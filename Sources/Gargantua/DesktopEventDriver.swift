// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import QuartzCore

// Events contain no frame pixels. Request may run on the capture queue; rendering
// runs in the main run loop's common modes (including window dragging).
final class DesktopEventDriver {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    private let lock = NSLock()
    private let schedule: Schedule
    private let now: () -> TimeInterval
    private let render: () -> Bool
    private var active = false
    private var pending = false
    private var generation = 0
    private var interval = 1.0/30
    private var lastAttempt: TimeInterval?
    private var retries = 0

    init(now: @escaping () -> TimeInterval = { CACurrentMediaTime() },
         schedule: @escaping Schedule = DesktopEventDriver.scheduleOnMain,
         render: @escaping () -> Bool) {
        self.now=now; self.schedule=schedule; self.render=render
    }
    private static func scheduleOnMain(delay: TimeInterval, action: @escaping () -> Void) {
        RunLoop.main.perform(inModes:[.common]) {
            if delay <= 0 { action() }
            else {
                let timer=Timer(timeInterval:delay,repeats:false) { _ in action() }
                RunLoop.main.add(timer,forMode:.common)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    func setActive(_ value: Bool, fps: Int) {
        let changed=lock.withLock { () -> Bool in
            interval=1.0/Double(max(1,fps))
            guard active != value else { return false }
            active=value; generation+=1; pending=false; lastAttempt=nil; retries=0
            return true
        }
        if changed && value { request() }
    }
    func request() { enqueue(retryDelay:0) }
    // Surface recreation/resume must not wait behind an unavailable-drawable retry.
    func invalidate() {
        lock.withLock { generation+=1; pending=false; lastAttempt=nil; retries=0 }
        request()
    }
    private func enqueue(retryDelay: TimeInterval) {
        let job=lock.withLock { () -> (Int,TimeInterval)? in
            guard active && !pending else { return nil }
            pending=true
            return (generation,max(retryDelay,max(0,(lastAttempt ?? -Double.infinity)+interval-now())))
        }
        guard let (token,delay)=job else { return }
        schedule(delay) { [weak self] in self?.run(token) }
    }
    private func run(_ token: Int) {
        let allowed=lock.withLock { () -> Bool in
            guard active && generation==token else { return false }
            pending=false; lastAttempt=now(); return true
        }
        guard allowed else { return }
        let satisfied=render()
        let retry=lock.withLock { () -> TimeInterval? in
            guard active && generation==token else { return nil }
            if satisfied { retries=0; return nil }
            retries=min(retries+1,4)
            return min(0.25,interval*pow(2,Double(retries-1)))
        }
        if let retry { enqueue(retryDelay:retry) }
    }
}
