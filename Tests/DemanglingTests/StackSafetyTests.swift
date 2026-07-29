import Foundation
import Testing
@_spi(Internals) @testable import Demangling

/// Regression tests for the stack-safety model.
///
/// The model matches the Swift project's: engines carry fixed depth limits
/// calibrated for an 8MB stack — the stack upstream gives every thread that
/// demangles — and `StackSafeExecutor` moves work onto such a stack when the
/// calling thread is low. The limits are recalibrated for this library's
/// unoptimized builds (upstream's own constants assume release frames and
/// overflow an 8MB debug stack before they fire; measured at 725 surviving
/// printer levels against a limit of 768). Iterative whole-tree walks —
/// interning, `copy()`, `Rewriter`, teardown, the remangler's substitution
/// hash — stay iterative, because no entry-point guard can reach them.
///
/// These tests must pass in **both** debug and release — the two
/// configurations sit on opposite sides of every failure here, and testing
/// only one is how the original defects survived review.
@Suite("StackSafety")
struct StackSafetyTests {
    // MARK: - Helpers

    /// A symbol whose type nests `nestingDepth` levels of `Optional`, standing
    /// in for the deeply nested generic types real `some View` bodies produce.
    static func deeplyNestedOptionalSymbol(nestingDepth: Int) -> String {
        "$sSi" + String(repeating: "Sg", count: nestingDepth) + "D"
    }

    /// The stack a Swift Concurrency cooperative worker and a libdispatch
    /// worker both get on Darwin. Every entry point has to survive being called
    /// from one.
    static let cooperativeWorkerStackSize = 512 * 1024

    /// What the main thread gets on Darwin. It clears the executor's
    /// remaining-stack threshold and runs inline, so it needs its own
    /// coverage: the depth limits must produce the same output inline as on a
    /// worker.
    static let mainThreadStackSize = 8 * 1024 * 1024

    /// Large enough that building and releasing the probe trees themselves can
    /// never be what fails.
    static let hostStackSize = 256 * 1024 * 1024

    static func runOnThread(stackSize: Int, _ body: @escaping @Sendable () -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        let thread = Thread {
            body()
            semaphore.signal()
        }
        thread.stackSize = stackSize
        thread.start()
        semaphore.wait()
    }

    /// Holds trees built on a large-stack thread so the tests can control which
    /// thread each phase runs on.
    final class TreeBox: @unchecked Sendable {
        var trees: [Node] = []
        var completed = false
    }

    // MARK: - Depth capability and degradation

    /// Real nesting depths print in full, and pathological ones degrade to
    /// `<<too complex>>` instead of overflowing the stack.
    ///
    /// The second half is the regression this suite exists for: the printer's
    /// limit used to be upstream's 768, which needs ~8.9MB of unoptimized
    /// frames — a debug build crashed the process at ~370 levels of nesting
    /// and the marker never appeared. The recalibrated limit fits the 8MB
    /// stack `StackSafeExecutor` provides, so 200 levels (five times the
    /// deepest real-world symbol measured) print in full and 1000 levels
    /// produce the marker in every build configuration.
    @Test func printingDegradesInsteadOfCrashingBeyondTheDepthLimit() throws {
        let fullyPrintedDepth = 200
        let fullyPrintedNode = try demangleAsNode(Self.deeplyNestedOptionalSymbol(nestingDepth: fullyPrintedDepth), internsSubtrees: false)
        let fullyPrinted = fullyPrintedNode.print(using: .default)
        #expect(!fullyPrinted.contains("<<too complex>>"), "\(fullyPrintedDepth) levels of nesting should print in full")
        #expect(fullyPrinted.hasPrefix(String(repeating: "Swift.Optional<", count: 8)))
        #expect(fullyPrinted.hasSuffix(String(repeating: ">", count: 8)))

        let truncatedDepth = 1000
        let truncatedNode = try demangleAsNode(Self.deeplyNestedOptionalSymbol(nestingDepth: truncatedDepth), internsSubtrees: false)
        let truncated = truncatedNode.print(using: .default)
        #expect(truncated.contains("<<too complex>>"), "\(truncatedDepth) levels should degrade, not print in full on borrowed luck")
    }

    /// Depths that fit the remangler's limit roundtrip; deeper ones throw
    /// `.tooComplex` quickly instead of crashing or burning CPU.
    ///
    /// Two regressions in one: the depth limit must actually be reachable
    /// (upstream's own `hashForNode` recursion sat outside the `mangle` depth
    /// counter and crashed a debug 8MB stack at ~180 levels, before the
    /// counter ever fired — the iterative rewrite is what closes that), and
    /// its rejection must stay cheap (with no depth limit, rejecting by stack
    /// exhaustion cost CPU proportional to limit × tree size: minutes for a
    /// 64KB symbol, against 0.1s for the depth check).
    @Test func remanglingRoundtripsWithinTheDepthLimitAndRejectsBeyondIt() throws {
        let roundtripDepth = 90
        let roundtripMangled = Self.deeplyNestedOptionalSymbol(nestingDepth: roundtripDepth)
        let roundtripNode = try demangleAsNode(roundtripMangled, internsSubtrees: false)
        let remangled = try mangleAsString(roundtripNode)
        // `mangleAsString` emits the `_$s` form; compare past the prefix.
        #expect(remangled.stripManglePrefix == roundtripMangled.stripManglePrefix)

        // 150 levels overflowed an unoptimized 8MB stack when the limit was
        // upstream's 1024 — the depth check must fire before the stack dies.
        for rejectedDepth in [150, 1000] {
            let rejectedNode = try demangleAsNode(Self.deeplyNestedOptionalSymbol(nestingDepth: rejectedDepth), internsSubtrees: false)
            #expect(throws: ManglingError.self) {
                try mangleAsString(rejectedNode)
            }
        }
    }

    // MARK: - Independence from the calling thread

    /// Printing must not depend on which thread produced it.
    ///
    /// A 512KB cooperative worker hops to an 8MB pool worker; the main
    /// thread's 8MB runs inline. The depth limit is a frame count, so both
    /// produce byte-identical output — including where the `<<too complex>>`
    /// marker lands on a pathologically deep tree.
    @Test(arguments: [200, 1000])
    func printedOutputIsIndependentOfTheCallingThreadStackSize(nestingDepth: Int) {
        final class OutputBox: @unchecked Sendable {
            var printedByStackSize: [Int: String] = [:]
        }
        let box = OutputBox()
        let mangled = Self.deeplyNestedOptionalSymbol(nestingDepth: nestingDepth)
        let stackSizes = [Self.cooperativeWorkerStackSize, Self.mainThreadStackSize]

        for stackSize in stackSizes {
            Self.runOnThread(stackSize: stackSize) {
                guard let tree = try? demangleAsNode(mangled, internsSubtrees: false) else { return }
                box.printedByStackSize[stackSize] = tree.print(using: .default)
            }
        }

        let outputs = stackSizes.compactMap { box.printedByStackSize[$0] }
        #expect(outputs.count == stackSizes.count, "every thread should have produced output")
        #expect(Set(outputs).count == 1, "print result differed by calling thread stack size")
    }

    /// The type decoder runs entirely on the calling thread — its `TypeBuilder`
    /// callbacks are user code that may be thread-bound, so unlike printing and
    /// remangling it never hops. Stack headroom is the caller's job: wrapping
    /// the batch in `withLargeStack` is the documented pattern, and inside it a
    /// depth well past any real symbol decodes in full even from a cooperative
    /// worker.
    @Test func decodesDeeplyNestedTypeInsideWithLargeStack() {
        final class ResultBox: @unchecked Sendable {
            var decoded: String?
            var failureDescription: String?
            var deepRejectionDescription: String?
        }
        let box = ResultBox()
        let nestingDepth = 60
        let mangled = Self.deeplyNestedOptionalSymbol(nestingDepth: nestingDepth)

        Self.runOnThread(stackSize: Self.cooperativeWorkerStackSize) {
            StackSafeExecutor.withLargeStack {
                do {
                    let node = try demangleAsNode(mangled, internsSubtrees: false)
                    let decoder = TypeDecoder(builder: StringTypeBuilder())
                    box.decoded = try decoder.decodeMangledType(node: node)
                } catch {
                    box.failureDescription = "\(error)"
                }

                // 130 levels overflowed an unoptimized 8MB stack when the
                // limit was upstream's 1024 — the depth check must throw
                // before the stack dies.
                do {
                    let deepNode = try demangleAsNode(Self.deeplyNestedOptionalSymbol(nestingDepth: 130), internsSubtrees: false)
                    let decoder = TypeDecoder(builder: StringTypeBuilder())
                    _ = try decoder.decodeMangledType(node: deepNode)
                } catch {
                    box.deepRejectionDescription = "\(error)"
                }
            }
        }

        let expectedType = String(repeating: "Optional<", count: nestingDepth) + "Int" + String(repeating: ">", count: nestingDepth)
        #expect(box.failureDescription == nil, "decoding failed: \(box.failureDescription ?? "")")
        #expect(box.decoded == expectedType)
        #expect(box.deepRejectionDescription != nil, "a pathologically deep type must be rejected, not decoded on borrowed luck")
    }

    /// The other half of the decoder's contract: every `TypeBuilder` callback
    /// runs on the thread that called `decodeMangledType`. Routing the walk
    /// through a worker would silently move user code — `@MainActor`-adjacent
    /// caches, Core Data contexts — onto a background thread behind a
    /// synchronous-looking call.
    @Test func typeDecoderInvokesBuilderCallbacksOnTheCallingThread() throws {
        let recorder = CallbackThreadRecorder()
        var builder = StringTypeBuilder()
        builder.callbackThreadRecorder = recorder

        let node = try demangleAsNode("$sSaySiGD", internsSubtrees: false)
        let decoder = TypeDecoder(builder: builder)
        let decoded = try decoder.decodeMangledType(node: node)

        #expect(decoded == "Array<Int>")
        let callingThread = pthread_mach_thread_np(pthread_self())
        #expect(!recorder.observedThreads.isEmpty, "the builder should have been called back")
        #expect(recorder.observedThreads == [callingThread], "builder callbacks left the calling thread")
    }

    // MARK: - Never crash

    /// Remangling used to walk the substitution hash and deep-equality helpers
    /// recursively. Neither passes back through `mangle(_:depth:)`, so both sat
    /// outside the only depth check the remangler had, and a deep tree on a
    /// small stack took the process down instead of returning an error.
    @Test func remanglingDeepTreeOnCooperativeWorkerStackNeverCrashes() throws {
        let box = TreeBox()
        let nestingDepths = [200, 600, 1200, 2400]

        Self.runOnThread(stackSize: Self.hostStackSize) {
            for nestingDepth in nestingDepths {
                box.trees.append(try! demangleAsNode(Self.deeplyNestedOptionalSymbol(nestingDepth: nestingDepth), internsSubtrees: false))
            }
        }
        Self.runOnThread(stackSize: Self.cooperativeWorkerStackSize) {
            for tree in box.trees {
                // Either outcome is acceptable; surviving the call is the point.
                _ = canMangle(tree)
            }
            box.completed = true
        }
        Self.runOnThread(stackSize: Self.hostStackSize) { box.trees.removeAll() }

        #expect(box.completed)
    }

    /// The same for printing, which additionally has to keep producing correct
    /// output rather than a truncated one.
    @Test func printingDeepTreeOnCooperativeWorkerStackNeverCrashes() throws {
        let box = TreeBox()
        let nestingDepths = [200, 600, 1200, 2400]

        Self.runOnThread(stackSize: Self.hostStackSize) {
            for nestingDepth in nestingDepths {
                box.trees.append(try! demangleAsNode(Self.deeplyNestedOptionalSymbol(nestingDepth: nestingDepth), internsSubtrees: false))
            }
        }
        Self.runOnThread(stackSize: Self.cooperativeWorkerStackSize) {
            for tree in box.trees {
                _ = tree.print(using: .default)
            }
            box.completed = true
        }
        Self.runOnThread(stackSize: Self.hostStackSize) { box.trees.removeAll() }

        #expect(box.completed)
    }

    /// Subtree interning runs on every `demangleAsNode` that leaves
    /// `internsSubtrees` at its default, and it is a whole-tree walk that no
    /// engine guard covers.
    @Test func interningDeepTreeOnCooperativeWorkerStackNeverCrashes() {
        final class ResultBox: @unchecked Sendable {
            var trees: [Node] = []
            var internedDepthCount = 0
            var everyRepeatDemangleWasCanonical = true
        }
        let box = ResultBox()
        let nestingDepths = [200, 600, 1200]

        Self.runOnThread(stackSize: Self.cooperativeWorkerStackSize) {
            for nestingDepth in nestingDepths {
                let mangled = Self.deeplyNestedOptionalSymbol(nestingDepth: nestingDepth)
                guard let firstTree = try? demangleAsNode(mangled, internsSubtrees: true),
                      let secondTree = try? demangleAsNode(mangled, internsSubtrees: true)
                else {
                    continue
                }
                // Surviving the walk is only half of it: the walk exists to
                // canonicalize, so the same symbol has to come back as the same
                // instance. An iterative rewrite that silently stopped
                // canonicalizing would pass a bare "did not crash" assertion.
                box.everyRepeatDemangleWasCanonical = box.everyRepeatDemangleWasCanonical && (firstTree === secondTree)
                box.internedDepthCount += 1
                box.trees.append(firstTree)
            }
        }
        Self.runOnThread(stackSize: Self.hostStackSize) { box.trees.removeAll() }

        #expect(box.internedDepthCount == nestingDepths.count, "every depth should have interned")
        #expect(box.everyRepeatDemangleWasCanonical, "interning must return the canonical instance")
    }

    /// `Node.copy()` and `Node.replacingDescendant(_:with:)` are public
    /// whole-tree recursions outside every engine, and `NodeBuilder` runs both
    /// while holding its lock. Nothing about them is reachable from a depth
    /// parameter, so they have to be iterative for the same reason
    /// `Node.deinit` is.
    @Test func copyingAndRewritingDeepTreeOnCooperativeWorkerStackNeverCrashes() {
        final class ResultBox: @unchecked Sendable {
            var copyMatchedOriginal = false
            var replacementTookEffect = false
            var completed = false
        }
        let box = ResultBox()
        let treeBox = TreeBox()

        Self.runOnThread(stackSize: Self.hostStackSize) {
            treeBox.trees.append(try! demangleAsNode(Self.deeplyNestedOptionalSymbol(nestingDepth: 2400), internsSubtrees: false))
        }
        Self.runOnThread(stackSize: Self.cooperativeWorkerStackSize) {
            let tree = treeBox.trees[0]

            let copiedTree = tree.copy()
            box.copyMatchedOriginal = copiedTree == tree && copiedTree !== tree

            var deepestInteriorNode = tree
            while let firstChild = deepestInteriorNode.children.first, !firstChild.children.isEmpty {
                deepestInteriorNode = firstChild
            }
            let rewrittenTree = tree.replacingDescendant(deepestInteriorNode, with: NodeFactory.emptyList)
            box.replacementTookEffect = rewrittenTree != tree

            treeBox.trees.append(copiedTree)
            treeBox.trees.append(rewrittenTree)
            box.completed = true
        }
        Self.runOnThread(stackSize: Self.hostStackSize) { treeBox.trees.removeAll() }

        #expect(box.completed)
        #expect(box.copyMatchedOriginal, "copy() must produce a structurally equal, distinct tree")
        #expect(box.replacementTookEffect, "replacingDescendant must actually replace")
    }

    /// `Node.Rewriter` is public, is not routed through a large-stack worker,
    /// and carries no depth parameter — the same position `Node.copy()` was in.
    @Test func rewritingDeepTreeOnCooperativeWorkerStackNeverCrashes() {
        /// Renames every identifier, so the rewrite rebuilds the whole spine
        /// rather than short-circuiting on unchanged children.
        final class IdentifierRenamingRewriter: Node.Rewriter, @unchecked Sendable {
            var visitCount = 0
            override func visit(_ node: Node) -> Node {
                visitCount += 1
                guard node.kind == .identifier, let text = node.text else { return node }
                return Node.createTransient(kind: .identifier, text: text + "_renamed")
            }
        }

        final class ResultBox: @unchecked Sendable {
            var visitCount = 0
            var rewrittenRootKind: Node.Kind?
        }
        let box = ResultBox()
        let treeBox = TreeBox()

        Self.runOnThread(stackSize: Self.hostStackSize) {
            treeBox.trees.append(try! demangleAsNode(Self.deeplyNestedOptionalSymbol(nestingDepth: 2400), internsSubtrees: false))
        }
        Self.runOnThread(stackSize: Self.cooperativeWorkerStackSize) {
            let rewriter = IdentifierRenamingRewriter()
            let rewrittenTree = rewriter.rewrite(treeBox.trees[0])
            box.visitCount = rewriter.visitCount
            box.rewrittenRootKind = rewrittenTree.kind
            treeBox.trees.append(rewrittenTree)
        }
        Self.runOnThread(stackSize: Self.hostStackSize) { treeBox.trees.removeAll() }

        #expect(box.rewrittenRootKind == .global)
        #expect(box.visitCount > 2400, "every node should have been visited")
    }

    /// `NodeStoreBuilder.demangle` runs the transient demangle through
    /// `StackSafeExecutor` but interns the resulting tree afterwards, on the
    /// caller's own thread — during bulk indexing that is a 512KB cooperative
    /// worker, and it is precisely where the deepest generic types arrive. The
    /// interning walk therefore has to be iterative; recursion there took the
    /// process down at 500 levels in debug and 1200 in release.
    @Test func storeInterningDeepTreeOnCooperativeWorkerStackNeverCrashes() {
        final class ResultBox: @unchecked Sendable {
            var internedNodeCounts: [Int] = []
        }
        let box = ResultBox()

        Self.runOnThread(stackSize: Self.cooperativeWorkerStackSize) {
            for nestingDepth in [200, 600, 1200, 2400] {
                var builder = NodeStoreBuilder()
                guard let rootIndex = try? builder.demangle(Self.deeplyNestedOptionalSymbol(nestingDepth: nestingDepth)) else {
                    continue
                }
                let store = builder.freeze()
                _ = store.reference(at: rootIndex)
                box.internedNodeCounts.append(store.nodeCount)
            }
        }

        #expect(box.internedNodeCounts.count == 4)
        #expect(box.internedNodeCounts == box.internedNodeCounts.sorted(), "deeper symbols should intern more nodes")
    }

    // MARK: - Deallocation

    /// Releasing a tree recurses once per level in the runtime, not in this
    /// library, so no engine-side budget can cover it. A tree deep enough to be
    /// worth supporting has to be *releasable* on a cooperative worker too.
    @Test func releasingDeepTreeOnCooperativeWorkerStackNeverCrashes() {
        let box = TreeBox()

        Self.runOnThread(stackSize: Self.hostStackSize) {
            for nestingDepth in [600, 1200, 2400] {
                box.trees.append(try! demangleAsNode(Self.deeplyNestedOptionalSymbol(nestingDepth: nestingDepth), internsSubtrees: false))
            }
        }
        Self.runOnThread(stackSize: Self.cooperativeWorkerStackSize) {
            box.trees.removeAll()
            box.completed = true
        }

        #expect(box.completed)
    }

    /// The iterative teardown must only dismantle nodes it holds the last
    /// reference to. A subtree that is still referenced elsewhere has to come
    /// through the root's deallocation intact.
    @Test func releasingTreeKeepsSharedSubtreesIntact() throws {
        let sharedSubtree = try demangleAsNode("$sSaySiGD", internsSubtrees: false)
        let expectedDescription = sharedSubtree.description

        do {
            let builder = NodeBuilder(kind: .global)
            builder.addChild(sharedSubtree)
            builder.addChild(sharedSubtree)
            _ = builder.build()
        }

        #expect(sharedSubtree.description == expectedDescription)
        #expect(sharedSubtree.children.count > 0)
    }

    /// Deallocation must actually happen — an iterative teardown that dropped
    /// children on the floor instead of releasing them would leak silently.
    @Test func releasingTreeDeallocatesEveryNode() throws {
        weak var weakRoot: Node?
        weak var weakInteriorNode: Node?

        do {
            let root = try demangleAsNode(Self.deeplyNestedOptionalSymbol(nestingDepth: 50), internsSubtrees: false)
            weakRoot = root
            // Walk to a node deep in the chain that still has children: leaves
            // are interned by `NodeCache` and stay alive by design, so they say
            // nothing about whether the tree was torn down.
            var interiorNode = root
            while let firstChild = interiorNode.children.first, !firstChild.children.isEmpty {
                interiorNode = firstChild
            }
            weakInteriorNode = interiorNode
            #expect(weakRoot != nil)
            #expect(weakInteriorNode != nil)
        }

        #expect(weakRoot == nil, "the root should be deallocated")
        #expect(weakInteriorNode == nil, "the whole subtree should be deallocated, not detached and leaked")
    }
}
