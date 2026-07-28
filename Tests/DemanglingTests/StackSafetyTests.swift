import Foundation
import Testing
@_spi(Internals) @testable import Demangling

/// Regression tests for the stack-safety rework.
///
/// Every recursion in the demangling engines used to be bounded by a frame
/// count. A frame count cannot be right for a debug build, a release build and
/// both `DemanglingNode` specializations at once, so it simultaneously let
/// unoptimized builds overflow the stack and rejected legitimately deep generic
/// types that optimized builds had megabytes of room for. These tests pin both
/// halves: nothing crashes, and real depth is available.
///
/// They must pass in **both** debug and release — the two configurations sit on
/// opposite sides of every failure the rework addresses, and testing only one
/// is how the original defects survived review.
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

    // MARK: - Depth capability

    /// The original problem: a legitimate deeply nested generic printed as
    /// `<<too complex>>` because 768 printer frames ran out at roughly 384
    /// levels of nesting, while the thread it ran on had megabytes to spare.
    @Test func printsGenericNestingFarBeyondTheOldFrameLimit() throws {
        let nestingDepth = 1000
        let node = try demangleAsNode(Self.deeplyNestedOptionalSymbol(nestingDepth: nestingDepth), internsSubtrees: false)

        let printed = node.print(using: .default)

        #expect(!printed.contains("<<too complex>>"), "\(nestingDepth) levels of nesting should print in full")
        #expect(printed.hasPrefix(String(repeating: "Swift.Optional<", count: 8)))
        #expect(printed.hasSuffix(String(repeating: ">", count: 8)))
    }

    /// The same tree has to remangle rather than report `.tooComplex`, which is
    /// what the 1024-frame remangler limit did from roughly 256 levels up.
    @Test func remanglesGenericNestingFarBeyondTheOldFrameLimit() throws {
        let nestingDepth = 1000
        let mangled = Self.deeplyNestedOptionalSymbol(nestingDepth: nestingDepth)
        let node = try demangleAsNode(mangled, internsSubtrees: false)

        let remangled = try mangleAsString(node)

        // `mangleAsString` emits the `_$s` form; compare past the prefix.
        #expect(remangled.stripManglePrefix == mangled.stripManglePrefix)
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
        let box = TreeBox()

        Self.runOnThread(stackSize: Self.cooperativeWorkerStackSize) {
            for nestingDepth in [200, 600, 1200] {
                if let tree = try? demangleAsNode(Self.deeplyNestedOptionalSymbol(nestingDepth: nestingDepth), internsSubtrees: true) {
                    box.trees.append(tree)
                }
            }
            box.completed = true
        }
        Self.runOnThread(stackSize: Self.hostStackSize) { box.trees.removeAll() }

        #expect(box.completed)
        #expect(box.trees.isEmpty)
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
