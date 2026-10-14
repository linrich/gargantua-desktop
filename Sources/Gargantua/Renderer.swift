// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import MetalKit

struct Uniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var exposure: Float
    var inclination: Float
    var glow: Float
    var background: Float = 0
    var spin: Float
    var relativistic: Float
    var stepScale: Float = 1
    var beams: Float = 1
    var shutter: Float = 0
    var colorRotation: SIMD2<Float> = SIMD2(1,0)
    var edgeGrid: Float = 4
    var materialEvolution: Float = 1
}

struct GeodesicProbe {
    var camera: SIMD4<Float>
    var options: SIMD4<Float>
}

struct DesktopUniforms {
    var rect: SIMD4<Float>
    var controls: SIMD4<Float>
    var viewport: SIMD4<Float>
}

enum RenderError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let reason): return reason }
    }
}

final class BlackHoleRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let settings: Settings
    private let queue: MTLCommandQueue
    private let geometryPipeline: MTLComputePipelineState
    private let probePipeline: MTLComputePipelineState
    private let bundleProbePipeline: MTLComputePipelineState
    private let refinePipeline: MTLComputePipelineState
    private let filterProbePipeline: MTLComputePipelineState
    private let materialPipeline: MTLComputePipelineState
    private let materialProbePipeline: MTLComputePipelineState
    let lens: LensResponse
    private let diskPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let desktopPipeline: MTLRenderPipelineState
    private let desktopGeometryPipeline: MTLComputePipelineState
    private let desktopLookupPipeline: MTLComputePipelineState
    private let desktopMappingProbePipeline: MTLComputePipelineState
    private let backgroundOnly: Bool
    private var desktopMap: MTLTexture?
    private var desktopMapSize=SIMD2<Int>(0,0)
    private var desktopMapSpin: Float = -2
    private var desktopMapAngle: Float = -1
    private var desktopMapExtent: Float = -1
    private var desktopOutputSize=SIMD2<Int>(0,0)
    private(set) var desktopMapBuildCount=0
    var desktopFrameProvider: (() -> DesktopFrame?)?
    var desktopRect=SIMD4<Float>(0,0,1,1)
    var desktopViewport=SIMD4<Float>(0,0,1,1)
    var desktopCacheSize: SIMD2<Int> {desktopMapSize}
    var liveSceneSize: SIMD2<Int>?
    // Only populated by the offscreen self-test; never contains captured pixels.
    var syntheticDesktop: MTLTexture?
    var useDesktopScissor=true
    private var validationTarget: MTLTexture?
    private var primary: MTLTexture?
    private var secondary: MTLTexture?
    private var differentialX: MTLTexture?
    private var differentialY: MTLTexture?
    private var bundleIndices: MTLTexture?
    private var bundleAtlas: MTLBuffer?
    private var bundleCounter: MTLBuffer?
    private var bundleCapacity: UInt32 = 0
    private var material: MTLTexture?
    private var materialSpin: Float = -2
    private var materialWasReference = false
    private var materialWasLegacyDetail = false
    var useReferenceMaterial = false
    // Offscreen comparison with v0.6.2's fixed texture and growing optical core.
    var useLegacyDetail = false
    var materialResolution: [Int] { [material?.width ?? 0, material?.height ?? 0] }
    // Keep capture-only alpha for the existing independent shadow convergence test.
    var shadowCoverageDiagnostic = false
    private(set) var materialBuildCount = 0
    private var scene: MTLTexture?
    private var optical: MTLTexture?
    private var cachedSize = SIMD2<Int>(0, 0)
    private var cachedAngle: Float = -1
    private var cachedSpin: Float = -2
    private var cachedEdgeGrid = 0
    // 2 reproduces the previous boundary coverage; 8 is a convergence oracle.
    var edgeGrid = 4
    private(set) var geometryBuildCount = 0
    var useReferenceFiltering = false
    private var animationClock = AnimationClock(wallTime: CACurrentMediaTime())
    private let inFlight = DispatchSemaphore(value: 2)
    private var desktopRefresh = DesktopRefreshState()
    var suspended = false { didSet {
        animationClock.synchronize(to: CACurrentMediaTime())
        if suspended { desktopRefresh.invalidate() }
    } }
    var onFailure: ((String) -> Void)?

    init(settings: Settings, backgroundOnly: Bool = false) throws {
        self.backgroundOnly=backgroundOnly
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw RenderError.unavailable("这台 Mac 没有可用的 Metal 渲染设备。")
        }
        self.device = device; self.queue = queue; self.settings = settings
        let shaderURL: URL?
        #if SWIFT_PACKAGE
        shaderURL = Bundle.module.url(forResource: "BlackHole", withExtension: "metal", subdirectory: "Shaders")
        #else
        shaderURL = Bundle.main.url(forResource: "BlackHole", withExtension: "metal", subdirectory: "Shaders")
        #endif
        guard let shaderURL else { throw RenderError.unavailable("缺少 BlackHole.metal 资源，请重新构建 App。") }
        var source = try String(contentsOf: shaderURL, encoding: .utf8)
        for name in ["RayBundles.metal", "Lens.metal", "Desktop.metal"] {
            source += "\n" + (try String(contentsOf: shaderURL.deletingLastPathComponent().appendingPathComponent(name), encoding: .utf8))
        }
        let library = try device.makeLibrary(source: source, options: nil)
        guard let geometry = library.makeFunction(name: "beamGeometry"),
              let probe = library.makeFunction(name: "probeGeodesics"),
              let bundleProbe = library.makeFunction(name: "probeBundles"),
              let refine = library.makeFunction(name: "refineBeams"),
              let materialBuilder = library.makeFunction(name: "buildDiskMaterial"),
              let materialProbe = library.makeFunction(name: "probeMaterialEvolution"),
              let filterProbe = library.makeFunction(name: "probeEWA"),
              let vertex = library.makeFunction(name: "fullScreenVertex"),
              let disk = library.makeFunction(name: "bundleDiskFragment"),
              let composite = library.makeFunction(name: "compositeFragment"),
              let desktopComposite = library.makeFunction(name:backgroundOnly ? "desktopBackgroundFragment":"desktopCompositeFragment"),
              let desktopGeometry = library.makeFunction(name:"desktopGeometry"),
              let desktopMappingProbe = library.makeFunction(name:"probeDesktopMapping"),
              let desktopLookup = library.makeFunction(name:"probeDesktopLookup") else {
            throw RenderError.unavailable("Metal shader 入口不完整。")
        }
        geometryPipeline = try device.makeComputePipelineState(function: geometry)
        probePipeline = try device.makeComputePipelineState(function: probe)
        bundleProbePipeline = try device.makeComputePipelineState(function: bundleProbe)
        refinePipeline = try device.makeComputePipelineState(function: refine)
        materialPipeline = try device.makeComputePipelineState(function: materialBuilder)
        materialProbePipeline = try device.makeComputePipelineState(function: materialProbe)
        filterProbePipeline = try device.makeComputePipelineState(function: filterProbe)
        lens = try LensResponse(device: device, library: library)
        func makePipeline(_ fragment: MTLFunction, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertex; desc.fragmentFunction = fragment
            desc.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: desc)
        }
        diskPipeline = try makePipeline(disk, format: .rgba16Float)
        compositePipeline = try makePipeline(composite, format: .bgra8Unorm)
        desktopPipeline = try makePipeline(desktopComposite,format:.bgra8Unorm)
        desktopGeometryPipeline = try device.makeComputePipelineState(function:desktopGeometry)
        desktopLookupPipeline = try device.makeComputePipelineState(function:desktopLookup)
        desktopMappingProbePipeline = try device.makeComputePipelineState(function:desktopMappingProbe)
        super.init()
    }

    private func diagnosticCommand() -> MTLCommandBuffer? {
        let descriptor = MTLCommandBufferDescriptor()
        descriptor.errorOptions = .encoderExecutionStatus
        return queue.makeCommandBuffer(descriptor: descriptor)
    }
    private func checkedError(_ command: MTLCommandBuffer) throws {
        if let error = command.error {
            if let entries = (error as NSError).userInfo[MTLCommandBufferEncoderInfoErrorKey] as? [MTLCommandBufferEncoderInfo] {
                for entry in entries { print("GPU encoder: \(entry.label), state \(entry.errorState.rawValue)") }
            }
            throw error
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        desktopRefresh.invalidate()
    }

    func desktopRefreshKey(sequence: UInt64?, size: SIMD2<Int>) -> DesktopRefreshKey {
        DesktopRefreshKey(sequence: sequence, outputSize: size, rect: desktopRect,
                          viewport: desktopViewport, spin: Float(settings.spin),
                          inclination: Float(settings.inclination), strength: Float(settings.desktopStrength),
                          enabled: settings.desktopLensing)
    }

    func draw(in view: MTKView) {
        guard !suspended else {return}
        // Snapshot once: the sequence tested here and the texture encoded below
        // must belong to the same capture frame even if a new frame arrives.
        let frame = settings.desktopLensing ? desktopFrameProvider?() : nil
        let key = desktopRefreshKey(sequence: frame?.sequence,
                                    size: SIMD2(Int(view.drawableSize.width), Int(view.drawableSize.height)))
        // Keep the existing timer and immediate drag transactions, but leave
        // the last presented surface intact while its inputs are unchanged.
        // Skip BEFORE acquiring a drawable, semaphore or GPU command buffer.
        if backgroundOnly && !desktopRefresh.needsDraw(key) { return }
        // A position transaction must not move a panel while silently dropping
        // its replacement pixels. GPU completion releases the gate off-thread.
        let deadline:DispatchTime=view.presentsWithTransaction ? .distantFuture:.now()
        guard inFlight.wait(timeout:deadline) == .success else {return}
        guard let drawable = view.currentDrawable, let command = diagnosticCommand() else {
            inFlight.signal(); return
        }
        let now = CACurrentMediaTime()
        let elapsed=animationClock.advance(to:now,rate:settings.effectiveSpeed,paused:settings.paused)
        do {
            try encode(command: command, target: drawable.texture, time: Float(elapsed),frame:frame,sceneSize:liveSceneSize)
            let gate = inFlight
            command.addCompletedHandler { [weak self] buffer in
                gate.signal()
                if let error = buffer.error {
                    DispatchQueue.main.async {
                        self?.desktopRefresh.invalidate()
                        self?.onFailure?(error.localizedDescription)
                    }
                }
            }
            if view.presentsWithTransaction {
                // Apple's transaction presentation sequence. Calling
                // command.present() here would present outside the UI update.
                command.commit()
                command.waitUntilScheduled()
                drawable.present()
            } else {
                command.present(drawable)
                command.commit()
            }
            if backgroundOnly { desktopRefresh.didSubmit(key) }
        } catch {
            inFlight.signal(); onFailure?(error.localizedDescription)
        }
    }

    private func texture(_ width: Int, _ height: Int, _ format: MTLPixelFormat) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private
        guard let value = device.makeTexture(descriptor: desc) else {
            throw RenderError.unavailable("无法分配渲染纹理，请降低画质或尺寸。")
        }
        return value
    }

    private func pass(_ target: MTLTexture) -> MTLRenderPassDescriptor {
        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = target
        desc.colorAttachments[0].loadAction = .clear
        desc.colorAttachments[0].storeAction = .store
        desc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        return desc
    }

    private func encode(command: MTLCommandBuffer, target: MTLTexture, time: Float, background: Float = 0, frame: DesktopFrame? = nil, sceneSize: SIMD2<Int>? = nil) throws {
        if backgroundOnly {
            try encodeBackground(command:command,target:target,background:background,frame:frame)
            return
        }
        let width = sceneSize?.x ?? target.width, height = sceneSize?.y ?? target.height
        let size = SIMD2<Int>(width, height)
        let angle = Float(settings.inclination)
        let spin = Float(settings.spin)
        let rebuild = cachedSize != size || cachedAngle != angle || cachedSpin != spin || cachedEdgeGrid != edgeGrid
        if cachedSize != size || cachedEdgeGrid != edgeGrid {
            primary = try texture(width, height, .rgba32Float)
            secondary = try texture(width, height, .rgba32Float)
            differentialX = try texture(width, height, .rgba32Float)
            differentialY = try texture(width, height, .rgba32Float)
            bundleIndices = try texture(width, height, .r32Uint)
            // Flat sparse beam storage: four bundles in smooth/large-footprint
            // regions, sixteen at visibility/image-branch edges. Extra reserve
            // prevents a dense small image from competing with boundary samples.
            bundleCapacity = UInt32(max(4096,width*height + 524288))
            if edgeGrid > 4 {bundleCapacity = UInt32(width*height*edgeGrid*edgeGrid)}
            bundleAtlas = device.makeBuffer(length: Int(bundleCapacity)*64, options: .storageModePrivate)
            bundleCounter = device.makeBuffer(length: 16, options: .storageModeShared)
            scene = try texture(width, height, .rgba16Float)
            optical = try texture(width, height, .rgba16Float)
        }
        guard let primary, let secondary, let differentialX, let differentialY, let bundleIndices,
              let bundleAtlas, let bundleCounter, let scene, let optical else {
            throw RenderError.unavailable("渲染目标未就绪。")
        }
        var u = Uniforms(resolution: SIMD2(Float(width), Float(height)), time: time,
                         exposure: Float(settings.brightness), inclination: angle,
                         glow: Float(settings.glow), background: background,
                         spin: spin, relativistic: settings.relativistic ? 1 : 0,
                         beams: settings.beamFiltering ? (useReferenceFiltering ? 2:1):0,
                         shutter: Float(settings.shutterDuration),
                         colorRotation: SIMD2(Float(cos(settings.diskHue * .pi/180)*settings.diskSaturation),
                                              Float(sin(settings.diskHue * .pi/180)*settings.diskSaturation)),
                         edgeGrid:Float(edgeGrid),materialEvolution:useReferenceMaterial ? 0 : (shadowCoverageDiagnostic ? 2 : 1))
        if rebuild {
            geometryBuildCount += 1
            guard let compute = command.makeComputeCommandEncoder() else {
                throw RenderError.unavailable("无法创建光线计算指令。")
            }
            compute.label = "Cache gravitational light paths"
            compute.setComputePipelineState(geometryPipeline)
            compute.setTexture(primary, index: 0); compute.setTexture(secondary, index: 1)
            compute.setTexture(differentialX, index: 2); compute.setTexture(differentialY, index: 3)
            compute.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            compute.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            compute.endEncoding()
            guard let clear = command.makeBlitCommandEncoder() else { throw RenderError.unavailable("无法清空光束索引。") }
            clear.fill(buffer: bundleCounter, range: 0..<16, value: 0); clear.endEncoding()
            guard let refine = command.makeComputeCommandEncoder() else { throw RenderError.unavailable("无法细分光束。") }
            refine.setComputePipelineState(refinePipeline)
            for (i,t) in [primary,secondary,differentialX,differentialY,bundleIndices].enumerated() { refine.setTexture(t,index:i) }
            refine.setBuffer(bundleAtlas,offset:0,index:0); refine.setBuffer(bundleCounter,offset:0,index:1)
            refine.setBytes(&bundleCapacity,length:4,index:2); refine.setBytes(&u,length:MemoryLayout<Uniforms>.stride,index:3)
            refine.dispatchThreads(MTLSize(width:width,height:height,depth:1),threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1))
            refine.endEncoding()
        }
        let materialWidth = useLegacyDetail ? 2048 : RenderDetail.materialWidth(for:width)
        if material?.width != materialWidth || materialSpin != spin || materialWasReference != useReferenceMaterial || materialWasLegacyDetail != useLegacyDetail {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: materialWidth, height: materialWidth/2, mipmapped: true)
            descriptor.usage = [.shaderRead,.shaderWrite]; descriptor.storageMode = .private
            guard let tex = device.makeTexture(descriptor: descriptor), let compute = command.makeComputeCommandEncoder() else {
                throw RenderError.unavailable("无法创建吸积盘滤波纹理。")
            }
            material = tex
            compute.setComputePipelineState(materialPipeline); compute.setTexture(tex,index:0)
            var options = SIMD4<Float>(spin,useReferenceMaterial ? 1 : 0,useLegacyDetail ? 1 : 0,0)
            compute.setBytes(&options,length:MemoryLayout<SIMD4<Float>>.stride,index:0)
            compute.dispatchThreads(MTLSize(width:tex.width,height:tex.height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:8,depth:1))
            compute.endEncoding()
            guard let blit = command.makeBlitCommandEncoder() else {throw RenderError.unavailable("无法生成线性光强 mipmap。")}
            blit.generateMipmaps(for:tex); blit.endEncoding(); materialSpin = spin
            materialWasReference = useReferenceMaterial; materialBuildCount += 1
            materialWasLegacyDetail = useLegacyDetail
        }
        guard let disk = command.makeRenderCommandEncoder(descriptor: pass(scene)) else {
            throw RenderError.unavailable("无法创建吸积盘渲染指令。")
        }
        disk.label = "Animated accretion disk"
        disk.setRenderPipelineState(diskPipeline)
        disk.setFragmentTexture(primary, index: 0); disk.setFragmentTexture(secondary, index: 1)
        disk.setFragmentTexture(differentialX, index: 2); disk.setFragmentTexture(differentialY, index: 3)
        disk.setFragmentTexture(bundleIndices, index: 4); disk.setFragmentTexture(material, index: 5)
        disk.setFragmentBuffer(bundleAtlas, offset: 0, index: 1)
        disk.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        disk.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        disk.endEncoding()

        lens.useReferenceCore = useLegacyDetail
        if settings.lensResponse {
            try lens.apply(command: command, scene: scene, target: optical, glow: settings.glow,
                           scale: settings.lensScale, measured: settings.measuredPSF, revision: settings.psfRevision)
        }
        // Capture surfaces must outlive the asynchronous GPU command. Never
        // retain a live frame in the geometry or material caches.
        let desktop=settings.desktopLensing ? (syntheticDesktop ?? frame?.texture):nil
        var compositeUniforms=u
        compositeUniforms.resolution=SIMD2(Float(target.width),Float(target.height))
        if let frame {command.addCompletedHandler {_ in withExtendedLifetime(frame) {}}}
        if desktop != nil {try prepareDesktopMap(command:command,u:&compositeUniforms)}
        else {desktopMap=nil;desktopMapSize=SIMD2(0,0)}
        guard let composite = command.makeRenderCommandEncoder(descriptor: pass(target)) else {
            throw RenderError.unavailable("无法创建透明合成指令。")
        }
        composite.label = "Bloom and premultiplied desktop compositing"
        composite.setRenderPipelineState(desktop == nil ? compositePipeline:desktopPipeline)
        composite.setFragmentTexture(settings.lensResponse ? optical:scene, index: 0)
        composite.setFragmentBytes(&compositeUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        if let desktop,let desktopMap {
            var d=desktopUniforms()
            composite.setFragmentTexture(desktop,index:1);composite.setFragmentTexture(desktopMap,index:2)
            composite.setFragmentBytes(&d,length:MemoryLayout<DesktopUniforms>.stride,index:1)
        }
        composite.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        composite.endEncoding()
        cachedSize = size; cachedAngle = angle; cachedSpin = spin; cachedEdgeGrid = edgeGrid
    }

    private func desktopUniforms() -> DesktopUniforms {
        DesktopUniforms(rect:desktopRect,
                        controls:SIMD4(Float(settings.desktopStrength),desktopMapExtent,DesktopField.compandingScale,0),
                        viewport:desktopViewport)
    }

    private func prepareDesktopMap(command: MTLCommandBuffer, u: inout Uniforms) throws {
        desktopOutputSize=SIMD2(Int(u.resolution.x),Int(u.resolution.y))
        let side=DesktopField.mapSide(output:desktopOutputSize,viewport:desktopViewport)
        let extent=DesktopField.extent(output:desktopOutputSize,viewport:desktopViewport)
        let size=SIMD2(side,side)
        guard desktopMapSize != size || desktopMapExtent != extent || desktopMapSpin != u.spin || desktopMapAngle != u.inclination else {return}
        if desktopMapSize != size {desktopMap=try texture(side,side,.rgba32Float)}
        desktopMapExtent=extent
        var d=desktopUniforms()
        guard let map=desktopMap,let compute=command.makeComputeCommandEncoder() else {
            throw RenderError.unavailable("无法创建桌面透镜映射。")
        }
        compute.setComputePipelineState(desktopGeometryPipeline);compute.setTexture(map,index:0)
        compute.setBytes(&u,length:MemoryLayout<Uniforms>.stride,index:0)
        compute.setBytes(&d,length:MemoryLayout<DesktopUniforms>.stride,index:1)
        compute.dispatchThreads(MTLSize(width:side,height:side,depth:1),threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1))
        compute.endEncoding()
        desktopMapSize=size;desktopMapSpin=u.spin;desktopMapAngle=u.inclination;desktopMapBuildCount+=1
    }

    // Stationary, mouse-transparent surface; only the local scissor is shaded.
    // No disk/PSF allocation
    // or animation work is done here; the original foreground view is unchanged.
    private func encodeBackground(command: MTLCommandBuffer, target: MTLTexture, background: Float, frame: DesktopFrame?) throws {
        let desktop=settings.desktopLensing ? (syntheticDesktop ?? frame?.texture):nil
        if let frame {command.addCompletedHandler {_ in withExtendedLifetime(frame) {}}}
        var u=Uniforms(resolution:SIMD2(Float(target.width),Float(target.height)),time:0,exposure:1,
                       inclination:Float(settings.inclination),glow:0,background:background,spin:Float(settings.spin),relativistic:0)
        if desktop != nil {try prepareDesktopMap(command:command,u:&u)}
        guard let composite=command.makeRenderCommandEncoder(descriptor:pass(target)) else {
            throw RenderError.unavailable("无法创建桌面背景合成。")
        }
        if let desktop,let desktopMap {
            if useDesktopScissor && background<2.5 {
                let bounds=DesktopField.rasterBounds(output:SIMD2(target.width,target.height),viewport:desktopViewport,inclination:u.inclination)
                guard !bounds.isNull && !bounds.isEmpty else {composite.endEncoding();return}
                composite.setScissorRect(MTLScissorRect(x:Int(bounds.minX),y:Int(bounds.minY),width:Int(bounds.width),height:Int(bounds.height)))
            }
            var d=desktopUniforms()
            composite.setRenderPipelineState(desktopPipeline)
            composite.setFragmentBytes(&u,length:MemoryLayout<Uniforms>.stride,index:0)
            composite.setFragmentBytes(&d,length:MemoryLayout<DesktopUniforms>.stride,index:1)
            composite.setFragmentTexture(desktop,index:1);composite.setFragmentTexture(desktopMap,index:2)
            composite.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3)
        }
        composite.endEncoding()
    }

    func probe(_ inputs: [GeodesicProbe], bundles: Bool = false) throws -> [[Float]] {
        guard !inputs.isEmpty else { return [] }
        let inputBytes = inputs.count * MemoryLayout<GeodesicProbe>.stride
        let input = inputs.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: inputBytes, options: .storageModeShared) }
        guard let input, let output = device.makeBuffer(length: inputs.count * 64, options: .storageModeShared),
              let command = diagnosticCommand(), let compute = command.makeComputeCommandEncoder() else {
            throw RenderError.unavailable("无法创建测地线验证缓冲区。")
        }
        var count = UInt32(inputs.count)
        compute.setComputePipelineState(bundles ? bundleProbePipeline:probePipeline)
        compute.setBuffer(input, offset: 0, index: 0); compute.setBuffer(output, offset: 0, index: 1)
        compute.setBytes(&count, length: 4, index: 2)
        compute.dispatchThreads(MTLSize(width: inputs.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        compute.endEncoding(); command.commit(); command.waitUntilCompleted()
        try checkedError(command)
        let pointer = output.contents().bindMemory(to: Float.self, capacity: inputs.count * 16)
        return (0..<inputs.count).map { i in Array(UnsafeBufferPointer(start: pointer + i*16, count: 16)) }
    }

    func checkEllipticalFilter() throws -> [String: Any] {
        let n = 256, uv: Float = 96.5/256
        let probes: [Float] = [
            uv,uv,1,0, 8/256,0,0,0.25/256,
            uv,uv,1,0, 0.25/256,0,0,8/256,
            -0.0001,uv,1,0, 2/256,1/256,-1/256,2/256,
            0.9999,uv,1,0, 2/256,1/256,-1/256,2/256,
            uv,uv,1,0, 1e10,0,0,1e10
        ]
        var count: UInt32 = 5
        var outputs = [[Float]]()
        for constant in [true,false] {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:n,height:n,mipmapped:true)
            d.storageMode = .shared; d.usage = [.shaderRead,.shaderWrite]
            guard let tex=device.makeTexture(descriptor:d),let command=diagnosticCommand(),
                  let input=probes.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}),
                  let result=device.makeBuffer(length:5*16,options:.storageModeShared) else {throw RenderError.unavailable("EWA 验证内存不足。")}
            var values=[Float](repeating:0,count:n*n*4)
            for y in 0..<n {for x in 0..<n {let v:Float=constant ? 0.37:0.5+0.4*cos(2*Float.pi*Float(x)/8)
                for c in 0..<4 {values[(y*n+x)*4+c]=v}
            }}
            values.withUnsafeBytes{tex.replace(region:MTLRegionMake2D(0,0,n,n),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:n*16)}
            guard let blit=command.makeBlitCommandEncoder() else {throw RenderError.unavailable("EWA mip 验证失败。")}
            blit.generateMipmaps(for:tex);blit.endEncoding()
            guard let compute=command.makeComputeCommandEncoder() else {throw RenderError.unavailable("EWA 验证编码失败。")}
            compute.setComputePipelineState(filterProbePipeline);compute.setTexture(tex,index:0)
            compute.setBuffer(input,offset:0,index:0);compute.setBuffer(result,offset:0,index:1);compute.setBytes(&count,length:4,index:2)
            compute.dispatchThreads(MTLSize(width:5,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:5,height:1,depth:1))
            compute.endEncoding();command.commit();command.waitUntilCompleted();try checkedError(command)
            let p=result.contents().bindMemory(to:Float.self,capacity:20)
            outputs.append((0..<5).map {p[$0*4]})
        }
        let c=outputs[0],s=outputs[1]
        let checks=["constant_radiance_preserved":c.allSatisfy {abs($0-0.37)<0.00001},
                    "parallel_stripes_antialiased":abs(s[0]-0.5)<0.02,
                    "perpendicular_detail_preserved":s[1]>0.85,
                    "periodic_seam_continuous":abs(s[2]-s[3])<0.0001,
                    "extreme_footprint_bounded":s[4].isFinite && abs(s[4]-0.5)<0.0001]
        return ["checks":checks,"constant_samples":c,"sinusoidal_samples":s]
    }

    // Compare the actual GPU FFT convolution against a direct CPU sum using
    // asymmetric kernels, independent colour channels, HDR input and hard edges.
    func checkLensConvolution() throws -> [String: Any] {
        var maxError: Float = 0
        var cases = [[String:Any]]()
        for (name,w,h) in [("asymmetric",23,17),("identity",23,17),("impulse",23,17),
                           ("wide",317,193),("tall",19,1037),("wide-global",1037,19),
                           ("two-axis-global",1031,1029),("single",1,1),
                           ("cropped-padding",29,29),("kernel-wider-than-image",2,3)] {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:w,height:h,mipmapped:false)
            d.storageMode = .shared; d.usage = [.shaderRead,.shaderWrite]
            guard let input = device.makeTexture(descriptor:d) else {throw RenderError.unavailable("PSF 测试纹理失败。")}
            let target = try texture(w,h,.rgba32Float)
            var pixels = [Float](repeating:0,count:w*h*4)
            for y in 0..<h {for x in 0..<w {
                let i = (y*w+x)*4
                if name == "impulse" {
                    if x == w/2 && y == h/2 {pixels[i]=1;pixels[i+1]=2;pixels[i+2]=4}
                } else {
                    pixels[i] = Float((x*17+y*11)%31)/7
                    pixels[i+1] = Float((x*5+y*13)%19)/5
                    pixels[i+2] = Float((x*3+y*7)%23)/3
                }
                pixels[i+3] = 0.375
            }}
            pixels.withUnsafeBytes {input.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:w*16)}
            let identity = name == "identity" || name == "single"
            let k: [Float] = identity ? [1]:[0,0,0.04,0,0, 0,0.02,0.05,0,0, 0.1,0.07,0.5,0.09,0, 0,0.03,0.06,0,0, 0,0,0.04,0,0]
            let n = identity ? 1:5, radius = n/2
            guard let command=diagnosticCommand(),let read=device.makeBuffer(length:w*h*16,options:.storageModeShared) else {throw RenderError.unavailable("PSF 测试缓冲失败。")}
            try lens.apply(command:command,scene:input,target:target,glow:0,scale:1,measured:nil,revision:0,override:(n,k))
            guard let blit=command.makeBlitCommandEncoder() else {throw RenderError.unavailable("PSF 读取失败。")}
            blit.copy(from:target,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),sourceSize:MTLSize(width:w,height:h,depth:1),to:read,destinationOffset:0,destinationBytesPerRow:w*16,destinationBytesPerImage:w*h*16)
            blit.endEncoding();command.commit();command.waitUntilCompleted()
            try checkedError(command)
            let result=read.contents().bindMemory(to:Float.self,capacity:w*h*4)
            var error: Float = 0
            for y in 0..<h {for x in 0..<w {for channel in 0..<4 {
                var expected: Float = channel == 3 ? 0.375:0
                if channel < 3 {for ky in 0..<n {for kx in 0..<n {
                    let sx=x-(kx-radius),sy=y-(ky-radius)
                    if (0..<w).contains(sx) && (0..<h).contains(sy) {expected+=pixels[(sy*w+sx)*4+channel]*k[ky*n+kx]}
                }}}
                let actual=result[(y*w+x)*4+channel]
                if !actual.isFinite {throw RenderError.unavailable("PSF 卷积产生非有限值。")}
                error=max(error,abs(expected-actual))
            }}}
            maxError=max(maxError,error);cases.append(["name":name,"max_absolute_error":error])
        }
        let (n,k) = LensResponse.synthesized(height:800,glow:0.65,scale:1)
        let sum=k.reduce(0.0){$0+Double($1)}
        let checks=["fft_matches_direct_linear_convolution":maxError<0.0001,
                    "normalized_nonnegative_psf":abs(sum-1)<0.00001 && k.allSatisfy{$0>=0}]
        return ["checks":checks,"max_absolute_error":maxError,"kernel_sum":sum,"kernel_size":n,"cases":cases]
    }

    func geometryDiagnostics() throws -> [String: Any] {
        guard let secondary, let command = diagnosticCommand(),
              let buffer = device.makeBuffer(length: secondary.width*secondary.height*16, options: .storageModeShared),
              let blit = command.makeBlitCommandEncoder() else {
            throw RenderError.unavailable("测地线诊断纹理未就绪。")
        }
        blit.copy(from: secondary, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0,y: 0,z: 0),
                  sourceSize: MTLSize(width: secondary.width,height: secondary.height,depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: secondary.width*16,
                  destinationBytesPerImage: secondary.width*secondary.height*16)
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        try checkedError(command)
        let p = buffer.contents().bindMemory(to: Float.self, capacity: secondary.width*secondary.height*4)
        var counts = [Int](repeating: 0, count: 7), maxRadial: Float = 0, maxPolar: Float = 0, higherOrder = 0
        for i in 0..<(secondary.width*secondary.height) {
            let status = p[i*4].isFinite ? Int(p[i*4]) : 5
            if (0..<7).contains(status) { counts[status] += 1 }
            if p[i*4+1] >= 2 && status == 1 { higherOrder += 1 }
            maxRadial = max(maxRadial,p[i*4+2]); maxPolar = max(maxPolar,p[i*4+3])
        }
        return ["disk": counts[1], "captured": counts[2], "escaped": counts[3], "budget_exhausted": counts[4],
                "nonfinite": counts[5], "invalid_bundle_derivatives": counts[6],
                "refined_pixels": bundleCounter.map {Int($0.contents().load(as:UInt32.self))} ?? 0,
                "refined_invalid": bundleCounter.map {Int($0.contents().advanced(by:8).load(as:UInt32.self))} ?? 0,
                "refinement_overflow": bundleCounter.map {Int($0.contents().advanced(by:4).load(as:UInt32.self))} ?? 0,
                "cached_subbeams": bundleCounter.map {Int($0.contents().advanced(by:12).load(as:UInt32.self))} ?? 0,
                "subbeam_capacity":Int(bundleCapacity),"edge_grid":edgeGrid,
                "higher_order_disk_pixels": higherOrder,
                "max_radial_invariant_error": maxRadial, "max_polar_invariant_error": maxPolar]
    }

    func scenePixels() throws -> [SIMD4<Float>] {
        guard let scene, let command=diagnosticCommand(),
              let read=device.makeBuffer(length:scene.width*scene.height*8,options:.storageModeShared),
              let blit=command.makeBlitCommandEncoder() else {throw RenderError.unavailable("无法读取线性调色检查。")}
        blit.copy(from:scene,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),
                  sourceSize:MTLSize(width:scene.width,height:scene.height,depth:1),to:read,destinationOffset:0,
                  destinationBytesPerRow:scene.width*8,destinationBytesPerImage:scene.width*scene.height*8)
        blit.endEncoding();command.commit();command.waitUntilCompleted();try checkedError(command)
        let p=read.contents().bindMemory(to:UInt16.self,capacity:scene.width*scene.height*4)
        return (0..<(scene.width*scene.height)).map {i in
            SIMD4(Float(Float16(bitPattern:p[i*4])),Float(Float16(bitPattern:p[i*4+1])),
                  Float(Float16(bitPattern:p[i*4+2])),Float(Float16(bitPattern:p[i*4+3])))
        }
    }

    func desktopMappingForValidation() throws -> [SIMD4<Float>] {
        try desktopProbe(pipeline:desktopMappingProbePipeline)
    }

    // Reads mathematical coordinates/weights only, never captured pixels.
    func desktopLookupForValidation() throws -> [SIMD4<Float>] {
        try desktopProbe(pipeline:desktopLookupPipeline)
    }

    private func desktopProbe(pipeline: MTLComputePipelineState) throws -> [SIMD4<Float>] {
        guard let map=desktopMap,let command=diagnosticCommand() else {throw RenderError.unavailable("桌面映射未就绪。")}
        let w=desktopOutputSize.x,h=desktopOutputSize.y
        let result=try texture(w,h,.rgba32Float)
        var u=Uniforms(resolution:SIMD2(Float(w),Float(h)),time:0,exposure:1,inclination:0,glow:0,spin:0,relativistic:0)
        var d=desktopUniforms()
        guard let compute=command.makeComputeCommandEncoder(),
              let read=device.makeBuffer(length:w*h*16,options:.storageModeShared) else {throw RenderError.unavailable("无法验证桌面采样映射。")}
        compute.setComputePipelineState(pipeline);compute.setTexture(map,index:0);compute.setTexture(result,index:1)
        compute.setBytes(&u,length:MemoryLayout<Uniforms>.stride,index:0);compute.setBytes(&d,length:MemoryLayout<DesktopUniforms>.stride,index:1)
        compute.dispatchThreads(MTLSize(width:w,height:h,depth:1),threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1))
        compute.endEncoding()
        guard let blit=command.makeBlitCommandEncoder() else {throw RenderError.unavailable("无法读取桌面采样映射。")}
        blit.copy(from:result,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),
                  sourceSize:MTLSize(width:w,height:h,depth:1),to:read,destinationOffset:0,
                  destinationBytesPerRow:w*16,destinationBytesPerImage:w*h*16)
        blit.endEncoding();command.commit();command.waitUntilCompleted();try checkedError(command)
        return Array(UnsafeBufferPointer(start:read.contents().bindMemory(to:SIMD4<Float>.self,capacity:w*h),count:w*h))
    }

    func materialEvolutionSamples(_ inputs:[SIMD4<Float>]) throws -> [SIMD4<Float>] {
        let length=inputs.count*MemoryLayout<SIMD4<Float>>.stride
        guard let material, let command=diagnosticCommand(),
              let data=device.makeBuffer(bytes:inputs,length:length,options:.storageModeShared),
              let result=device.makeBuffer(length:length,options:.storageModeShared),
              let compute=command.makeComputeCommandEncoder() else {throw RenderError.unavailable("材质演化检查失败。")}
        compute.setComputePipelineState(materialProbePipeline);compute.setTexture(material,index:0)
        compute.setBuffer(data,offset:0,index:0);compute.setBuffer(result,offset:0,index:1)
        compute.dispatchThreads(MTLSize(width:inputs.count,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:32,height:1,depth:1))
        compute.endEncoding();command.commit();command.waitUntilCompleted();try checkedError(command)
        let p=result.contents().bindMemory(to:SIMD4<Float>.self,capacity:inputs.count)
        return Array(UnsafeBufferPointer(start:p,count:inputs.count))
    }

    // Read the cached emissivity only during self-tests, never in the draw loop.
    func materialStatistics() throws -> [String: Double] {
        guard let material, let command=diagnosticCommand(),
              let read=device.makeBuffer(length:material.width*material.height*8,options:.storageModeShared),
              let blit=command.makeBlitCommandEncoder() else {throw RenderError.unavailable("无法读取盘材质检查。")}
        let width=material.width, height=material.height
        blit.copy(from:material,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),
                  sourceSize:MTLSize(width:width,height:height,depth:1),to:read,destinationOffset:0,
                  destinationBytesPerRow:width*8,destinationBytesPerImage:width*height*8)
        blit.endEncoding();command.commit();command.waitUntilCompleted();try checkedError(command)
        let p=read.contents().bindMemory(to:UInt16.self,capacity:width*height*4)
        func intensity(_ x:Int,_ y:Int)->Double {Double(Float16(bitPattern:p[(y*width+x)*4+3]))}
        var invalid=0, seam=0.0, neighbor=0.0, contrast=0.0, rows=0, dark=0
        for i in 0..<(width*height*4) {
            let value=Float16(bitPattern:p[i]); if !value.isFinite || value<0 {invalid+=1}
        }
        // Compare azimuthal contrast at fixed radius, excluding both tapered edges.
        for y in 0..<height where Double(y)*24/Double(height)>settings.isco+1 && Double(y)*24/Double(height)<14 {
            let values=(0..<width).map {intensity($0,y)}
            let mean=values.reduce(0,+)/Double(width)
            contrast+=sqrt(values.reduce(0) {$0+($1-mean)*($1-mean)}/Double(width))/max(mean,1e-8)
            dark+=values.filter {$0<mean*0.35}.count
            seam+=abs(values[0]-values[width-1])
            neighbor+=(1..<width).reduce(0) {$0+abs(values[$1]-values[$1-1])}/Double(width-1)
            rows+=1
        }
        return ["invalid_channels":Double(invalid),"mean_azimuthal_contrast":contrast/Double(rows),
                "dark_area_fraction":Double(dark)/Double(rows*width),
                "seam_step_to_neighbor_step":seam/max(neighbor,1e-8)]
    }

    func sceneStatistics() throws -> [String: Double] {
        let pixels=try scenePixels()
        var sum=0.0,invalid=0.0,maxGrayDifference=0.0
        for pixel in pixels {
            let rgb=(0..<3).map {Double(pixel[$0])}
            if rgb.contains(where:{!$0.isFinite || $0<0}) {invalid+=1}
            sum+=rgb[0]*0.2126+rgb[1]*0.7152+rgb[2]*0.0722
            maxGrayDifference=max(maxGrayDifference,abs(rgb[0]-rgb[1]),abs(rgb[1]-rgb[2]))
        }
        return ["linear_luminance_sum":sum,"invalid_pixels":invalid,"max_gray_difference":maxGrayDifference]
    }

    // Synthetic input replay, without display/capture access. Both paths use
    // this same renderer; only the unchanged-frame submission gate differs.
    func benchmarkDesktopRefresh(width: Int, height: Int, ticks: Int, newFrameEvery: Int,
                                 moving: Bool, optimized: Bool) throws -> [String: Any] {
        precondition(backgroundOnly && ticks > 0 && newFrameEvery > 0)
        let target = try texture(width,height,.bgra8Unorm)
        let originalViewport = desktopViewport
        defer { desktopViewport = originalViewport }
        for _ in 0..<2 {
            guard let command=diagnosticCommand() else {throw RenderError.unavailable("背景性能预热失败。")}
            try encode(command:command,target:target,time:0)
            command.commit();command.waitUntilCompleted();try checkedError(command)
        }
        var state = DesktopRefreshState(), gpu = [Double]()
        let start = CACurrentMediaTime()
        for tick in 0..<ticks {
            desktopViewport = originalViewport
            if moving { desktopViewport.x += Float(tick % 20) / Float(width) }
            let key = desktopRefreshKey(sequence:UInt64(tick/newFrameEvery+1),size:SIMD2(width,height))
            if optimized && !state.needsDraw(key) { continue }
            guard let command=diagnosticCommand() else {throw RenderError.unavailable("背景性能测量失败。")}
            try encode(command:command,target:target,time:0)
            command.commit();state.didSubmit(key)
            command.waitUntilCompleted();try checkedError(command)
            gpu.append((command.gpuEndTime-command.gpuStartTime)*1000)
        }
        let sorted=gpu.sorted()
        return ["ticks":ticks,"submitted":gpu.count,"skipped":ticks-gpu.count,
                "gpu_total_ms":gpu.reduce(0,+),"gpu_samples_ms":gpu,
                "gpu_median_ms":sorted[sorted.count/2],"gpu_p95_ms":sorted[Int(Double(sorted.count-1)*0.95)],
                "wall_total_ms":(CACurrentMediaTime()-start)*1000]
    }

    // Interleave individual frames to reduce the timing drift observed in
    // whole-run ABBA tests. All inputs change here, so neither path may skip.
    func compareChangingDesktop(width: Int, height: Int, moving: Bool) throws -> [String: Any] {
        precondition(backgroundOnly)
        let target=try texture(width,height,.bgra8Unorm),origin=desktopViewport
        defer { desktopViewport=origin }
        var state=DesktopRefreshState(),before=[Double](),after=[Double]()
        for cycle in 0..<160 {
            for (step,optimized) in [false,true,true,false].enumerated() {
                let tick=cycle*4+step
                desktopViewport=origin
                if moving {desktopViewport.x += Float(tick%20)/Float(width)}
                let key=desktopRefreshKey(sequence:UInt64(tick+1),size:SIMD2(width,height))
                guard !optimized || state.needsDraw(key) else {throw RenderError.unavailable("动态背景被错误跳过。")}
                guard let command=diagnosticCommand() else {throw RenderError.unavailable("交替计时指令失败。")}
                try encode(command:command,target:target,time:0)
                command.commit();state.didSubmit(key)
                command.waitUntilCompleted();try checkedError(command)
                if cycle>=10 {
                    let value=(command.gpuEndTime-command.gpuStartTime)*1000
                    if optimized {after.append(value)} else {before.append(value)}
                }
            }
        }
        func stats(_ values:[Double]) -> [String:Any] {
            let sorted=values.sorted()
            return ["submitted":values.count,"median_ms":sorted[sorted.count/2],
                    "p95_ms":sorted[Int(Double(sorted.count-1)*0.95)],"samples_ms":values]
        }
        return ["baseline":stats(before),"optimized":stats(after)]
    }

    func benchmark(width: Int, height: Int, frames: Int = 24, lensOnly: Bool = false) throws -> [String: Any] {
        let target = try texture(width,height,.bgra8Unorm)
        var gpu = [Double](), wall = [Double]()
        for i in 0..<(frames+2) {
            guard let command=diagnosticCommand() else {throw RenderError.unavailable("性能测量指令失败。")}
            let start=CACurrentMediaTime()
            if lensOnly && i > 0, let scene, let optical {
                try lens.apply(command:command,scene:scene,target:optical,glow:settings.glow,
                               scale:settings.lensScale,measured:settings.measuredPSF,revision:settings.psfRevision)
            } else {
                try encode(command:command,target:target,time:12+Float(i)/60)
            }
            command.commit();command.waitUntilCompleted();try checkedError(command)
            if i>=2 {
                wall.append((CACurrentMediaTime()-start)*1000)
                gpu.append((command.gpuEndTime-command.gpuStartTime)*1000)
            }
        }
        let sorted=gpu.sorted()
        return ["width":width,"height":height,"frames":frames,
                "gpu_samples_ms":gpu,
                "scope":backgroundOnly ? "desktop_background_only":(lensOnly ? "lens_only":"full_frame"), "reference_fft":lens.useReferenceFFT,
                "beams":settings.beamFiltering,"lens":settings.lensResponse,"shutter_degrees":settings.shutterAngle,
                "gpu_median_ms":sorted[sorted.count/2],"gpu_p95_ms":sorted[Int(Double(sorted.count-1)*0.95)],
                "wall_mean_ms":wall.reduce(0,+)/Double(wall.count),
                "note":backgroundOnly ? "Generated texture, warmed desktop cache; excludes capture, foreground rendering, window composition and sustained thermal/power behavior.":"Offscreen, warmed geometry/PSF; excludes window composition and sustained thermal/power behavior."]
    }

    // Deterministic, offscreen GPU rendering for verification, no desktop capture.
    func snapshot(to url: URL, width: Int = 1280, height: Int = 800,
                  time: Float = 12, background: Float = 0, sceneSize: SIMD2<Int>? = nil, reuseTarget: Bool = false) throws -> [UInt8] {
        let target: MTLTexture
        if reuseTarget,let previous=validationTarget,previous.width==width,previous.height==height {target=previous}
        else {target=try texture(width,height,.bgra8Unorm)}
        if reuseTarget {validationTarget=target}
        let count = width * height * 4
        guard let buffer = device.makeBuffer(length: count, options: .storageModeShared),
              let command = diagnosticCommand() else {
            throw RenderError.unavailable("无法创建离屏渲染缓冲区。")
        }
        try encode(command: command, target: target, time: time, background: background,sceneSize:sceneSize)
        guard let blit = command.makeBlitCommandEncoder() else {
            throw RenderError.unavailable("无法读取离屏渲染结果。")
        }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: width * 4, destinationBytesPerImage: count)
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        try checkedError(command)
        let bytes = buffer.contents().bindMemory(to: UInt8.self, capacity: count)
        var rgba = [UInt8](repeating: 0, count: count)
        for i in stride(from: 0, to: count, by: 4) {
            rgba[i] = bytes[i + 2]; rgba[i + 1] = bytes[i + 1]
            rgba[i + 2] = bytes[i]; rgba[i + 3] = bytes[i + 3]
        }
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw RenderError.unavailable("无法编码 PNG。")
        }
        try png.write(to: url, options: .atomic)
        return rgba
    }
}
