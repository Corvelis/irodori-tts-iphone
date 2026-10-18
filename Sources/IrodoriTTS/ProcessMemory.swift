import Foundation
import Darwin

/// Whole-process physical footprint, in MiB. Missing readings are never reported as zero.
public enum ProcessMemory {
    public static func currentMiB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS, info.phys_footprint > 0 else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }
}

public struct MemoryObservation: Codable, Sendable {
    public var startMiB: Double?
    public var endMiB: Double?
    public var peakMiB: Double?
    public var sampleCount = 0
    public var readErrorCount = 0
    public var requestedIntervalMilliseconds = 10.0
    public var maximumSampleGapMilliseconds = 0.0
}

/// A fresh sampler per operation; the peak is observed, not the OS lifetime high-water mark.
public final class ProcessMemorySampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "IrodoriTTS.memory")
    private var timer: DispatchSourceTimer?
    private var value = MemoryObservation()
    private var lastSample: Double?
    private var finished = false
    private let reader: @Sendable () -> Double?

    public init(intervalMilliseconds: Double = 10, reader: @escaping @Sendable () -> Double? = { ProcessMemory.currentMiB() }) {
        precondition(intervalMilliseconds.isFinite && intervalMilliseconds >= 1)
        self.reader = reader
        value.requestedIntervalMilliseconds = intervalMilliseconds
        queue.sync { value.startMiB = sample() }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + intervalMilliseconds / 1000, repeating: intervalMilliseconds / 1000)
        source.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            _ = self.sample()
        }
        timer = source
        source.resume()
    }

    private func sample() -> Double? {
        let now = ProcessInfo.processInfo.systemUptime
        guard let current = reader(), current.isFinite, current > 0 else {
            value.readErrorCount += 1
            return nil
        }
        if let lastSample { value.maximumSampleGapMilliseconds = max(value.maximumSampleGapMilliseconds, (now - lastSample) * 1000) }
        lastSample = now
        value.sampleCount += 1
        value.peakMiB = max(value.peakMiB ?? current, current)
        return current
    }

    public func finish() -> MemoryObservation {
        queue.sync {
            if !finished {
                value.endMiB = sample()
                finished = true
                timer?.cancel()
            }
            return value
        }
    }

    deinit { timer?.cancel() }
}
