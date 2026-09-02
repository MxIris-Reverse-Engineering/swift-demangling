import Foundation

/// Runs the recursive demangling engines on a stack large enough for real
/// symbols.
///
/// On Darwin every thread except the main one gets a 512KB stack — Swift
/// Concurrency cooperative workers and libdispatch workers alike — which is
/// enough for a few dozen levels of generic nesting. The engines' depth limits
/// make running out of stack a clean `<<too complex>>` / `.tooComplex` instead
/// of a crash; this type is what makes running out of it *rare*, by moving the
/// work onto a pooled worker with a large stack when the calling thread is low.
///
/// This mirrors what the Swift project does. `lib/Demangling` contains no
/// stack handling at all; its callers arrange a big stack at a task boundary —
/// IRGen creates its worker threads with `pthread_attr_setstacksize(8MB)`
/// "to match the main thread" (`IRGen.cpp`), module-interface subcompilations
/// run on explicit 8MB threads (`ModuleInterfaceBuilder.cpp`) — and the
/// engines carry fixed depth limits calibrated for that stack. clang guards
/// its own recursive parser the same way this type does: probe the remaining
/// stack, and move to a fresh 8MB stack when it runs low
/// (`clang/lib/Basic/Stack.cpp`).
///
/// ### What is guaranteed
///
/// Work starts only on a thread with at least ``minimumRemainingStackSize``
/// of stack still free — the caller's own thread when it qualifies, a
/// large-stack thread otherwise. The engines' depth limits bound how much of
/// it a walk may consume; they are calibrated for a full
/// ``largeStackThreadSize`` stack, so a caller that has already consumed most
/// of a large stack before calling in relies on the limits' margin rather
/// than on a fresh guarantee. This matches the upstream model (fixed limits
/// sized for 8MB threads) rather than trying to make output fully
/// thread-independent: an earlier design compared against a 64MB worker-sized
/// stack so that *no* thread ran inline, which made every call from the main
/// thread hop — blocking debugger expression evaluation (`po node` never
/// schedules the worker) and inverting priority against the pool.
///
/// SPI note: exposed as `@_spi(Internals)` so deep consumers driving
/// ``DemanglingPrinter`` directly get the same treatment as the library's own
/// entry points.
@_spi(Internals)
public enum StackSafeExecutor {
    #if canImport(Darwin)
    /// Minimum remaining stack below which work is moved to a large-stack
    /// thread.
    ///
    /// clang considers 256KB sufficient between probes of its recursive
    /// parser; the demangling engines probe once per entry rather than once
    /// per frame, so this is deliberately eight times more conservative.
    static let minimumRemainingStackSize = 2 * 1024 * 1024 // 2MB

    /// Stack size for pooled workers and dedicated fallback threads.
    ///
    /// Matches the macOS main thread and the stack the Swift project gives
    /// every thread that demangles (see the type discussion). The engines'
    /// depth limits are calibrated against this size in an unoptimized build.
    static let largeStackThreadSize = 8 * 1024 * 1024 // 8MB
    #endif

    /// Runs `body` with a large stack and returns its result.
    ///
    /// Use this at a batch boundary — indexing every symbol of a binary, say —
    /// so the whole batch pays for at most one thread hop instead of one per
    /// call. Calls inside `body` then find plenty of remaining stack and run
    /// inline.
    public static func withLargeStack<Success: Sendable, Failure: Error>(
        _ body: @escaping @Sendable () throws(Failure) -> Success
    ) throws(Failure) -> Success {
        try execute(body)
    }

    /// Executes the given block, moving it to a large-stack thread when the
    /// current thread's remaining stack is insufficient.
    public static func execute(_ block: @escaping @Sendable () -> String) -> String {
        #if canImport(Darwin)
        if currentThreadHasSufficientStack {
            return block()
        }
        nonisolated(unsafe) var result = ""
        runOnLargeStack {
            result = block()
        }
        return result
        #else
        return block()
        #endif
    }

    /// Throwing, generic variant of ``execute(_:)``, propagating typed errors
    /// across the thread boundary.
    public static func execute<Success: Sendable, Failure: Error>(
        _ block: @escaping @Sendable () throws(Failure) -> Success
    ) throws(Failure) -> Success {
        #if canImport(Darwin)
        if currentThreadHasSufficientStack {
            return try block()
        }
        nonisolated(unsafe) var outcome: Result<Success, Failure>!
        runOnLargeStack {
            do throws(Failure) {
                outcome = .success(try block())
            } catch {
                outcome = .failure(error)
            }
        }
        return try outcome.get()
        #else
        return try block()
        #endif
    }

    /// Async variant that suspends the calling task instead of blocking a
    /// cooperative worker on an OS-level semaphore.
    public static func executeAsync<Success: Sendable, Failure: Error & Sendable>(
        _ block: @escaping @Sendable () throws(Failure) -> Success
    ) async throws(Failure) -> Success {
        #if canImport(Darwin)
        if currentThreadHasSufficientStack {
            return try block()
        }
        let outcome: Result<Success, Failure>? = await withCheckedContinuation { continuation in
            // A suspended task occupies no thread, so this submission cannot be
            // part of a wait cycle and does not get the overflow allowance that
            // keeps blocked callers from deadlocking each other.
            let accepted = LargeStackThreadPool.shared.trySubmit(allowingOverflow: false) {
                do throws(Failure) {
                    continuation.resume(returning: .success(try block()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
            if accepted {
                return
            }
            // The pool cannot take it: run on a dedicated thread, and if even
            // that cannot be created, inline — the depth limits degrade the
            // result instead of crashing.
            let spawned = spawnDedicatedLargeStackThread {
                do throws(Failure) {
                    continuation.resume(returning: .success(try block()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
            if !spawned {
                continuation.resume(returning: nil)
            }
        }
        guard let outcome else {
            return try block()
        }
        return try outcome.get()
        #else
        return try block()
        #endif
    }

    #if canImport(Darwin)
    /// Whether the current thread still has ``minimumRemainingStackSize`` of
    /// stack below the probe.
    private static var currentThreadHasSufficientStack: Bool {
        let stackTopAddress = pthread_get_stackaddr_np(pthread_self())
        let stackSize = pthread_get_stacksize_np(pthread_self())
        let stackBaseAddress = stackTopAddress - stackSize
        var stackProbe = 0
        let currentAddress = withUnsafeMutablePointer(to: &stackProbe) { Int(bitPattern: $0) }
        let remainingStackSpace = currentAddress - Int(bitPattern: stackBaseAddress)
        return remainingStackSpace >= minimumRemainingStackSize
    }

    /// Runs `work` on a large-stack thread and blocks until it completes,
    /// degrading to inline execution when no such thread can be arranged.
    ///
    /// Routing, in order:
    /// 1. A pool worker that is itself low on stack must not submit back into
    ///    its own capped pool (the wait could be behind the very item it is
    ///    running), so it gets a dedicated one-off thread.
    /// 2. Everything else goes to the pool; a caller about to block may grow
    ///    it past steady state, which is what breaks fan-out wait cycles.
    /// 3. A refused submission gets a dedicated one-off thread.
    /// 4. If the OS cannot create a thread at all, the work runs inline and
    ///    the engines' depth limits keep it from crashing.
    private static func runOnLargeStack(_ work: @escaping @Sendable () -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        let signalingWork: @Sendable () -> Void = {
            work()
            semaphore.signal()
        }

        if !LargeStackThreadPool.isRunningOnPoolWorker,
           LargeStackThreadPool.shared.trySubmit(allowingOverflow: true, signalingWork) {
            semaphore.wait()
            return
        }
        if spawnDedicatedLargeStackThread(signalingWork) {
            semaphore.wait()
            return
        }
        work()
    }

    /// Context handed to a dedicated thread's C entry point.
    private final class DedicatedThreadContext {
        let work: @Sendable () -> Void

        init(work: @escaping @Sendable () -> Void) {
            self.work = work
        }
    }

    /// Starts a one-off detached thread with a ``largeStackThreadSize`` stack,
    /// reporting whether the OS actually made it.
    ///
    /// `Thread`/`NSThread` is deliberately not used: `start()` returns `Void`
    /// and swallows exactly the failure this reports.
    static func spawnDedicatedLargeStackThread(_ work: @escaping @Sendable () -> Void) -> Bool {
        var threadAttributes = pthread_attr_t()
        guard pthread_attr_init(&threadAttributes) == 0 else { return false }
        defer { pthread_attr_destroy(&threadAttributes) }
        guard pthread_attr_setstacksize(&threadAttributes, largeStackThreadSize) == 0,
              pthread_attr_setdetachstate(&threadAttributes, PTHREAD_CREATE_DETACHED) == 0
        else {
            return false
        }
        // The thread exists to run one item for this caller — usually a caller
        // that is about to block on it across a semaphore, which donates no
        // priority — so it adopts the caller's QOS class rather than a fixed
        // one: a fixed class below the caller's would be a priority inversion
        // at the caller's wait.
        _ = pthread_attr_set_qos_class_np(&threadAttributes, resolvedSubmitterQualityOfService(), 0)

        let context = Unmanaged.passRetained(DedicatedThreadContext(work: work)).toOpaque()
        var threadHandle: pthread_t?
        let creationResult = pthread_create(&threadHandle, &threadAttributes, { rawContext in
            let dedicatedContext = Unmanaged<StackSafeExecutor.DedicatedThreadContext>
                .fromOpaque(rawContext).takeRetainedValue()
            pthread_setname_np("swift-demangling.large-stack")
            autoreleasepool {
                dedicatedContext.work()
            }
            return nil
        }, context)
        guard creationResult == 0 else {
            Unmanaged<DedicatedThreadContext>.fromOpaque(context).release()
            return false
        }
        return true
    }
    #endif
}

#if canImport(Darwin)
/// The calling thread's quality-of-service class, resolved to one the pthread
/// QOS APIs accept.
///
/// `qos_class_self()` answers `QOS_CLASS_UNSPECIFIED` on threads outside the
/// QOS system (opted-out legacy threads); the pthread APIs reject that value,
/// so those callers fall back to user-initiated — the class every thread here
/// was created with before submissions carried their own.
private func resolvedSubmitterQualityOfService() -> qos_class_t {
    let submitterClass = qos_class_self()
    return submitterClass == QOS_CLASS_UNSPECIFIED ? QOS_CLASS_USER_INITIATED : submitterClass
}

/// A bounded pool of long-lived large-stack workers.
///
/// Creating and joining a thread per call costs roughly 41µs measured on this
/// package — five to eighteen times the work itself for a typical symbol, and
/// seconds of pure overhead when indexing a framework from small-stack
/// threads. Workers are therefore created on demand and kept.
///
/// Properties that are load-bearing and easy to lose:
///
/// - **Workers never retire.** An idle-timeout retirement has a window between
///   the timeout firing and the worker reacquiring the lock in which a
///   submission counts it as available, creates no replacement, and signals
///   nobody — the work item is then never run and the caller blocks forever.
///   Keeping workers alive removes the window rather than trying to close it.
///   Idle workers cost a kernel thread structure each; their 8MB stacks are
///   untouched address space.
/// - **A worker is created before its work is queued, and creation is
///   checked.** `Thread.start()` reports nothing when the OS refuses to make a
///   thread, so a design built on it increments the worker count, fails to
///   start anything, and leaves the item queued with nobody to run it: the
///   caller blocks forever, and because the phantom worker still counts, every
///   later submission sees a full pool and never creates a replacement — one
///   failure poisons a process-wide singleton permanently. `pthread_create`
///   returns an error code, so the slot is released instead.
/// - **When the last spawn attempt fails, the failing submitter drains the
///   queue itself.** Two concurrent submitters can each reserve a worker slot
///   and both fail to spawn; the first to roll back still sees the other's
///   reservation, concludes a worker survives, queues its item and blocks.
///   Only the second roll-back can know the pool is truly empty — so it runs
///   everything still queued on its own thread before refusing. Nobody hangs;
///   the cost is running someone's work on a caller's stack in a process that
///   cannot create threads at all, where the depth limits degrade instead of
///   crash.
/// - **Submission can be refused.** A refused item is the caller's to run —
///   `StackSafeExecutor` puts it on a dedicated thread, or inline as the last
///   resort. That is what makes every failure mode degrade rather than hang.
/// - **A worker never submits back into its own pool.** Printing re-enters
///   demangling for nested mangled names; a worker deep enough in its own
///   stack to need a hop gets a dedicated thread instead
///   (``StackSafeExecutor/runOnLargeStack(_:)``), because its wait could sit
///   behind the very item it is running.
/// - **Workers are partitioned by QOS class, and a submission only ever
///   touches its own class.** Neither wait involved can inherit priority — the
///   submitter's semaphore donates nothing, and a condition variable cannot
///   know its future signaller — so the ranking has to be right by
///   construction: a worker is created at the class of the submitter that
///   needed it and keeps that class for life, and a submission signals or
///   creates only workers of the submitter's class. A caller blocked on its
///   item therefore never waits on a lower-priority thread, and a parked
///   worker is never signalled by a thread below its own class (the shape the
///   Thread Performance Checker reports as a priority inversion at the
///   condition wait). The previous design kept one class-agnostic pool and
///   re-ranked per hop — every dequeue `pthread_set_qos_class_self_np` to the
///   item's class, every park a drop to background — which was correct but
///   cost three to four times the throughput of every demangle-heavy path
///   (SwiftUICore dump in the downstream indexer: 50 s → 150–210 s): a
///   parked worker was a *background* thread, so each of the hundreds of
///   thousands of hops paid a background wake-up (efficiency-core scheduling,
///   throttling) plus two QOS syscalls. Partitioning removes both costs from
///   the hop; the price is up to one pool per class actually used by the
///   process (five at most), each bounded like the single pool was. The
///   bound is deliberately per class, not a budget shared across classes:
///   workers never retire, so under a shared budget the idle workers of one
///   class would hold slots another class needs, forever — the never-retire
///   property would be breached through the side door. Worst case with every
///   class bursting at once: 5 × `max(32, 4 × cores)` workers, each an 8MB
///   reservation of untouched address space (1.28GB on a 32-bit watchOS
///   process with its 4GB address space, which takes 32 simultaneously
///   blocked callers of *each* class to reach); steady state on a dual-core
///   watch is 5 × 2 = 10 workers, 80MB of reservation. A class this build
///   does not know is refused rather than promoted into a pool — the caller
///   takes the dedicated-thread path, which does not promote it either.
///
/// ### The overflow allowance
///
/// Blocking submissions may grow the pool above the steady-state limit: a
/// worker that fans out — `concurrentPerform` or a task group inside a
/// ``StackSafeExecutor/withLargeStack(_:)`` batch — produces submissions from
/// threads the pool cannot recognise, and with a hard cap the outer items
/// would wait for inner items queued behind them. A caller that is about to
/// block is evidence of a thread waiting, and growing for it is what breaks
/// the cycle. Asynchronous submissions occupy no thread while suspended,
/// cannot be part of such a cycle, and stay under the steady-state limit so a
/// burst of them cannot inflate the pool.
///
/// Nesting deeper than ``burstWorkerLimit`` simultaneously blocked callers is
/// still possible in principle; those submissions queue as before.
///
/// Concurrency: this type itself is plain `Sendable` — it holds only its
/// immutable class pools. The mutable state lives in the nested
/// ``QualityOfServiceClassPool``, the one type here that keeps
/// `@unchecked Sendable` rather than moving its state into a `Mutex`; the
/// reason is the primitive, not the pattern, and is recorded there.
final class LargeStackThreadPool: Sendable {
    static let shared = LargeStackThreadPool()

    /// The QOS classes a submitter can resolve to, one sub-pool each, in
    /// ``classPools`` order — ``poolIndex(for:)`` is the single source of that
    /// order and the initializer asserts the two agree.
    ///
    /// `QOS_CLASS_UNSPECIFIED` is not a pool: ``resolvedSubmitterQualityOfService()``
    /// folds it into user-initiated before the lookup, so a legacy thread
    /// outside the QOS system shares the user-initiated pool.
    private static let pooledQualityOfServiceClasses: [qos_class_t] = [
        QOS_CLASS_BACKGROUND,
        QOS_CLASS_UTILITY,
        QOS_CLASS_DEFAULT,
        QOS_CLASS_USER_INITIATED,
        QOS_CLASS_USER_INTERACTIVE,
    ]

    /// Index into ``classPools`` for a resolved submitter class, or `nil` for
    /// a raw value this build does not know (a class a future OS adds). An
    /// unknown class is refused rather than filed under a known one: the first
    /// partitioned version folded it into user-initiated, which raised work of
    /// unknown rank five levels and let a user-initiated park be signalled
    /// from below — the very shape the partition rules out. The refusal sends
    /// the caller down the dedicated-thread path, which does not promote it
    /// either (`pthread_attr_set_qos_class_np` rejects the value with `EINVAL`,
    /// leaving the thread at `pthread_create`'s default).
    private static func poolIndex(for qualityOfServiceClass: qos_class_t) -> Int? {
        switch qualityOfServiceClass {
        case QOS_CLASS_BACKGROUND: return 0
        case QOS_CLASS_UTILITY: return 1
        case QOS_CLASS_DEFAULT: return 2
        case QOS_CLASS_USER_INITIATED: return 3
        case QOS_CLASS_USER_INTERACTIVE: return 4
        default: return nil
        }
    }

    /// Thread-local marker key, or `nil` if the platform refused to allocate
    /// one.
    ///
    /// `Thread.current.threadDictionary` would be the obvious place for this,
    /// but reading it materializes an `NSThread` wrapper and lazily allocates —
    /// and permanently retains — an `NSMutableDictionary` on every thread that
    /// ever demangles. This check sits on every entry point, so it has to be a
    /// bare `pthread_getspecific`.
    ///
    /// Without the marker the pool cannot tell a worker from any other thread,
    /// and a worker submitting back into a capped pool could deadlock. The
    /// pool disables itself instead: submissions are refused and
    /// `StackSafeExecutor` falls back to dedicated threads.
    private static let workerMarkerKey: pthread_key_t? = {
        var key = pthread_key_t()
        guard pthread_key_create(&key, nil) == 0 else { return nil }
        return key
    }()

    /// Whether the calling thread is one of this pool's workers.
    static var isRunningOnPoolWorker: Bool {
        guard let workerMarkerKey else { return false }
        return pthread_getspecific(workerMarkerKey) != nil
    }

    private static func markCurrentThreadAsPoolWorker() {
        guard let workerMarkerKey else { return }
        // Any non-null value marks the thread; the key has no destructor, so
        // nothing is ever dereferenced.
        pthread_setspecific(workerMarkerKey, UnsafeMutableRawPointer(bitPattern: 1))
    }

    /// The per-class ceiling including the overflow allowance, kept here only
    /// to report it to tests (``burstWorkerLimitForTesting``); the pools
    /// enforce their own copy.
    private let burstWorkerLimit: Int

    /// One sub-pool per pooled class, in ``pooledQualityOfServiceClasses``
    /// order. Created eagerly — five small objects — so the submission path
    /// is a plain array read; a class that never receives a submission never
    /// spawns a thread.
    private let classPools: [QualityOfServiceClassPool]

    /// ``shared`` and every production path use the parameterless form; only
    /// tests pass the hooks, which are handed straight to the class pools.
    init(
        simulatesSpawnFailureForTesting: Bool = false,
        simulatedSpawnFailureDelayForTesting: TimeInterval = 0
    ) {
        let steadyStateWorkerLimit = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let burstWorkerLimit = max(32, 4 * steadyStateWorkerLimit)
        self.burstWorkerLimit = burstWorkerLimit
        self.classPools = Self.pooledQualityOfServiceClasses.map { qualityOfServiceClass in
            QualityOfServiceClassPool(
                qualityOfServiceClass: qualityOfServiceClass,
                steadyStateWorkerLimit: steadyStateWorkerLimit,
                burstWorkerLimit: burstWorkerLimit,
                simulatesSpawnFailureForTesting: simulatesSpawnFailureForTesting,
                simulatedSpawnFailureDelayForTesting: simulatedSpawnFailureDelayForTesting
            )
        }
        for (index, qualityOfServiceClass) in Self.pooledQualityOfServiceClasses.enumerated() {
            assert(Self.poolIndex(for: qualityOfServiceClass) == index, "pooledQualityOfServiceClasses must follow poolIndex(for:)")
        }
    }

    /// Number of workers this pool has created across every class — a sum of
    /// per-class snapshots taken one lock at a time, so the total may never
    /// have held at any single instant. Fit for an upper-bound assertion or a
    /// quiescent private pool, which is what the tests use it for; not for a
    /// decision.
    var currentWorkerCount: Int {
        classPools.reduce(0) { $0 + $1.currentWorkerCount }
    }

    /// Number of workers created for one class (zero for a class this build
    /// does not pool). Exposed for tests that pin the partition itself.
    func currentWorkerCount(for qualityOfServiceClass: qos_class_t) -> Int {
        guard let poolIndex = Self.poolIndex(for: qualityOfServiceClass) else { return 0 }
        return classPools[poolIndex].currentWorkerCount
    }

    /// One class pool's hard ceiling. Tests assert a single class's count
    /// against this rather than the steady-state limit: the pool is a
    /// process-wide singleton whose workers never retire, so a suite running
    /// concurrently may legitimately have taken a class above steady state.
    var burstWorkerLimitForTesting: Int { burstWorkerLimit }

    /// Queues `workItem` on the submitter's class pool, growing that pool if
    /// that is what it takes.
    ///
    /// - Parameter allowingOverflow: whether the caller will block until the
    ///   item runs. Blocking callers may grow the pool past its steady-state
    ///   limit; see the type's discussion.
    /// - Returns: `false` if the pool cannot run the item, in which case the
    ///   caller must run it elsewhere. When this returns `true` the item is
    ///   guaranteed to run: by a worker of the submitter's class, or — if
    ///   thread creation collapses process-wide — on the thread of whichever
    ///   submitter discovered the collapse.
    func trySubmit(allowingOverflow: Bool, _ workItem: @escaping @Sendable () -> Void) -> Bool {
        trySubmit(allowingOverflow: allowingOverflow, submitterQualityOfService: resolvedSubmitterQualityOfService(), workItem)
    }

    /// The class-explicit form of ``trySubmit(allowingOverflow:_:)``. Production
    /// always passes the calling thread's resolved class; tests pass classes no
    /// thread of this process can carry.
    func trySubmit(allowingOverflow: Bool, submitterQualityOfService: qos_class_t, _ workItem: @escaping @Sendable () -> Void) -> Bool {
        guard Self.workerMarkerKey != nil, let poolIndex = Self.poolIndex(for: submitterQualityOfService) else { return false }
        return classPools[poolIndex].trySubmit(allowingOverflow: allowingOverflow, workItem)
    }

    /// The workers of one QOS class: created at that class, never re-ranked,
    /// signalled only by submitters of that class. Everything the single
    /// pre-partition pool did — bounded growth, checked creation, drain on
    /// collapse, refusal — lives here unchanged, per class.
    ///
    /// Concurrency: this is the one type here that keeps `@unchecked Sendable`
    /// rather than moving its state into a `Mutex`, and the reason is the
    /// primitive, not the pattern. Workers park on `condition.wait()` until a
    /// submission signals them, so the pool needs a *condition variable*, and
    /// a mutex offers no way to wait on one — `NSCondition` is lock and
    /// condition in one object, so the state it guards has to live beside it
    /// rather than inside it. (`NodeCache` and `NodeBuilder` only ever needed
    /// mutual exclusion, which is why they did move.)
    private final class QualityOfServiceClassPool: @unchecked Sendable {
        let qualityOfServiceClass: qos_class_t

        /// Thread name for this pool's workers, class-suffixed so a spindump
        /// shows which class's pool grew and whether an item landed in the
        /// wrong one. `pthread_setname_np` caps names at 63 bytes; the longest
        /// here is 51.
        let workerThreadName: String

        /// Ceiling for demand-driven growth in steady state.
        private let steadyStateWorkerLimit: Int

        /// Ceiling including the allowance for blocking submissions.
        ///
        /// A fan-out inside a batch needs room for the outer items *and* the
        /// inner ones they wait on; both are bounded by the caller's own
        /// concurrency, which is in turn bounded by the core count. A few
        /// times the steady-state limit covers the nesting depths that occur
        /// in practice. Each worker reserves address space rather than memory,
        /// so the cost of the headroom is a kernel thread structure per worker.
        private let burstWorkerLimit: Int

        /// Test hook: makes every spawn attempt fail as if the OS refused to
        /// create the thread, so the failure paths can be exercised on a
        /// private pool instance. Never set on the shared pool.
        ///
        /// Immutable, and set only at construction. Every other mutable
        /// property on this type is touched exclusively under `condition`,
        /// but `spawnWorker()` runs *after* the lock is released, so a
        /// settable hook would be an unsynchronized read racing any writer —
        /// leaving the type's `@unchecked Sendable` audit resting on call-site
        /// discipline rather than on the lock it otherwise uses uniformly (and
        /// a torn read of the 64-bit `TimeInterval` is representable on 32-bit
        /// armv7k). `let` removes the race outright instead of moving it under
        /// the lock, which would make the delay's `Thread.sleep` block every
        /// other submitter.
        private let simulatesSpawnFailureForTesting: Bool

        /// Test hook: how long a simulated spawn failure takes to report. A
        /// real `pthread_create` failure is not instantaneous either; the delay
        /// holds concurrent submitters in the reserved-but-not-yet-failed state
        /// at the same time, which is the interleaving the failure handling
        /// has to survive.
        private let simulatedSpawnFailureDelayForTesting: TimeInterval

        init(
            qualityOfServiceClass: qos_class_t,
            steadyStateWorkerLimit: Int,
            burstWorkerLimit: Int,
            simulatesSpawnFailureForTesting: Bool,
            simulatedSpawnFailureDelayForTesting: TimeInterval
        ) {
            self.qualityOfServiceClass = qualityOfServiceClass
            self.workerThreadName = "swift-demangling.large-stack-worker." + Self.threadNameSuffix(for: qualityOfServiceClass)
            self.steadyStateWorkerLimit = steadyStateWorkerLimit
            self.burstWorkerLimit = burstWorkerLimit
            self.simulatesSpawnFailureForTesting = simulatesSpawnFailureForTesting
            self.simulatedSpawnFailureDelayForTesting = simulatedSpawnFailureDelayForTesting
        }

        private static func threadNameSuffix(for qualityOfServiceClass: qos_class_t) -> String {
            switch qualityOfServiceClass {
            case QOS_CLASS_BACKGROUND: return "background"
            case QOS_CLASS_UTILITY: return "utility"
            case QOS_CLASS_DEFAULT: return "default"
            case QOS_CLASS_USER_INITIATED: return "user-initiated"
            case QOS_CLASS_USER_INTERACTIVE: return "user-interactive"
            default: return "unknown"
            }
        }

        private let condition = NSCondition()
        private var pendingWorkItems: [@Sendable () -> Void] = []
        /// Index of the next item to run. Removing from the front of the array
        /// instead would memmove the whole queue while holding the lock.
        private var nextWorkItemIndex = 0
        private var idleWorkerCount = 0
        private var workerCount = 0

        var currentWorkerCount: Int {
            condition.lock()
            defer { condition.unlock() }
            return workerCount
        }

        func trySubmit(allowingOverflow: Bool, _ workItem: @escaping @Sendable () -> Void) -> Bool {
            condition.lock()
            let queuedCount = pendingWorkItems.count - nextWorkItemIndex
            let workerLimit = allowingOverflow ? burstWorkerLimit : steadyStateWorkerLimit
            let needsAdditionalWorker = queuedCount + 1 > idleWorkerCount && workerCount < workerLimit
            if needsAdditionalWorker {
                workerCount += 1
            }
            condition.unlock()

            if needsAdditionalWorker, !spawnWorker() {
                condition.lock()
                workerCount -= 1
                if workerCount == 0 {
                    // Workers never retire, so a zero count here means no worker
                    // thread exists at all — and a concurrent submitter that saw
                    // this thread's reservation may have queued an item and
                    // blocked on it. Run everything still queued right here so
                    // nobody waits on a pool that cannot act, then refuse.
                    drainPendingWorkItemsWhileLocked()
                    condition.unlock()
                    return false
                }
                condition.unlock()
            }

            condition.lock()
            guard workerCount > 0 else {
                // Every counted worker turned out to be a failed reservation and
                // the last roll-back already ran its drain. Queueing now would
                // strand the item: refuse instead.
                condition.unlock()
                return false
            }
            pendingWorkItems.append(workItem)
            condition.signal()
            condition.unlock()
            return true
        }

        /// Runs every queued item on the calling thread. Entered with the lock
        /// held and `workerCount == 0`; leaves the lock held.
        ///
        /// The lock is released around each item — items block on semaphores of
        /// their own and may take arbitrarily long. New items queued meanwhile are
        /// picked up on the next pass; they can only come from submitters racing
        /// the same collapse, and running them here is what unblocks those
        /// submitters. Runs at the drainer's own class, which is this pool's
        /// class by construction.
        private func drainPendingWorkItemsWhileLocked() {
            while nextWorkItemIndex < pendingWorkItems.count {
                let workItem = pendingWorkItems[nextWorkItemIndex]
                pendingWorkItems[nextWorkItemIndex] = {}
                nextWorkItemIndex += 1
                if nextWorkItemIndex == pendingWorkItems.count {
                    pendingWorkItems.removeAll(keepingCapacity: true)
                    nextWorkItemIndex = 0
                }
                condition.unlock()
                autoreleasepool {
                    workItem()
                }
                condition.lock()
            }
        }

        /// Starts one worker at this pool's class, reporting whether the OS
        /// actually made the thread.
        ///
        /// `Thread`/`NSThread` is deliberately not used here: `start()` returns
        /// `Void` and swallows the failure this whole path exists to detect.
        private func spawnWorker() -> Bool {
            if simulatesSpawnFailureForTesting {
                if simulatedSpawnFailureDelayForTesting > 0 {
                    Thread.sleep(forTimeInterval: simulatedSpawnFailureDelayForTesting)
                }
                return false
            }
            var threadAttributes = pthread_attr_t()
            guard pthread_attr_init(&threadAttributes) == 0 else { return false }
            defer { pthread_attr_destroy(&threadAttributes) }
            guard pthread_attr_setstacksize(&threadAttributes, StackSafeExecutor.largeStackThreadSize) == 0,
                  pthread_attr_setdetachstate(&threadAttributes, PTHREAD_CREATE_DETACHED) == 0
            else {
                return false
            }
            // The worker's class for life: every item it will ever run was
            // submitted from a thread of this class, so the hop never needs a
            // re-rank and the idle park never outranks its signaller.
            _ = pthread_attr_set_qos_class_np(&threadAttributes, qualityOfServiceClass, 0)

            let context = Unmanaged.passRetained(self).toOpaque()
            var threadHandle: pthread_t?
            let creationResult = pthread_create(&threadHandle, &threadAttributes, { rawContext in
                let classPool = Unmanaged<QualityOfServiceClassPool>.fromOpaque(rawContext).takeRetainedValue()
                pthread_setname_np(classPool.workerThreadName)
                classPool.runWorkerLoop()
                return nil
            }, context)
            guard creationResult == 0 else {
                Unmanaged<QualityOfServiceClassPool>.fromOpaque(context).release()
                return false
            }
            return true
        }

        private func runWorkerLoop() {
            LargeStackThreadPool.markCurrentThreadAsPoolWorker()

            while true {
                condition.lock()
                idleWorkerCount += 1
                while nextWorkItemIndex == pendingWorkItems.count {
                    condition.wait()
                }
                idleWorkerCount -= 1
                let workItem = pendingWorkItems[nextWorkItemIndex]
                // Drop the queue's reference to the closure. `removeAll` below only
                // runs when the queue happens to drain completely, so under a
                // sustained burst every already-executed item would otherwise stay
                // alive — each one retaining whatever its caller captured, which on
                // the print and remangle paths is a whole `Node` tree.
                pendingWorkItems[nextWorkItemIndex] = {}
                nextWorkItemIndex += 1
                if nextWorkItemIndex == pendingWorkItems.count {
                    pendingWorkItems.removeAll(keepingCapacity: true)
                    nextWorkItemIndex = 0
                }
                condition.unlock()

                // The predecessor created a thread per call, and a thread drains
                // its own pool when it exits — so no explicit pool was needed. Long-
                // lived workers remove that drain point: without this, an
                // autoreleased object's release would move from "end of the call" to
                // "end of the process". The pool created the hazard; this closes it.
                autoreleasepool {
                    workItem()
                }
            }
        }
    }
}
#endif
