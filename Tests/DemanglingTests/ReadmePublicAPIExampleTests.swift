import Testing

// A plain `import`, deliberately — NOT `@testable`.
//
// This file exists to compile README examples the way a *consumer* compiles
// them, so anything the README shows must be public. `ReadmeExampleTests`
// cannot serve that purpose: it uses `@testable import`, which raises internal
// symbols into view, so an example calling an internal method compiles there
// and fails for every reader of the README.
//
// That is exactly what had happened. The "Building & Modifying Trees" example
// called `node.addingChild(_:)`, `node.replacingDescendant(_:with:)` and
// `node.changeKind(_:)` on `Node` directly; all three are internal, since the
// public path is `NodeBuilder` (nodes it hands out are frozen, which is what
// makes cyclic trees unconstructible). The snippet could never have compiled
// outside this package.
import Demangling

/// The tree-building and tree-rewriting examples from `README.md`, compiled
/// against the public API.
///
/// **When this file changes, change `README.md` in the same commit** — the same
/// contract `ReadmeExampleTests` carries, for the same reason: prose is
/// invisible to the compiler.
@Suite
struct ReadmePublicAPIExampleTests {
    @Test func readmeTreeBuildingExampleUsesOnlyPublicAPI() throws {
        let node = try demangleAsNode("$s4main1fyyF")
        let element1 = Node.create(kind: .identifier, text: "first")
        let element2 = Node.create(kind: .identifier, text: "second")
        let newChild = Node.create(kind: .identifier, text: "added")
        let oldNode = try #require(node.first(of: .identifier))
        let newNode = Node.create(kind: .identifier, text: "renamed")

        // MARK: - Verbatim from README.md, "Building & Modifying Trees"

        // Build a new node tree
        let builder = NodeBuilder(kind: .tuple)
        builder.addChild(element1)
        builder.addChild(element2)
        let tupleNode = builder.build()

        // Non-mutating transformations (return new nodes)
        let modified = NodeBuilder(node).addingChild(newChild)
        let replaced = NodeBuilder(node).replacingDescendant(oldNode, with: newNode)
        let changed = NodeBuilder(node).changingKind(.structure)

        // MARK: - Behaviour the example promises

        #expect(tupleNode.kind == .tuple)
        #expect(tupleNode.children.count == 2)
        #expect(modified.children.count == node.children.count + 1)
        #expect(replaced.first(of: .identifier)?.text == "renamed")
        #expect(changed.kind == .structure)
        // The original is untouched: every node the builder hands out is frozen.
        #expect(node.kind == .global)
        #expect(node.first(of: .identifier)?.text == "f")
    }

    /// The two builder initializers are split along the contents/children
    /// exclusion, and both spellings the README names are public.
    @Test func builderInitializersAreSplitAlongTheContentsChildrenExclusion() {
        let leaf = NodeBuilder(kind: .identifier, contents: .text("name")).build()
        #expect(leaf.text == "name")
        #expect(leaf.children.isEmpty)

        let parent = NodeBuilder(kind: .type, children: [leaf]).build()
        #expect(parent.children.count == 1)
        #expect(parent.text == nil)
    }

    // MARK: - Verbatim from README.md, "Tree Rewriting"

    class ModuleRenamer: Node.Rewriter {
        override func visit(_ node: Node) -> Node {
            if node.kind == .module, node.text == "OldName" {
                return Node.create(kind: .module, text: "NewName")
            }
            return node
        }
    }

    /// The rewriting example. It had the same defect as the building one — it
    /// constructed through `Node(kind:contents:)`, which is internal — and was
    /// invisible for the same reason: the only file compiling README examples
    /// used `@testable import`.
    @Test func readmeTreeRewritingExampleUsesOnlyPublicAPI() throws {
        let originalTree = try demangleAsNode("$s7OldName1fyyF")

        let rewriter = ModuleRenamer()
        let rewritten = rewriter.rewrite(originalTree)

        #expect(originalTree.first(of: .module)?.text == "OldName")
        #expect(rewritten.first(of: .module)?.text == "NewName")
    }
}
