// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func runDefaultsChecks(renderer: BlackHoleRenderer, output: URL) throws {
    let settings=renderer.settings
    settings.restoreAppearance()
    defer {settings.restoreAppearance()}
    let fresh=Settings(persistent:false)
    var checks=["fresh_default_size_360":fresh.size==360,
                "fresh_default_spin_zero":fresh.spin==0,
                "reset_default_size_and_spin":settings.size==360 && settings.spin==0]
    let screens:[(Double,Double,Double)]=[(1920,1080,1728),(2560,1600,2560),(3440,1440,2304),(1080,1920,1080)]
    var cases=[[String:Double]]()
    for (w,h,expected) in screens {
        let screen=CGSize(width:w,height:h)
        settings.updateSizeLimit(screenSize:screen)
        settings.size=settings.maximumSize
        checks["full_screen_fit_\(Int(w))_\(Int(h))"]=settings.size==expected && settings.size<=w && settings.size/1.6<=h
        checks["speed_compensation_\(Int(w))_\(Int(h))"]=abs(settings.effectiveSpeed*settings.size-38)<1e-10
        cases.append(["screen_width_pt":w,"screen_height_pt":h,"maximum_width_pt":settings.maximumSize])
    }
    settings.updateSizeLimit(screenSize:CGSize(width:2560,height:1600));settings.size=2560
    settings.updateSizeLimit(screenSize:CGSize(width:1280,height:800))
    checks["smaller_screen_clamps_current_size"]=settings.size==1280 && settings.maximumSize==1280
    settings.updateSizeLimit(screenSize:CGSize(width:2560,height:1600))
    checks["larger_screen_expands_limit_only"]=settings.size==1280 && settings.maximumSize==2560
    settings.restoreAppearance()
    settings.size=900;settings.speed=0.025;settings.brightness=1.8;settings.setPalette(.blue)
    settings.setMovieParameters()
    checks["movie_button_sets_positive_0600"]=settings.spin==0.6
    checks["movie_button_preserves_size_speed_color"]=settings.size==900 && settings.speed==0.025 && settings.brightness==1.8 && settings.selectedPalette == .blue
    settings.restoreAppearance()
    checks["reset_after_movie_returns_zero"]=settings.spin==0 && settings.size==360
    let zero=try renderer.snapshot(to:output.appendingPathComponent("default-spin-zero.png"),width:720,height:450,background:1)
    settings.setMovieParameters()
    let movie=try renderer.snapshot(to:output.appendingPathComponent("movie-spin-0600.png"),width:720,height:450,background:1)
    let changed=stride(from:0,to:zero.count,by:4).filter {abs(Int(zero[$0])-Int(movie[$0]))>3}.count
    checks["movie_spin_changes_gpu_image"]=changed>1000
    let report:[String:Any]=["checks":checks,"screens":cases,"movie_changed_pixels":changed,
        "note":"Synthetic screen bounds test the sizing policy. Actual multi-monitor moves still require native testing. GPU targets are capped at 3840 pixels wide."]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        .write(to:output.appendingPathComponent("defaults-and-size.json"),options:.atomic)
    guard checks.values.allSatisfy({$0}) else {throw RenderError.unavailable("默认值、电影参数或全屏尺寸检查失败。")}
}
