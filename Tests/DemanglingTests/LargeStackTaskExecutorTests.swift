import Foundation
import Testing
@_spi(Internals) @testable import Demangling

/// Guards the large-stack task executor (evolution 0014).
///
/// The executor exists for one property: a task running on it passes
/// ``StackSafeExecutor``'s stack probe at every entry point, so every demangle,
/// print and remangle inside the task runs inline instead of hopping. The rest
/// — thread shape, priority-to-class mapping, separation from the hop pool,
/// the fallback when threads cannot be created — is what keeps that property
/// from costing something elsewhere.
///
/// Every test opens with the runtime gate the executor itself carries; on an
/// older OS the suite is a no-op rather than a failure.
@Suite("LargeStackTaskExecutor")
struct LargeStackTaskExecutorTests {
    static func currentThreadName() -> String {
        var nameBuffer = [CChar](repeating: 0, count: 64)
        pthread_getname_np(pthread_self(), &nameBuffer, nameBuffer.count)
        return String(cString: nameBuffer)
    }

    /// Blocks the calling thread on `semaphore`. A synchronous wrapper because
    /// the executor's threads are the package's own pthreads, not cooperative
    /// workers — holding one is exactly what the separation test needs — and
    /// the compiler's "no waits in async contexts" rule cannot know that.
    static func hold(_ semaphore: DispatchSemaphore) {
        semaphore.wait()
    }

    /// The property everything else serves: inside a task on the executor,
    /// both the blocking and the suspending entry points run on the task's
    /// own thread. On the cooperative pool the same calls hop every time
    /// (``LargeStackThreadPoolTests/executionHopsToALargeStackFromASmallCallerStack``).
    @Test func callsInsideATaskOnTheExecutorRunInline() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) else { return }
        let observation = await withTaskExecutorPreference(StackSafeExecutor.taskExecutor) {
            () -> (taskThread: mach_port_t, blockingCallThread: mach_port_t, suspendingCallThread: mach_port_t) in
            let taskThread = pthread_mach_thread_np(pthread_self())
            let blockingCallThread: mach_port_t = StackSafeExecutor.execute {
                pthread_mach_thread_np(pthread_self())
            }
            let suspendingCallThread: mach_port_t = await StackSafeExecutor.executeAsync {
                pthread_mach_thread_np(pthread_self())
            }
            return (taskThread, blockingCallThread, suspendingCallThread)
        }
        #expect(observation.blockingCallThread == observation.taskThread, "execute must not hop off an executor thread")
        #expect(observation.suspendingCallThread == observation.taskThread, "executeAsync must not hop off an executor thread")
    }

    /// Executor threads are the executor's own — 16MB, named after it — not
    /// hop-pool workers and not the dedicated fallback thread.
    @Test func executorThreadsCarryTheExecutorStackAndName() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) else { return }
        let (stackSize, threadName) = await withTaskExecutorPreference(StackSafeExecutor.taskExecutor) {
            (pthread_get_stacksize_np(pthread_self()), Self.currentThreadName())
        }
        #expect(stackSize >= LargeStackTaskExecutor.threadStackSize, "stack was \(stackSize) bytes")
        #expect(threadName.hasPrefix("swift-demangling.task-executor."), "ran on \(threadName)")
    }

    /// A job runs at the QOS class of its task's priority. The class is fixed
    /// at thread creation — the pool is partitioned by class — so this is also
    /// what pins that a background task does not run on a user-initiated
    /// thread or vice versa.
    @Test(arguments: [
        (TaskPriority.background, QOS_CLASS_BACKGROUND),
        (TaskPriority.utility, QOS_CLASS_UTILITY),
        (TaskPriority.medium, QOS_CLASS_DEFAULT),
        (TaskPriority.userInitiated, QOS_CLASS_USER_INITIATED),
    ])
    func aJobRunsAtTheClassOfItsPriority(priority: TaskPriority, expectedClass: qos_class_t) async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) else { return }
        let observedClass = await Task(executorPreference: StackSafeExecutor.taskExecutor, priority: priority) {
            qos_class_self()
        }.value
        #expect(observedClass == expectedClass)
    }

    /// The priority-to-class mapping is the identity on the raw value — the
    /// runtime's own global executor relies on the same equality — with
    /// unspecified filed under default (dispatch's reading of
    /// `QOS_CLASS_UNSPECIFIED`) and unknown values passed through so the pool
    /// refuses them the way it refuses an unknown submitter class.
    @Test func priorityMapsToTheQualityOfServiceClassOfTheSameRawValue() {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) else { return }
        #expect(LargeStackTaskExecutor.qualityOfServiceClass(for: JobPriority(rawValue: 0x21)) == QOS_CLASS_USER_INTERACTIVE)
        #expect(LargeStackTaskExecutor.qualityOfServiceClass(for: JobPriority(.userInitiated)) == QOS_CLASS_USER_INITIATED)
        #expect(LargeStackTaskExecutor.qualityOfServiceClass(for: JobPriority(.medium)) == QOS_CLASS_DEFAULT)
        #expect(LargeStackTaskExecutor.qualityOfServiceClass(for: JobPriority(.utility)) == QOS_CLASS_UTILITY)
        #expect(LargeStackTaskExecutor.qualityOfServiceClass(for: JobPriority(.background)) == QOS_CLASS_BACKGROUND)
        #expect(LargeStackTaskExecutor.qualityOfServiceClass(for: JobPriority(rawValue: 0)) == QOS_CLASS_DEFAULT)

        let unknownClass = LargeStackTaskExecutor.qualityOfServiceClass(for: JobPriority(rawValue: 0x1B))
        let accepted = StackSafeExecutor.taskExecutor.poolForTesting.trySubmit(
            allowingOverflow: false,
            submitterQualityOfService: unknownClass
        ) {}
        #expect(!accepted, "an unknown priority must be refused by the pool, not promoted into a class")
    }

    /// Long jobs on the executor never touch the hop pool: with every
    /// executor worker of a class held, a blocking hop of that class still
    /// lands on an 8MB hop-pool worker, and the hop pool did not grow to
    /// absorb the executor's jobs. This is the reason the executor has its
    /// own threads — under a shared pool the held jobs would have consumed
    /// the class's steady-state budget and pushed the hop into the overflow
    /// allowance.
    @Test func jobsOnTheExecutorDoNotOccupyTheHopPool() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) else { return }
        let executorPool = StackSafeExecutor.taskExecutor.poolForTesting
        let heldWorkerCount = executorPool.steadyStateWorkerLimitForTesting
        let hopPoolUtilityWorkersBefore = LargeStackThreadPool.shared.currentWorkerCount(for: QOS_CLASS_UTILITY)

        let release = DispatchSemaphore(value: 0)
        let startedCounter = LargeStackThreadPoolTests.Counter()
        let holders = (0..<heldWorkerCount).map { _ in
            Task(executorPreference: StackSafeExecutor.taskExecutor, priority: .utility) {
                startedCounter.increment()
                Self.hold(release)
            }
        }
        while startedCounter.current < heldWorkerCount {
            try? await Task.sleep(for: .milliseconds(2))
        }

        final class ObservationBox: @unchecked Sendable {
            var hopThreadName = ""
            var hopStackSize = 0
        }
        let observation = ObservationBox()
        LargeStackThreadPoolTests.runOnThread(stackSize: LargeStackThreadPoolTests.cooperativeWorkerStackSize, qualityOfService: .utility) {
            _ = StackSafeExecutor.execute { () -> String in
                observation.hopThreadName = Self.currentThreadName()
                observation.hopStackSize = pthread_get_stacksize_np(pthread_self())
                return ""
            }
        }
        let hopPoolUtilityWorkersWhileHeld = LargeStackThreadPool.shared.currentWorkerCount(for: QOS_CLASS_UTILITY)

        for _ in holders {
            release.signal()
        }
        for holder in holders {
            await holder.value
        }

        #expect(executorPool.currentWorkerCount(for: QOS_CLASS_UTILITY) >= heldWorkerCount)
        #expect(observation.hopThreadName.hasPrefix(LargeStackThreadPool.hopWorkerThreadNamePrefix), "hopped to \(observation.hopThreadName)")
        #expect(observation.hopStackSize >= StackSafeExecutor.largeStackThreadSize && observation.hopStackSize < LargeStackTaskExecutor.threadStackSize, "hop stack was \(observation.hopStackSize) bytes")
        #expect(hopPoolUtilityWorkersWhileHeld <= hopPoolUtilityWorkersBefore + 1, "the hop pool must not have grown for the executor's jobs")
    }

    /// When the executor's pool cannot create a thread, the job still runs —
    /// on a dedicated thread of the executor's stack size, so the inline
    /// property survives the failure — and never inline in `enqueue`.
    @Test func aJobThePoolCannotTakeStillRunsOnALargeStackThread() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) else { return }
        let executor = LargeStackTaskExecutor(
            pool: LargeStackThreadPool(
                stackSize: LargeStackTaskExecutor.threadStackSize,
                workerThreadNamePrefix: LargeStackTaskExecutor.workerThreadNamePrefix,
                simulatesSpawnFailureForTesting: true
            )
        )
        let enqueuingThread = pthread_mach_thread_np(pthread_self())
        let (stackSize, threadName, runningThread) = await withTaskExecutorPreference(executor) {
            (pthread_get_stacksize_np(pthread_self()), Self.currentThreadName(), pthread_mach_thread_np(pthread_self()))
        }
        #expect(stackSize >= LargeStackTaskExecutor.threadStackSize, "stack was \(stackSize) bytes")
        #expect(threadName == "swift-demangling.large-stack", "ran on \(threadName)")
        #expect(runningThread != enqueuingThread)
    }

    // MARK: - Depth (KnownIssues.md #4 on the executor path)
    //
    // The nested-`Optional` shape costs the printer two depth units and the
    // remangler four per nesting level, so `maxPrintDepth = 768` fires between
    // 380 and 383 levels and `Remangler.maxDepth = 1024` between 240 and 260.
    // Measured on 2026-09-03, unoptimized build, arm64: on an 8MB thread both
    // engines die of SIGBUS *before* their counter fires — the printer at 380
    // levels, the remangler at 200 — which is the window KnownIssues.md #4
    // describes. On the executor's 16MB thread the same depths complete and
    // the counters fire first, so the degradation assertions that #4 had to
    // remove from `StackSafetyTests` are restored here, for this path.
    // `TypeDecoder` is not covered: at ~30KB per depth unit its 1024 limit
    // needs ~30MB, so its window stays open on the executor too.

    /// A depth that overflows an 8MB thread in an unoptimized build prints in
    /// full on the executor.
    @Test func printingOnTheExecutorSurvivesADepthThatOverflowsAnEightMegabyteThread() async throws {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) else { return }
        let nestingDepth = 380
        let node = try await demangleAsNode(StackSafetyTests.deeplyNestedOptionalSymbol(nestingDepth: nestingDepth), internsSubtrees: false)
        let printed = await withTaskExecutorPreference(StackSafeExecutor.taskExecutor) {
            node.print(using: .default)
        }
        #expect(!printed.contains("<<too complex>>"), "\(nestingDepth) levels should print in full on a 16MB thread")
        #expect(printed == String(repeating: "Swift.Optional<", count: nestingDepth) + "Swift.Int" + String(repeating: ">", count: nestingDepth))
    }

    /// Past the printer's depth limit the executor path degrades to the
    /// marker instead of crashing — the assertion `StackSafetyTests` lost when
    /// the limit went back to upstream's 768.
    @Test func printingOnTheExecutorDegradesPastTheDepthLimitInsteadOfCrashing() async throws {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) else { return }
        let node = try await demangleAsNode(StackSafetyTests.deeplyNestedOptionalSymbol(nestingDepth: 1000), internsSubtrees: false)
        let printed = await withTaskExecutorPreference(StackSafeExecutor.taskExecutor) {
            node.print(using: .default)
        }
        #expect(printed.contains("<<too complex>>"))
        #expect(printed.hasPrefix(String(repeating: "Swift.Optional<", count: 8)))
    }

    /// A depth that overflows an 8MB thread in an unoptimized build
    /// roundtrips through the remangler on the executor.
    @Test func remanglingOnTheExecutorSurvivesADepthThatOverflowsAnEightMegabyteThread() async throws {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) else { return }
        let mangled = StackSafetyTests.deeplyNestedOptionalSymbol(nestingDepth: 200)
        let node = try await demangleAsNode(mangled, internsSubtrees: false)
        let remangled = try await withTaskExecutorPreference(StackSafeExecutor.taskExecutor) {
            try mangleAsString(node)
        }
        // `mangleAsString` emits the `_$s` form; compare past the prefix.
        #expect(remangled.stripManglePrefix == mangled.stripManglePrefix)
    }

    /// Past the remangler's depth limit the executor path throws instead of
    /// crashing — the other assertion `StackSafetyTests` had to drop.
    @Test func remanglingOnTheExecutorDegradesPastTheDepthLimitInsteadOfCrashing() async throws {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) else { return }
        let node = try await demangleAsNode(StackSafetyTests.deeplyNestedOptionalSymbol(nestingDepth: 1000), internsSubtrees: false)
        let outcome: Result<String, ManglingError> = await withTaskExecutorPreference(StackSafeExecutor.taskExecutor) {
            Result { () throws(ManglingError) -> String in try mangleAsString(node) }
        }
        switch outcome {
        case .success:
            Issue.record("1000 levels must exceed Remangler.maxDepth")
        case .failure(let error):
            guard case .tooComplex = error else {
                Issue.record("expected .tooComplex, got \(error)")
                return
            }
        }
    }
}
