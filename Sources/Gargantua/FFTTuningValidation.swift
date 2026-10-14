// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func runFFTTuning(output: URL) throws {
    guard !FileManager.default.fileExists(atPath:output.path) else {throw RenderError.unavailable("FFT 测试目录已存在。")}
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    let settings=Settings(persistent:false);settings.restoreAppearance()
    let renderer=try BlackHoleRenderer(settings:settings)
    var rows=[[String:Any]]()
    for (name,w,h,scale) in [("large",2400,1500,1.0),("maximum",3840,2400,1.0),("wide",3840,2400,2.0)] {
        settings.lensScale=scale
        let shapes=[1,4]
        for round in 0..<4 {
            for columns in (round%2==0 ? shapes:Array(shapes.reversed())) {
                renderer.lens.useGroupedColumns=columns==4
                var report=try renderer.benchmark(width:w,height:h,frames:16,lensOnly:true)
                report["case"]=name;report["round"]=round;report["group"]="columns-\(columns)"
                rows.append(report)
                print("FFT \(name) \(round) columns-\(columns): \(report["gpu_median_ms"]!) ms")
            }
        }
    }
    try JSONSerialization.data(withJSONObject:["rows":rows],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
}
