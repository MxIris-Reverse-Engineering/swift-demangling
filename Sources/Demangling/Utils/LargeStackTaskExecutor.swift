import Foundation

#if canImport(Darwin)
/// A `TaskExecutor` whose threads carry a stack big enough that every demangle,
/// print and remangle inside a task runs inline.
///
/// ``StackSafeExecutor`` decides per call whether to hop by probing the calling
/// thread's *remaining stack*, not its identity. A task running on one of these
/// threads therefore passes the probe at every entry point, synchronous callees
/// included, and pays no thread round trip at all — the effect of
/// ``StackSafeExecutor/withLargeStack(_:)`` extended to a whole task instead of
/// one synchronous batch. That is what an `async` print loop needs: it cannot
/// be wrapped in a synchronous batch boundary, and on the 512KB cooperative
/// pool the probe never passes, so it paid one hop per printed symbol.
///
/// Use it with `withTaskExecutorPreference(_:operation:)` or
/// `Task(executorPreference:)`. Child tasks and default actors inherit the
/// preference; unstructured `Task {}` does not (SE-0417).
///
/// ### Threads
///
/// The executor owns its own ``LargeStackThreadPool`` — separate workers from
/// the pool behind the blocking hops, the same partitioning by QOS class,
/// bounded growth, checked creation and never-retiring workers. Its threads
/// are ``threadStackSize`` (16MB) rather than the hop pool's 8MB: on a
/// thread this size the printer's and the remangler's depth limits fire before
/// the stack dies even in an unoptimized build, closing that window of
/// `KnownIssues.md` #4 on this path. A job's QOS class is its priority —
/// `JobPriority` raw values *are* the Darwin QOS class values, which is how the
/// runtime's own global executor files jobs onto dispatch queues — so a
/// background task runs on a background thread and a user-initiated one on a
/// user-initiated thread, with the class fixed at thread creation and no QOS
/// syscall per job. Jobs never block their enqueuer, so a class grows only to
/// the steady-state limit (`max(2, activeProcessorCount)`), the width of the
/// cooperative pool; the overflow allowance exists to break cycles between
/// *blocked* submitters and has nothing to break here.
///
/// A job the pool cannot take — thread creation failed — runs on a dedicated
/// one-off thread of the same stack size, and if even that cannot be created,
/// on a global dispatch queue of its class: the job still runs, the per-call
/// probe hops as it does today. `enqueue` never runs a job inline: it is called
/// from the runtime's scheduling path, and running the job there would recurse
/// into it.
///
/// ### What it does not do
///
/// It is not a `SerialExecutor`: actors cannot be isolated to it. A job that
/// *blocks* its thread waiting on another job of the same class can exhaust
/// the class's workers exactly as it would exhaust the cooperative pool — the
/// contract is the same as Swift Concurrency's. And the thread that enqueues a
/// job is whichever thread resumed it, which can rank below the job's own
/// class; a parked worker may therefore be signalled from below, a shape the
/// Thread Performance Checker can report. Nothing waits on that worker, so it
/// is not an inversion anyone pays for, and it is inherent to any executor
/// whose jobs are resumed from arbitrary threads.
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
@_spi(Internals)
public final class LargeStackTaskExecutor: TaskExecutor, Sendable {
    /// Stack size of the executor's threads.
    ///
    /// Twice the hop pool's ``StackSafeExecutor/largeStackThreadSize``: a
    /// virtual-address reservation, committed page by page as a walk actually
    /// descends, so the doubling costs nothing for the depths real symbols
    /// reach. `Documentations/StackSafety.md` records what this size does and
    /// does not close of `KnownIssues.md` #4.
    public static let threadStackSize = 16 * 1024 * 1024 // 16MB

    /// Name prefix of the executor's workers; the QOS class suffix follows
    /// (`swift-demangling.task-executor.user-initiated`).
    static let workerThreadNamePrefix = "swift-demangling.task-executor."

    /// The process-wide executor. Its threads are separate from
    /// `LargeStackThreadPool.shared`, which keeps serving the blocking hops.
    public static let shared = LargeStackTaskExecutor(
        pool: LargeStackThreadPool(stackSize: threadStackSize, workerThreadNamePrefix: workerThreadNamePrefix)
    )

    private let pool: LargeStackThreadPool

    /// Tests construct private instances over pools with the spawn-failure
    /// hooks set; production only ever uses ``shared``.
    init(pool: LargeStackThreadPool) {
        self.pool = pool
    }

    /// The executor's own pool, for tests that pin its separation from
    /// `LargeStackThreadPool.shared` and its per-class limits.
    var poolForTesting: LargeStackThreadPool { pool }

    public func enqueue(_ job: consuming ExecutorJob) {
        let qualityOfServiceClass = Self.qualityOfServiceClass(for: job.priority)
        let unownedJob = UnownedJob(job)
        let unownedExecutor = asUnownedTaskExecutor()
        let runJob: @Sendable () -> Void = {
            unownedJob.runSynchronously(on: unownedExecutor)
        }

        if pool.trySubmit(allowingOverflow: false, submitterQualityOfService: qualityOfServiceClass, runJob) {
            return
        }
        if StackSafeExecutor.spawnDedicatedLargeStackThread(
            stackSize: Self.threadStackSize,
            qualityOfServiceClass: qualityOfServiceClass,
            runJob
        ) {
            return
        }
        DispatchQueue.global(qos: DispatchQoS.QoSClass(rawValue: qualityOfServiceClass) ?? .default).async(execute: runJob)
    }

    /// The QOS class a job of `priority` runs at.
    ///
    /// `JobPriority`'s raw values are the Darwin QOS class values — the
    /// runtime's global executor casts the priority straight to
    /// `dispatch_qos_class_t` for `dispatch_get_global_queue` — so the mapping
    /// is the identity. Unspecified (`0`) becomes default, which is what
    /// dispatch does with `QOS_CLASS_UNSPECIFIED` on that same call. Any other
    /// value this build does not know reaches the pool as itself, and the pool
    /// refuses it rather than filing it under a known class, as it does for an
    /// unknown submitter class; the job then takes the dedicated-thread path.
    static func qualityOfServiceClass(for priority: JobPriority) -> qos_class_t {
        if priority.rawValue == 0 {
            return QOS_CLASS_DEFAULT
        }
        return qos_class_t(rawValue: UInt32(priority.rawValue))
    }
}

extension StackSafeExecutor {
    /// The large-stack task executor: run a task on it and every demangle,
    /// print and remangle inside runs inline. See ``LargeStackTaskExecutor``.
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public static var taskExecutor: LargeStackTaskExecutor { .shared }
}
#endif
