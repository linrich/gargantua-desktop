// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation

// Deterministic clock and generated event tokens; no AppKit windows or capture.
private final class EventTestClock {
    var time=0.0
    var jobs=[(Double,()->Void)]()
    func schedule(_ delay:Double,_ action:@escaping ()->Void) { jobs.append((time+delay,action)) }
    func next() {
        jobs.sort {$0.0<$1.0}
        guard !jobs.isEmpty else {return}
        let job=jobs.removeFirst();time=max(time,job.0);job.1()
    }
    func drain() { var budget=1000;while !jobs.isEmpty && budget>0 {budget-=1;next()};precondition(budget>0) }
}
func runDesktopEventChecks(output: URL) throws {
    guard !FileManager.default.fileExists(atPath:output.path) else {throw RenderError.unavailable("事件测试目录已存在。")}
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    var checks=[String:Bool](),calls=0,failures=0,inside=false,latest=0,seen=[Int]()
    let clock=EventTestClock()
    var driver:DesktopEventDriver!
    driver=DesktopEventDriver(now:{clock.time},schedule:clock.schedule) {
        calls+=1;seen.append(latest)
        if inside {inside=false;latest+=1;driver.request()}
        if failures>0 {failures-=1;return false}
        return true
    }
    driver.request();checks["inactive_has_no_callback"] = clock.jobs.isEmpty
    driver.setActive(true,fps:30)
    for _ in 0..<100 {latest+=1;driver.request()}
    checks["burst_coalesces_to_one_callback"] = clock.jobs.count==1
    clock.drain();checks["latest_event_rendered"] = calls==1 && seen.last==100
    let saved=calls;clock.time+=10
    checks["idle_has_no_timer_or_draw"] = clock.jobs.isEmpty && calls==saved
    inside=true;driver.request();clock.drain()
    checks["event_during_render_is_not_lost"] = calls==saved+2 && seen.suffix(2)==[100,101]
    let start=calls;failures=3;driver.request();clock.drain()
    checks["missing_drawable_retries_until_satisfied"] = calls==start+4 && clock.jobs.isEmpty
    driver.request();driver.setActive(false,fps:30);clock.drain()
    checks["disable_cancels_queued_draw"] = calls==start+4
    driver.setActive(true,fps:24);clock.drain()
    let last=clock.time;driver.request()
    checks["eco_preserves_24_hz_limit"] = abs(clock.jobs.first!.0-last-1/24.0)<1e-8
    driver.invalidate()
    checks["surface_invalidated_wakes_immediately"] = clock.jobs.contains {$0.0==clock.time}
    let invalidated=calls;clock.drain()
    checks["old_surface_callback_cancelled"] = calls==invalidated+1
    let concurrent=calls
    DispatchQueue.concurrentPerform(iterations:1000) {_ in driver.request()}
    checks["cross_queue_burst_coalesces"] = clock.jobs.count==1
    clock.drain();checks["cross_queue_burst_renders_once"] = calls==concurrent+1
    driver.setActive(false,fps:30)
    var scenarios=[[String:Any]]()
    for (name,period,moving) in [("static",120,false),("10hz",3,false),("30hz",1,false),("drag",120,true)] {
        let c=EventTestClock();var count=0,events=0
        let d=DesktopEventDriver(now:{c.time},schedule:c.schedule) { count+=1;return true }
        d.setActive(true,fps:30)
        for tick in 0..<120 {
            c.time=max(c.time,Double(tick)/30)
            if tick%period==0 || moving {events+=1;d.request()}
            c.drain()
        }
        let expected=moving ? 120:119/period+1
        checks[name+"_event_count"] = count==expected
        scenarios.append(["scenario":name,"periodic_callbacks":120,"event_callbacks":count,"input_events":events])
        d.setActive(false,fps:30)
    }
    // Exercise the production scheduler in another common run-loop mode too;
    // event tracking must not strand a frame until dragging ends. No windows.
    let mode=RunLoop.Mode("Gargantua.EventValidation")
    CFRunLoopAddCommonMode(CFRunLoopGetMain(),CFRunLoopMode(rawValue:mode.rawValue as CFString))
    // An otherwise empty CLI run-loop mode exits before servicing blocks.
    // AppKit normally supplies sources; this unfired one-shot keeps it alive.
    let keeper=Timer(timeInterval:5,repeats:false) {_ in }
    RunLoop.main.add(keeper,forMode:mode)
    defer {keeper.invalidate()}
    var realCalls=0,mainOnly=true
    let real=DesktopEventDriver {realCalls+=1;mainOnly = mainOnly && Thread.isMainThread;return true}
    func pump(until count:Int) {
        let deadline=Date().addingTimeInterval(2)
        while realCalls<count && Date()<deadline {
            _=RunLoop.main.run(mode:mode,before:Date().addingTimeInterval(0.02))
        }
    }
    real.setActive(true,fps:30);pump(until:1)
    DispatchQueue.concurrentPerform(iterations:100) {_ in real.request()}
    pump(until:2)
    checks["production_common_mode_wakes_and_coalesces"] = realCalls==2 && mainOnly
    real.setActive(false,fps:30)
    try JSONSerialization.data(withJSONObject:["checks":checks,"scenarios":scenarios,"production_callbacks":realCalls,"production_callbacks_on_main":mainOnly,
        "scope":"Synthetic events, deterministic scheduler and production common-run-loop dispatch only; no live display/capture/power or MTKView latency measurement."],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
    guard checks.values.allSatisfy({$0}) else {throw RenderError.unavailable("背景事件检查失败：\(checks.filter {!$0.value}.keys)")}
    print("背景事件检查通过：\(checks.count) 项。")
}
