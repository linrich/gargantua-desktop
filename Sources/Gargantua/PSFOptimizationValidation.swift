// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Metal

// Generated Float32 HDR inputs, before display quantization. This exercises
// both FFT axes, partial crops, three global stages and asymmetric kernels.
// The baseline switch retains the previous shader schedule and RGBA spectrum.
func runPSFOptimizationChecks(directory: URL) throws {
    guard !FileManager.default.fileExists(atPath:directory.path) else {
        throw RenderError.unavailable("PSF 对照目录已存在，拒绝覆盖。")
    }
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    let renderer=try BlackHoleRenderer(settings:Settings(persistent:false))
    guard let queue=renderer.device.makeCommandQueue() else {throw RenderError.unavailable("无法创建 PSF 测试队列。")}
    let cases:[(String,Int,Int)] = [
        ("single",1,1),("asymmetric",23,17),("kernel-wider-than-image",2,3),("crop-edge",29,29),
        ("one-stage-x",1031,19),("two-stages-x",2051,19),("two-stages-y",19,2051),
        ("mixed-axes",1031,2051),("transposed-axes",2051,1031),
        ("three-stages-x",4097,17),("three-stages-y",17,4097),
        ("two-large-axes",2051,2053),("wide-large",4097,2051),("support-1025",2051,19)]
    var reports=[[String:Any]]()
    for (name,w,h) in cases {
        let report=try autoreleasepool { () throws -> [String:Any] in
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:w,height:h,mipmapped:false)
            d.storageMode = .shared; d.usage = [.shaderRead,.shaderWrite]
            guard let input=renderer.device.makeTexture(descriptor:d),let target=renderer.device.makeTexture(descriptor:d),
                  let read=renderer.device.makeBuffer(length:w*h*16,options:.storageModeShared) else {
                throw RenderError.unavailable("无法创建 PSF 对照纹理。")
            }
            var pixels=[Float](repeating:0,count:w*h*4)
            for y in 0..<h {for x in 0..<w {
                let i=(y*w+x)*4
                pixels[i]=Float((x*17+y*11)%31)/7
                pixels[i+1]=Float((x*5+y*13)%19)/5
                pixels[i+2]=Float((x*3+y*7)%23)/3
                pixels[i+3]=Float((x*17+y*3)%255)/255
            }}
            pixels.withUnsafeBytes { input.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:w*16) }
            var kernel:[Float] = name == "single" ? [1]:[0,0,0.04,0,0, 0,0.02,0.05,0,0, 0.1,0.07,0.5,0.09,0, 0,0.03,0.06,0,0, 0,0,0.04,0,0]
            let size=name == "single" ? 1:(name == "support-1025" ? 1025:5),radius=size/2
            if size == 1025 {
                kernel=[Float](repeating:0,count:size*size)
                for (x,y,v):(Int,Int,Float) in [(0,0,0.4),(512,0,0.1),(-512,0,0.2),(1,-512,0.2),(50,512,0.1)] {
                    kernel[(y+radius)*size+x+radius]=v
                }
            }
            let nonzero=kernel.enumerated().filter {$0.element != 0}
            var before=[UInt32](),after=[UInt32](),bytes=[Int]()
            for optimized in [false,true] {
                renderer.lens.useCompactPSF=optimized
                renderer.lens.useGroupedColumns=optimized
                guard let command=queue.makeCommandBuffer() else {throw RenderError.unavailable("PSF 对照指令失败。")}
                try renderer.lens.apply(command:command,scene:input,target:target,glow:0,scale:1,measured:nil,revision:0,override:(size,kernel))
                guard let blit=command.makeBlitCommandEncoder() else {throw RenderError.unavailable("PSF 对照读回失败。")}
                blit.copy(from:target,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),sourceSize:MTLSize(width:w,height:h,depth:1),
                          to:read,destinationOffset:0,destinationBytesPerRow:w*16,destinationBytesPerImage:w*h*16)
                blit.endEncoding();command.commit();command.waitUntilCompleted()
                if let error=command.error {throw error}
                guard command.status == .completed else {throw RenderError.unavailable("PSF 对照指令未完成。")}
                let values=Array(UnsafeBufferPointer(start:read.contents().bindMemory(to:UInt32.self,capacity:w*h*4),count:w*h*4))
                if optimized {after=values} else {before=values}
                bytes.append(renderer.lens.allocatedBytes)
            }
            var maximum:Float=0,changed=0,alpha=0,finite=true,cpuError:Float=0
            for i in before.indices {
                let a=Float(bitPattern:before[i]),b=Float(bitPattern:after[i])
                finite = finite && a.isFinite && b.isFinite
                maximum=max(maximum,abs(a-b))
                if before[i] != after[i] {changed+=1;if i%4 == 3 {alpha+=1}}
            }
            // Direct spatial convolution at corners, edges and the interior
            // also checks padding, kernel orientation and boundary behavior.
            for y in Set([0,min(1,h-1),h/2,max(0,h-2),h-1]) {
                for x in Set([0,min(1,w-1),w/2,max(0,w-2),w-1]) {for channel in 0..<4 {
                    var expected:Float=channel == 3 ? pixels[(y*w+x)*4+3]:0
                    if channel < 3 {for sample in nonzero {
                        let sx=x-(sample.offset%size-radius),sy=y-(sample.offset/size-radius)
                        if (0..<w).contains(sx)&&(0..<h).contains(sy) {expected+=pixels[(sy*w+sx)*4+channel]*sample.element}
                    }}
                    cpuError=max(cpuError,abs(expected-Float(bitPattern:after[(y*w+x)*4+channel])))
                }}
            }
            return ["case":name,"width":w,"height":h,"fft_resolution":[renderer.lens.paddingWidth,renderer.lens.paddingHeight],
                    "changed_float32_components":changed,"max_absolute_difference":maximum,"alpha_changes":alpha,
                    "sampled_direct_cpu_max_error":cpuError,"baseline_psf_bytes":bytes[0],"optimized_psf_bytes":bytes[1],
                    "checks":["bit_exact_float32":changed == 0,"finite":finite,"unchanged_alpha":alpha == 0,
                              "direct_cpu_convolution":cpuError<0.0001,"no_memory_increase":bytes[1]<=bytes[0]]]
        }
        reports.append(report)
        try JSONSerialization.data(withJSONObject:["gpu":renderer.device.name,"cases":reports],options:[.prettyPrinted,.sortedKeys])
            .write(to:directory.appendingPathComponent("psf-float32-equivalence.json"),options:.atomic)
        print("PSF Float32 对照：\(name)，变化分量 \(report["changed_float32_components"]!)");fflush(stdout)
    }
    guard reports.allSatisfy({($0["checks"] as! [String:Bool]).values.allSatisfy({$0})}) else {
        throw RenderError.unavailable("PSF Float32 对照失败，详见生成报告。")
    }
}
