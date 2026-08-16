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
    private var samplingThreadStartFailed = false
    private let samplingFinished = DispatchSemaphore(value: 0)

    public init() {}

    /// Whether the most recent ``start()`` could not create its sampling
    /// thread. A window that never opened reports a peak of 0; callers that
    /// treat 0 as a measurement should check this first.
    public var lastWindowFailedToStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return samplingThreadStartFailed
    }

    /// Records the baseline footprint and starts the sampling thread.
    ///
    /// The thread is created with a checked `pthread_create` rather than
    /// `Thread.start()`, which reports nothing when the OS refuses to make a
    /// thread. With the unchecked spelling, `keepsSampling` was already true
    /// when creation failed, so the matching `stop()` passed its `guard` and
    /// parked forever on a semaphore no thread would ever signal — the whole
    /// benchmark suite wedging with no diagnostic and no timeout, under exactly
    /// the thread pressure those suites create. `StackSafeExecutor` documents
    /// this same hazard twice and is where the shape below comes from
    /// (PR #7 review, finding 11).
    ///
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
        samplingThreadStartFailed = false
        lock.unlock()

        var threadAttributes = pthread_attr_t()
        guard pthread_attr_init(&threadAttributes) == 0 else {
            abandonUnstartedWindow()
            return
        }
        defer { pthread_attr_destroy(&threadAttributes) }
        guard pthread_attr_setdetachstate(&threadAttributes, PTHREAD_CREATE_DETACHED) == 0 else {
            abandonUnstartedWindow()
            return
        }
        _ = pthread_attr_set_qos_class_np(&threadAttributes, QOS_CLASS_USER_INITIATED, 0)

        let samplerContext = Unmanaged.passRetained(self).toOpaque()
        var threadHandle: pthread_t?
        let creationResult = pthread_create(&threadHandle, &threadAttributes, { rawContext in
            let sampler = Unmanaged<PhysicalFootprintSampler>.fromOpaque(rawContext).takeRetainedValue()
            pthread_setname_np("swift-demangling.footprint-sampler")
            sampler.runSamplingLoop()
            return nil
        }, samplerContext)
        guard creationResult == 0 else {
            Unmanaged<PhysicalFootprintSampler>.fromOpaque(samplerContext).release()
            abandonUnstartedWindow()
            return
        }
    }

    /// Closes a window whose sampling thread never started, so the matching
    /// `stop()` returns 0 instead of blocking on a semaphore nobody will signal.
    private func abandonUnstartedWindow() {
        lock.lock()
        keepsSampling = false
        samplingThreadStartFailed = true
        lock.unlock()
    }

    private func runSamplingLoop() {
        while true {
            lock.lock()
            let continuesSampling = keepsSampling
            lock.unlock()
            guard continuesSampling else { break }
            recordSample(Self.currentFootprint())
            usleep(500)
        }
        samplingFinished.signal()
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
