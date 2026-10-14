// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import QuartzCore

func runSamplingOptimizationChecks(output: URL) throws {
    guard !FileManager.default.fileExists(atPath:output.path) else { throw RenderError.unavailable("采样测试目录已存在。") }
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    let settings=Settings(persistent:false);settings.restoreAppearance()
    let renderer=try BlackHoleRenderer(settings:settings)
    var cases=[[String:Any]]()
    let inputs:[(String,Int,Int,Float,Double,Double)] = [("small",540,338,12,0,8),("maximum",3840,2400,12,0,8),
        ("spin",720,450,35.75,0.998,2),("retrograde",720,450,-1,-0.998,35),
        ("relativistic",540,338,12,0.6,8),("zero-shutter",540,338,12,0,8),("no-filter",540,338,12,0,8),
        ("reference-filter",540,338,12,0,8),("static-material",540,338,12,0,8),("full-shutter",540,338,12,0,8)]
    for (name,w,h,time,spin,angle) in inputs {
        settings.restoreAppearance();settings.spin=spin;settings.inclination=angle
        settings.relativistic=name=="relativistic";settings.beamFiltering=name != "no-filter"
        if name=="zero-shutter" {settings.shutterAngle=0}
        if name=="full-shutter" {settings.shutterAngle=360}
        renderer.useReferenceFiltering=name=="reference-filter";renderer.useReferenceMaterial=name=="static-material"
        renderer.useSpecializedDisk=false
        let before=try renderer.snapshot(to:output.appendingPathComponent(name+"-before.png"),width:w,height:h,time:time)
        let linear=try renderer.scenePixels()
        renderer.useSpecializedDisk=true
        let after=try renderer.snapshot(to:output.appendingPathComponent(name+"-after.png"),width:w,height:h,time:time)
        let next=try renderer.scenePixels()
        let delta=zip(before,after).filter {$0 != $1}.count
        var changed=0,maxError:Float=0
        for (a,b) in zip(linear,next) {for i in 0..<4 {if a[i].bitPattern != b[i].bitPattern {changed += 1};maxError=max(maxError,abs(a[i]-b[i]))}}
        cases.append(["name":name,"changed_rgba":delta,"changed_linear":changed,"max_linear_difference":maxError])
    }
    let data:[String:Any] = ["images":cases,"checks":["images_exact":cases.allSatisfy {($0["changed_rgba"] as! Int)==0 && ($0["changed_linear"] as! Int)==0}]]
    try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
    guard (data["checks"] as! [String:Bool]).values.allSatisfy({$0}) else {throw RenderError.unavailable("盘面采样对照失败。")}
}
