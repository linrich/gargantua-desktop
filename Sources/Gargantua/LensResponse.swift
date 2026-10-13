// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Metal

// A monochromatic/achromatic linear-intensity PSF. Values must already be
// background-subtracted; this loader never treats a gamma-encoded photo as HDR.
struct MeasuredPSF: Decodable {
    let format: String
    let size: Int
    let pitchAt800: Double
    let values: [Double]
    static func read(_ url: URL) throws -> MeasuredPSF {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 8_000_000 else {
            throw RenderError.unavailable("PSF 文件超过 8 MB。")
        }
        let value = try JSONDecoder().decode(MeasuredPSF.self, from: Data(contentsOf: url))
        guard value.format == "linear-intensity-psf-v1", (3...257).contains(value.size), value.size % 2 == 1,
              value.values.count == value.size*value.size, value.pitchAt800.isFinite,
              (0.05...8).contains(value.pitchAt800),
              value.values.allSatisfy({$0.isFinite && $0 >= 0}), value.values.reduce(0,+).isFinite, value.values.reduce(0,+) > 0 else {
            throw RenderError.unavailable("PSF 应为 3–257 的奇数方阵、非负线性光强，且包含有效采样间距。")
        }
        // Reserve enough support for every permitted resolution and lens scale,
        // so a later slider adjustment cannot invalidate an accepted file.
        guard Double(value.size/2)*value.pitchAt800*(Double(RenderDetail.maximumHeight)/800)*2 <= 512 else {
            throw RenderError.unavailable("PSF 的采样间距与范围过大：需确保在最高分辨率、2×尺度下不超过 1025 像素。")
        }
        return value
    }
}

struct FFTParameters {
    var width, height, axis, span, inverse, bits, kernelSize, padding: UInt32
    init(_ width: Int, _ height: Int) {
        self.width = UInt32(width); self.height = UInt32(height)
        axis = 0; span = 0; inverse = 0; bits = 0; kernelSize = 0; padding = 0
    }
}

final class LensResponse {
    private let device: MTLDevice
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private var a: MTLTexture?, b: MTLTexture?, spectrum: MTLTexture?
    private var cachedKey = ""
    // Kept for numerical/performance regression checks against the v0.3 path.
    var useReferenceFFT = false
    var useReferenceCore = false
    // Exact v0.9.3 pass schedule retained for same-binary regression checks.
    var useFusedPasses = true
    private(set) var kernel: [Float] = []
    private(set) var kernelSize = 0
    private(set) var paddingWidth = 0
    private(set) var paddingHeight = 0

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        for name in ["fftLoadScene","fftLoadKernel","fftReorder","fftStage","fftBlock","fftStagePair","fftMultiply","fftFinish","fftStagePairFinish"] {
            guard let f = library.makeFunction(name: name) else { throw RenderError.unavailable("缺少镜头卷积入口。") }
            pipelines[name] = try device.makeComputePipelineState(function: f)
        }
        for (name, mode) in [("fftBlockRegisters", UInt32(0)), ("fftBlockScene", UInt32(1)), ("fftBlockMultiply", UInt32(2)), ("fftBlockFinish", UInt32(3))] {
            for simd in [false, true] {
                if simd && !device.supportsFamily(.apple1) { continue }
                if !simd && mode == 0 { continue } // The original fftBlock.
                let constants = MTLFunctionConstantValues()
                var value = mode, simdButterflies = simd
                constants.setConstantValue(&value, type: .uint, index: 0)
                constants.setConstantValue(&simdButterflies, type: .bool, index: 1)
                let function = try library.makeFunction(name: "fftBlockFused", constantValues: constants)
                pipelines[name + (simd ? "SIMD":"")] = try device.makeComputePipelineState(function: function)
            }
        }
    }
    private func texture(_ width: Int, _ height: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead,.shaderWrite]; d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { throw RenderError.unavailable("镜头卷积内存不足，请降低尺寸。") }
        return t
    }
    private func encode(_ name: String, command: MTLCommandBuffer, textures: [(Int,MTLTexture)],
                        params: FFTParameters? = nil, paramIndex: Int = 0, buffer: MTLBuffer? = nil,
                        width: Int, height: Int) throws {
        guard let e = command.makeComputeCommandEncoder(), let pipeline = pipelines[name] else {
            throw RenderError.unavailable("无法创建镜头卷积指令。")
        }
        e.label = name; e.setComputePipelineState(pipeline)
        for (i,t) in textures { e.setTexture(t,index:i) }
        if var p = params { e.setBytes(&p,length:MemoryLayout<FFTParameters>.stride,index:paramIndex) }
        if let buffer { e.setBuffer(buffer,offset:0,index:0) }
        e.dispatchThreads(MTLSize(width:width,height:height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:8,depth:1))
        e.endEncoding()
    }
    private func fft(command: MTLCommandBuffer, source: inout MTLTexture, scratch: inout MTLTexture, inverse: Bool,
                     sceneInput: MTLTexture? = nil, multiply: MTLTexture? = nil,
                     finish: (scene: MTLTexture, target: MTLTexture)? = nil) throws {
        var p = FFTParameters(source.width,source.height); p.inverse = inverse ? 1:0
        // Register shuffles help larger Apple-GPU transforms; on the measured
        // small transform their overhead exceeds the barrier savings. Retain
        // shared memory there and on other GPU families. Both are exact paths.
        let simd = useFusedPasses && device.supportsFamily(.apple1) && source.width * source.height >= 1_048_576
        let suffix = simd ? "SIMD":""
        let regularBlock = simd ? "fftBlockRegistersSIMD":"fftBlock"
        for axis in 0...1 {
            let n = axis == 0 ? source.width:source.height
            p.axis = UInt32(axis); p.bits = UInt32(n.trailingZeroBitCount)
            var span = 2
            if useReferenceFFT {
                try encode("fftReorder",command:command,textures:[(0,source),(1,scratch)],params:p,width:source.width,height:source.height)
            } else {
                var name = regularBlock
                if axis == 0, sceneInput != nil { name = "fftBlockScene" + suffix }
                if axis == 0, multiply != nil { name = "fftBlockMultiply" + suffix }
                // Select the terminal block only when all stages fit locally.
                if axis == 1, finish != nil, n <= 1024 { name = "fftBlockFinish" + suffix }
                guard let e = command.makeComputeCommandEncoder(), var pipeline = pipelines[name] else {
                    throw RenderError.unavailable("无法创建分块 FFT 指令。")
                }
                var block = min(1024,n)
                while block/2 > pipeline.maxTotalThreadsPerThreadgroup || block*16 > device.maxThreadgroupMemoryLength {block/=2}
                if name == "fftBlockFinish" + suffix, block < n {
                    // Smaller devices finish in the last global butterfly pass.
                    pipeline = pipelines[regularBlock]!
                    while block/2 > pipeline.maxTotalThreadsPerThreadgroup || block*16 > device.maxThreadgroupMemoryLength { block /= 2 }
                }
                let finalBlock = axis == 1 && block == n && finish != nil
                p.span = UInt32(block)
                e.label = name
                e.setComputePipelineState(pipeline)
                e.setTexture(axis == 0 ? (sceneInput ?? source):source,index:0)
                e.setTexture(finalBlock ? finish!.target:scratch,index:1)
                if let multiply, axis == 0 { e.setTexture(multiply,index:2) }
                if finalBlock { e.setTexture(finish!.scene,index:3) }
                e.setBytes(&p,length:MemoryLayout<FFTParameters>.stride,index:0)
                e.setThreadgroupMemoryLength(block*16,index:0)
                e.dispatchThreadgroups(MTLSize(width:n/block,height:axis == 0 ? source.height:source.width,depth:1),
                                       threadsPerThreadgroup:MTLSize(width:max(1,block/2),height:1,depth:1))
                e.endEncoding()
                if finalBlock { return }
                span = block*2
            }
            swap(&source,&scratch)
            while span <= n {
                p.span = UInt32(span)
                let finalStage = axis == 1 && span == n && finish != nil
                var textures = [(0,source),(1,finalStage ? finish!.target:scratch)]
                if finalStage { textures.append((2,finish!.scene)) }
                try encode(finalStage ? "fftStagePairFinish":(useReferenceFFT ? "fftStage":"fftStagePair"),command:command,
                           textures:textures,params:p,
                           width:source.width / (!useReferenceFFT && axis == 0 ? 2:1),
                           height:source.height / (!useReferenceFFT && axis == 1 ? 2:1))
                if finalStage { return }
                swap(&source,&scratch); span *= 2
            }
        }
    }
    static func synthesized(height: Int, glow: Double, scale: Double, referenceCore: Bool = false) -> (Int,[Float]) {
        let s = Double(height)/800*scale
        let radius = max(4,Int(ceil(80*s))), size = radius*2+1
        // Synthetic fit: a compact optical core plus multi-scale veiling wings.
        // Weights sum to unity, so the PSF redistributes rather than adds energy.
        let scatter = min(0.72,max(0,glow*0.24))
        // Keep the broad lens wings at their angular size. Bound only the
        // synthetic sharp core, so enlarging a panel can reveal material detail.
        // Measured PSFs retain their own core and are never sharpened here.
        let core = referenceCore ? 0.65*s : min(0.65*s,0.85*scale)
        let sigmas = [core,3.0*s,12.0*s,32.0*s]
        let weights = [1-scatter,scatter*0.35,scatter*0.42,scatter*0.23]
        var kernel = [Double](repeating:0,count:size*size)
        for (sigma,weight) in zip(sigmas,weights) {
            var component = [Double](repeating:0,count:size*size); var sum = 0.0
            for y in -radius...radius { for x in -radius...radius {
                let v = exp(-Double(x*x+y*y)/(2*sigma*sigma))
                component[(y+radius)*size+x+radius] = v; sum += v
            }}
            for i in kernel.indices { kernel[i] += component[i]/sum*weight }
        }
        return (size,kernel.map(Float.init))
    }
    static func resample(_ measured: MeasuredPSF, height: Int, scale: Double) -> (Int,[Float]) {
        let pitch = measured.pitchAt800*Double(height)/800*scale
        let radius = max(1,Int(ceil(Double(measured.size/2)*pitch))), size = radius*2+1
        var values = [Double](repeating:0,count:size*size)
        // Flux-conserving splatting of the measured samples, with bilinear
        // reconstruction at the destination sampling pitch. This remains valid
        // when a narrow measured core is smaller than one output pixel.
        for iy in 0..<measured.size { for ix in 0..<measured.size {
            let x = Double(ix-measured.size/2)*pitch+Double(radius)
            let y = Double(iy-measured.size/2)*pitch+Double(radius)
            let xx = Int(floor(x)), yy = Int(floor(y)), fx = x-floor(x), fy = y-floor(y)
            for dy in 0...1 { for dx in 0...1 {
                if (0..<size).contains(xx+dx) && (0..<size).contains(yy+dy) {
                    values[(yy+dy)*size+xx+dx] += measured.values[iy*measured.size+ix] * (dx == 0 ? 1-fx:fx) * (dy == 0 ? 1-fy:fy)
                }
            }}
        }}
        let sum = values.reduce(0,+)
        return (size,values.map {Float($0/sum)})
    }
    func apply(command: MTLCommandBuffer, scene: MTLTexture, target: MTLTexture,
               glow: Double, scale: Double, measured: MeasuredPSF?, revision: Int,
               override: (Int,[Float])? = nil) throws {
        let key = "\(scene.width)x\(scene.height):\(glow):\(scale):\(revision):\(override != nil):\(useReferenceFFT):\(useReferenceCore):\(useFusedPasses)"
        let rebuild = key != cachedKey || override != nil
        if rebuild {
            if let measured, Double(measured.size/2)*measured.pitchAt800*Double(scene.height)/800*scale > 512 {
                throw RenderError.unavailable("PSF 支持范围超过 1025 像素，请缩小采样间距或镜头扩散尺度。")
            }
            (kernelSize,kernel) = override ?? measured.map {Self.resample($0,height:scene.height,scale:scale)} ?? Self.synthesized(height:scene.height,glow:glow,scale:scale,referenceCore:useReferenceCore)
            guard kernelSize <= 1025, kernel.allSatisfy({$0.isFinite && $0>=0}), kernel.reduce(0,+)>0 else {
                throw RenderError.unavailable("PSF 支持范围过大或归一化无效，请缩小镜头扩散尺度。")
            }
            func power2(_ n:Int)->Int {var v=1;while v<n{v*=2};return v}
            // We return only the original image rectangle, not the full
            // convolution tail. A zero gap >= radius prevents any wrapped
            // source texel entering that crop: N-radius >= imageSize.
            // N >= kernelSize additionally keeps positive/negative kernel
            // offsets distinct, including kernels wider than a small image.
            // The reference retains full-convolution padding for comparison.
            let padding = useReferenceFFT ? kernelSize-1:kernelSize/2
            let w = power2(max(scene.width+padding,kernelSize))
            let h = power2(max(scene.height+padding,kernelSize))
            if a?.width != w || a?.height != h {
                a = try texture(w,h); b = try texture(w,h); spectrum = try texture(w,h)
            }
            paddingWidth = w; paddingHeight = h
        }
        guard var source=a,var scratch=b,let spectrum else {throw RenderError.unavailable("镜头卷积未就绪。")}
        if rebuild {
            let data = kernel.withUnsafeBytes {device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}
            guard let data else {throw RenderError.unavailable("无法创建 PSF 缓冲区。")}
            var p = FFTParameters(source.width,source.height);p.kernelSize=UInt32(kernelSize)
            try encode("fftLoadKernel",command:command,textures:[(0,source)],params:p,paramIndex:1,buffer:data,width:source.width,height:source.height)
            try fft(command:command,source:&source,scratch:&scratch,inverse:false)
            guard let blit=command.makeBlitCommandEncoder() else {throw RenderError.unavailable("无法缓存 PSF。")}
            blit.copy(from:source,to:spectrum);blit.endEncoding()
        }
        if useFusedPasses && !useReferenceFFT {
            try fft(command:command,source:&source,scratch:&scratch,inverse:false,sceneInput:scene)
            try fft(command:command,source:&source,scratch:&scratch,inverse:true,multiply:spectrum,finish:(scene,target))
        } else {
            try encode("fftLoadScene",command:command,textures:[(0,scene),(1,source)],width:source.width,height:source.height)
            try fft(command:command,source:&source,scratch:&scratch,inverse:false)
            try encode("fftMultiply",command:command,textures:[(0,source),(1,spectrum),(2,scratch)],width:source.width,height:source.height)
            swap(&source,&scratch)
            try fft(command:command,source:&source,scratch:&scratch,inverse:true)
            try encode("fftFinish",command:command,textures:[(0,source),(1,scene),(2,target)],width:target.width,height:target.height)
        }
        cachedKey = key
    }
}
