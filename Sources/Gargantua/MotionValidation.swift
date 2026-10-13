// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func runMotionChecks(renderer: BlackHoleRenderer, output: URL) throws {
    let settings=renderer.settings
    settings.restoreAppearance()
    defer {settings.displayedWidth=0;settings.restoreAppearance()}
    func near(_ a:Double,_ b:Double)->Bool {abs(a-b)<1e-10}
    var checks=[String:Bool]()
    checks["fresh_and_reset_default_005"]=near(Settings(persistent:false).speed,0.05) && near(settings.speed,0.05)
    var sizes=[[String:Double]]()
    for width in [360.0,760,1000,1400] {
        settings.size=width
        let rate=settings.effectiveSpeed
        sizes.append(["width_pt":width,"reference_speed":settings.speed,"effective_speed":rate])
        checks["projected_travel_\(Int(width))"]=near(rate*width,0.05*760)
    }
    settings.size=1400; settings.displayedWidth=1000
    checks["screen_constrained_width_used"]=near(settings.effectiveSpeed,0.038)
    let rate=settings.effectiveSpeed
    for quality in RenderQuality.allCases {
        settings.quality=quality
        checks["quality_does_not_change_rate_\(quality.rawValue)"]=near(settings.effectiveSpeed,rate)
        checks["shutter_uses_compensated_rate_\(quality.rawValue)"]=near(settings.shutterDuration*Double(quality.fps),rate*0.5)
    }
    for fps in [24,30,60] {
        var clock=AnimationClock(wallTime:0)
        for frame in 1...fps {_ = clock.advance(to:Double(frame)/Double(fps),rate:0.05,paused:false)}
        checks["wall_time_rate_\(fps)_fps"]=near(clock.elapsed,0.05)
    }
    var clock=AnimationClock(wallTime:0)
    let first=clock.advance(to:0.1,rate:0.05,paused:false)
    let newRate=MotionTuning.effectiveSpeed(0.05,width:1400)
    let unchanged=clock.advance(to:0.1,rate:newRate,paused:false)
    let next=clock.advance(to:0.2,rate:newRate,paused:false)
    checks["resize_does_not_rephase"]=near(first,unchanged) && near(next,first+0.1*newRate)
    let paused=clock.advance(to:0.3,rate:newRate,paused:true)
    let stopped=clock.advance(to:0.4,rate:0,paused:false)
    clock.synchronize(to:100)
    let resumed=clock.advance(to:100.02,rate:0.05,paused:false)
    checks["pause_zero_and_resume_no_catchup"]=near(paused,next) && near(stopped,next) && near(resumed,next+0.001)
    settings.speed=0
    checks["zero_speed_zero_shutter"]=settings.effectiveSpeed==0 && settings.shutterDuration==0
    checks["slider_endpoints_and_low_speed_precision"]=[0.0,0.005,0.01,0.025,0.05,0.1,0.2,0.65,1,2].allSatisfy {
        near(MotionTuning.speed(at:MotionTuning.sliderPosition(for:$0)),$0)
    } && MotionTuning.sliderPosition(for:0.05)>0.3

    // With zero shutter and identical simulation time, changing the reference
    // rate/point size must not alter geometry, radiance or the cached material.
    settings.restoreAppearance();settings.displayedWidth=0;settings.shutterAngle=0
    let original=try renderer.snapshot(to:output.appendingPathComponent("motion-fixed-time-before.png"),width:640,height:400)
    let geometryCount=renderer.geometryBuildCount, materialCount=renderer.materialBuildCount
    settings.size=1400;settings.speed=2
    let after=try renderer.snapshot(to:output.appendingPathComponent("motion-fixed-time-after.png"),width:640,height:400)
    checks["speed_and_point_size_preserve_fixed_time_image"]=original==after
    checks["speed_does_not_rebuild_caches"]=renderer.geometryBuildCount==geometryCount && renderer.materialBuildCount==materialCount
    let result:[String:Any]=["checks":checks,"sizes":sizes,"note":"Point-travel normalization is an appearance heuristic, not a claim of identical subjective perception. Offscreen frames use explicit simulation time."]
    try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
        .write(to:output.appendingPathComponent("motion-timing.json"),options:.atomic)
    guard checks.values.allSatisfy({$0}) else {throw RenderError.unavailable("速度、尺寸补偿或动画时钟检查失败。")}
}
