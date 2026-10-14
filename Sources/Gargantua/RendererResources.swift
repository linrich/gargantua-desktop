// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Metal
import Foundation

// Owned by one overlay controller. Share only immutable device/library/pipeline
// objects; command queues, textures, clocks and PSF caches stay renderer-local.
final class RendererResources {
    let device: MTLDevice
    let library: MTLLibrary
    let lensPipelines: [String: MTLComputePipelineState]
    let geometryPipeline: MTLComputePipelineState
    let probePipeline: MTLComputePipelineState
    let bundleProbePipeline: MTLComputePipelineState
    let refinePipeline: MTLComputePipelineState
    let countBeamsPipeline: MTLComputePipelineState
    let filterProbePipeline: MTLComputePipelineState
    let materialPipeline: MTLComputePipelineState
    let materialProbePipeline: MTLComputePipelineState
    let desktopGeometryPipeline: MTLComputePipelineState
    let desktopLookupPipeline: MTLComputePipelineState
    let desktopMappingProbePipeline: MTLComputePipelineState
    let diskPipeline: MTLRenderPipelineState
    let specializedDiskPipeline: MTLRenderPipelineState
    let compositePipeline: MTLRenderPipelineState
    let desktopCompositePipeline: MTLRenderPipelineState
    let desktopBackgroundPipeline: MTLRenderPipelineState
    var pipelineCount: Int { 16 + lensPipelines.count }
    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RenderError.unavailable("这台 Mac 没有可用的 Metal 渲染设备。")
        }
        self.device = device
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
        self.library = library

        func compute(_ name: String) throws -> MTLComputePipelineState {
            if name == "probeMaterialEvolution" {
                let constants=MTLFunctionConstantValues();var enabled=false
                constants.setConstantValue(&enabled,type:.bool,index:3)
                let function=try library.makeFunction(name:name,constantValues:constants)
                return try device.makeComputePipelineState(function:function)
            }
            guard let function = library.makeFunction(name: name) else {
                throw RenderError.unavailable("缺少 Metal 入口：\(name)")
            }
            return try device.makeComputePipelineState(function: function)
        }
        func render(_ name: String, _ format: MTLPixelFormat, specialized: Bool = false) throws -> MTLRenderPipelineState {
            let selected: MTLFunction?
            if name == "bundleDiskFragment" {
                let constants=MTLFunctionConstantValues();var enabled=specialized
                constants.setConstantValue(&enabled,type:.bool,index:3)
                selected=try library.makeFunction(name:name,constantValues:constants)
            } else {selected=library.makeFunction(name:name)}
            guard let vertex = library.makeFunction(name: "fullScreenVertex"), let fragment=selected else {
                throw RenderError.unavailable("缺少 Metal 渲染入口：\(name)")
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertex; desc.fragmentFunction = fragment
            desc.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: desc)
        }
        geometryPipeline = try compute("beamGeometry")
        probePipeline = try compute("probeGeodesics")
        bundleProbePipeline = try compute("probeBundles")
        refinePipeline = try compute("refineBeams")
        countBeamsPipeline = try compute("countRefinedBeams")
        filterProbePipeline = try compute("probeEWA")
        materialPipeline = try compute("buildDiskMaterial")
        materialProbePipeline = try compute("probeMaterialEvolution")
        desktopGeometryPipeline = try compute("desktopGeometry")
        desktopLookupPipeline = try compute("probeDesktopLookup")
        desktopMappingProbePipeline = try compute("probeDesktopMapping")
        diskPipeline = try render("bundleDiskFragment", .rgba16Float)
        specializedDiskPipeline = try render("bundleDiskFragment", .rgba16Float,specialized:true)
        compositePipeline = try render("compositeFragment", .bgra8Unorm)
        desktopCompositePipeline = try render("desktopCompositeFragment", .bgra8Unorm)
        desktopBackgroundPipeline = try render("desktopBackgroundFragment", .bgra8Unorm)
        lensPipelines = try LensResponse.makePipelines(device: device, library: library)
    }
}
