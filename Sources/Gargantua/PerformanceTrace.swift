// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Metal
import QuartzCore
import Darwin

// Opt-in, offscreen diagnostics. Normal rendering never creates either class.
// No frame pixels, desktop metadata, preferences, or external services here.
final class PeakMemory {
    private let device: MTLDevice
    private let queue = DispatchQueue(label: "local.gargantua.baseline-memory")
    private var timer: DispatchSourceTimer?
    private var peaks: [String: UInt64] = [:]
    private var count = 0
    private var failures = 0

    init(device: MTLDevice) { self.device = device }

    static func process() -> [String: UInt64]? {
        var value = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &value) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        return ["physical_footprint_bytes": value.ri_phys_footprint,
                "resident_bytes": value.ri_resident_size,
                "lifetime_max_physical_footprint_bytes": value.ri_lifetime_max_phys_footprint]
    }

    private func sample() {
        count += 1
        var values = Self.process() ?? [:]
        if values.isEmpty { failures += 1 }
        values["metal_allocated_bytes"] = UInt64(device.currentAllocatedSize)
        for (key, value) in values { peaks[key] = max(peaks[key] ?? 0, value) }
    }
    func start() {
        queue.sync { sample() }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in self?.sample() }
        timer = source; source.resume()
    }
    func checkpoint() { queue.sync { sample() } }
    func stop() -> [String: Any] {
        timer?.cancel(); timer = nil
        return queue.sync {
            sample()
            return ["sampled_peaks": peaks, "samples": count, "process_read_failures": failures,
                    "requested_interval_ms": 5,
                    "note": "Metal/resident/footprint sampled peaks may miss shorter spikes. Lifetime physical-footprint maximum is an OS high-water mark for this fresh worker, including initialization. These metrics overlap; do not add them."]
        }
    }
    deinit { timer?.cancel() }
}

final class FrameProfile {
    private struct Pass {
        let stage: String
        let label: String
        let first: Int
        let render: Bool
    }
    private let device: MTLDevice
    private let buffer: MTLCounterSampleBuffer?
    private let firstClock: (cpu: MTLTimestamp, gpu: MTLTimestamp)?
    private let unavailable: String?
    private var passes: [Pass] = []
    private var next = 0
    private var cpuStarts: [String: Double] = [:]
    private var cpuMS: [String: Double] = [:]
    private let memory: PeakMemory?
    private static let capacity = 512

    init(device: MTLDevice, counters: Bool = true, memory: PeakMemory? = nil) throws {
        self.device = device; self.memory = memory
        if counters, device.supportsCounterSampling(.atStageBoundary),
           let set = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue }) {
            let descriptor = MTLCounterSampleBufferDescriptor()
            descriptor.counterSet = set; descriptor.storageMode = .shared
            descriptor.sampleCount = Self.capacity; descriptor.label = "Offscreen phase timestamps"
            buffer = try device.makeCounterSampleBuffer(descriptor: descriptor)
            firstClock = device.sampleTimestamps(); unavailable = nil
        } else {
            buffer = nil; firstClock = nil
            unavailable = counters ? "Stage-boundary timestamp counters unavailable on this device" : "Counters disabled for memory-only pass"
        }
    }
    func beginCPU(_ stage: String) { cpuStarts[stage] = CACurrentMediaTime() }
    func endCPU(_ stage: String) {
        if let start = cpuStarts.removeValue(forKey: stage) {
            cpuMS[stage, default: 0] += (CACurrentMediaTime() - start) * 1000
        }
        memory?.checkpoint()
    }
    private func reserve(_ stage: String, _ label: String, render: Bool = false) -> Int {
        let index = next; next += render ? 4 : 2
        precondition(next <= Self.capacity, "Too many profiling samples")
        passes.append(Pass(stage: stage, label: label, first: index, render: render))
        return index
    }
    func compute(_ command: MTLCommandBuffer, stage: String, label: String) -> MTLComputeCommandEncoder? {
        guard let buffer else { return command.makeComputeCommandEncoder() }
        let index = reserve(stage, label)
        let descriptor = MTLComputePassDescriptor()
        descriptor.dispatchType = .serial
        let sample = descriptor.sampleBufferAttachments[0]!
        sample.sampleBuffer = buffer
        sample.startOfEncoderSampleIndex = index; sample.endOfEncoderSampleIndex = index + 1
        return command.makeComputeCommandEncoder(descriptor: descriptor)
    }
    func blit(_ command: MTLCommandBuffer, stage: String, label: String) -> MTLBlitCommandEncoder? {
        guard let buffer else { return command.makeBlitCommandEncoder() }
        let index = reserve(stage, label)
        let descriptor = MTLBlitPassDescriptor()
        let sample = descriptor.sampleBufferAttachments[0]!
        sample.sampleBuffer = buffer
        sample.startOfEncoderSampleIndex = index; sample.endOfEncoderSampleIndex = index + 1
        return command.makeBlitCommandEncoder(descriptor: descriptor)
    }
    func render(_ descriptor: MTLRenderPassDescriptor, stage: String) {
        guard let buffer else { return }
        let index = reserve(stage, stage, render: true)
        let sample = descriptor.sampleBufferAttachments[0]!
        sample.sampleBuffer = buffer
        sample.startOfVertexSampleIndex = index; sample.endOfVertexSampleIndex = index + 1
        sample.startOfFragmentSampleIndex = index + 2; sample.endOfFragmentSampleIndex = index + 3
    }
    // Resolve only after GPU completion, outside the timed command. Apple's
    // paired timestamps convert GPU ticks to CPU nanoseconds, not guessed units.
    func resolve() throws -> [String: Any] {
        var report: [String: Any] = ["cpu_encode_stages_ms": cpuMS,
                                   "timestamp_status": unavailable ?? "available"]
        guard let buffer, let firstClock else { return report }
        let last = device.sampleTimestamps()
        guard last.cpu > firstClock.cpu, last.gpu > firstClock.gpu,
              let data = try buffer.resolveCounterRange(0..<next),
              data.count >= next * MemoryLayout<MTLCounterResultTimestamp>.stride else {
            throw RenderError.unavailable("GPU 时间戳校准或读取失败。")
        }
        let scale = Double(last.cpu - firstClock.cpu) / Double(last.gpu - firstClock.gpu) / 1_000_000
        var values = [UInt64](repeating: 0, count: next)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        var stages: [String: Double] = [:], vertices: [String: Double] = [:], records = [[String: Any]]()
        for pass in passes {
            let i = pass.first
            let indices = pass.render ? Array(i..<(i+4)) : Array(i..<(i+2))
            guard indices.allSatisfy({values[$0] != 0 && values[$0] != UInt64.max}),
                  values[i+1] >= values[i], !pass.render || values[i+3] >= values[i+2] else {
                throw RenderError.unavailable("GPU 阶段时间戳无效：\(pass.label)")
            }
            // Tiled GPUs may run vertices long before dependent compute is
            // finished. The vertex-to-fragment envelope would misattribute
            // that wait to this pass. Report fragment duration, vertex duration
            // and envelope separately rather than summing overlapping spans.
            let start = pass.render ? values[i+2] : values[i]
            let end = pass.render ? values[i+3] : values[i+1]
            let duration = Double(end - start) * scale
            stages[pass.stage, default: 0] += duration
            var record: [String:Any] = ["stage": pass.stage, "pass": pass.label, "milliseconds": duration,
                            "start_gpu_ticks": start, "end_gpu_ticks": end]
            if pass.render {
                let vertex = Double(values[i+1]-values[i])*scale
                vertices[pass.stage,default:0] += vertex
                record["vertex_ms"]=vertex
                record["vertex_start_gpu_ticks"]=values[i];record["vertex_end_gpu_ticks"]=values[i+1]
                record["vertex_fragment_envelope_ms"]=Double(max(values[i+1],values[i+3])-min(values[i],values[i+2]))*scale
            }
            records.append(record)
        }
        report["gpu_stages_ms"] = stages; report["gpu_passes"] = records
        report["gpu_vertex_stages_ms"] = vertices
        report["gpu_tick_to_ms"] = scale
        report["note"] = "Includes the geometry/count prefix on demand-allocation cache misses and the final frame command. Render stage values are FRAGMENT durations; vertices and vertex/fragment envelopes are separate. Stage sums need not equal command duration because of scheduling gaps/overlap. Sampling can perturb timing; compare paired uninstrumented frames. CPU stage values exclude profile construction/resolution."
        return report
    }
}

func profiledCompute(_ command: MTLCommandBuffer, _ profile: FrameProfile?, _ stage: String, _ label: String = "") -> MTLComputeCommandEncoder? {
    if let profile { return profile.compute(command, stage: stage, label: label.isEmpty ? stage : label) }
    return command.makeComputeCommandEncoder()
}
func profiledBlit(_ command: MTLCommandBuffer, _ profile: FrameProfile?, _ stage: String, _ label: String = "") -> MTLBlitCommandEncoder? {
    if let profile { return profile.blit(command, stage: stage, label: label.isEmpty ? stage : label) }
    return command.makeBlitCommandEncoder()
}
