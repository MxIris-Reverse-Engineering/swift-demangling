import Darwin
import Foundation

/// Samples the process's physical footprint (`phys_footprint`, the ledger the
/// OS memory tooling reports) on a dedicated thread and keeps the peak seen
/// inside a start/stop window, reported relative to the baseline at `start()`.
///
/// Sampling runs at roughly 2 kHz, so only spikes that stay resident for a
/// fraction of a millisecond can slip between samples — a multi-megabyte
/// buffer-regrowth copy is comfortably wider than that. The measurement is
/// process-wide: keep unrelated work quiet while a window is open.
public final class PhysicalFootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var baselineFootprint: UInt64 = 0
    private var peakFootprint: UInt64 = 0
    private var keepsSampling = false
    private let samplingFinished = DispatchSemaphore(value: 0)

    public init() {}

    /// Records the baseline footprint and starts the sampling thread.
    /// - Precondition: no window is currently open. A second `start()` would
    ///   leave two sampling threads polling; the single `stop()` that follows
    ///   signals the semaphore twice but waits once, so the *next* window's
    ///   `stop()` returns before its own sampler has exited and silently
    ///   reports a peak belonging to another window.
    public func start() {
        let currentFootprint = Self.currentFootprint()
        lock.lock()
        precondition(!keepsSampling, "PhysicalFootprintSampler.start() called while a measurement window is already open")
        baselineFootprint = currentFootprint
        peakFootprint = currentFootprint
        keepsSampling = true
        lock.unlock()

        let thread = Thread { [self] in
            while true {
                lock.lock()
                let continues = keepsSampling
                lock.unlock()
                guard continues else { break }
                recordSample(Self.currentFootprint())
                usleep(500)
            }
            samplingFinished.signal()
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Stops sampling and returns the peak footprint growth over the
    /// baseline, in bytes. Calling it without a matching ``start()`` returns
    /// 0 instead of blocking forever on a semaphore no thread will ever
    /// signal (PR #7 review, supplementary finding 2).
    public func stop() -> UInt64 {
        lock.lock()
        let wasSampling = keepsSampling
        keepsSampling = false
        lock.unlock()
        guard wasSampling else { return 0 }
        samplingFinished.wait()
        recordSample(Self.currentFootprint())

        lock.lock()
        defer { lock.unlock() }
        return peakFootprint > baselineFootprint ? peakFootprint - baselineFootprint : 0
    }

    private func recordSample(_ sampledFootprint: UInt64) {
        lock.lock()
        if sampledFootprint > peakFootprint {
            peakFootprint = sampledFootprint
        }
        lock.unlock()
    }

    /// The process's current `phys_footprint` in bytes, or 0 if the mach
    /// call fails.
    public static func currentFootprint() -> UInt64 {
        var vmInfo = task_vm_info_data_t()
        var fieldCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kernelResult = withUnsafeMutablePointer(to: &vmInfo) { vmInfoPointer in
            vmInfoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(fieldCount)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &fieldCount)
            }
        }
        guard kernelResult == KERN_SUCCESS else { return 0 }
        return UInt64(vmInfo.phys_footprint)
    }
}
