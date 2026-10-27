import Foundation
import Testing
import Demangling

public protocol DemanglingTests {
    func allSymbols() async throws -> [MachOSwiftSymbol]
    func mainTest() async throws
}

extension DemanglingTests {
    public func mainTest() async throws {
        let toolchainLibraryPath = try ToolchainDemangler.requireLoadedLibrary()
        let allSwiftSymbols = try await allSymbols()
        let totalCount = allSwiftSymbols.count

        // Chunk the work across all available cores. Each task checks its
        // chunk serially to avoid the overhead of scheduling one task per symbol.
        let concurrency = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let chunkSize = max(1, (totalCount + concurrency - 1) / concurrency)

        var allResults: [SymbolCheckResult] = []
        allResults.reserveCapacity(totalCount)

        await withTaskGroup(of: [SymbolCheckResult].self) { group in
            for chunkStart in stride(from: 0, to: totalCount, by: chunkSize) {
                let chunkEnd = min(chunkStart + chunkSize, totalCount)
                let chunk = Array(allSwiftSymbols[chunkStart..<chunkEnd])
                group.addTask {
                    chunk.map { checkSymbol(mangledName: $0.stringValue) }
                }
            }
            for await chunkResults in group {
                allResults.append(contentsOf: chunkResults)
            }
        }

        // Aggregate counters and limited-size samples.
        var successCount = 0
        var knownIssueCount = 0
        var toolchainAcceptedCount = 0
        var demangleFailCount = 0
        var nodeTreeMismatchCount = 0
        var remangleMismatchCount = 0
        var printComparisonCount = 0
        var printMismatchCount = 0
        var simplifiedPrintComparisonCount = 0
        var simplifiedPrintMismatchCount = 0
        var printMismatchCountsByShape: [String: Int] = [:]

        let maxSamples = 10
        var demangleFailSamples: [String] = []
        var nodeTreeMismatchSamples: [String] = []
        var remangleMismatchSamples: [String] = []
        var printMismatchSamples: [String] = []
        var simplifiedPrintMismatchSamples: [String] = []

        for result in allResults {
            successCount += result.addSuccess
            knownIssueCount += result.addKnownIssues
            toolchainAcceptedCount += result.addToolchainAccepted
            demangleFailCount += result.addDemangleFails
            nodeTreeMismatchCount += result.addNodeTreeMismatches
            remangleMismatchCount += result.addRemangleMismatches
            printComparisonCount += result.addPrintComparisons
            printMismatchCount += result.addPrintMismatches
            simplifiedPrintComparisonCount += result.addSimplifiedPrintComparisons
            simplifiedPrintMismatchCount += result.addSimplifiedPrintMismatches

            if let sample = result.demangleFailSample, demangleFailSamples.count < maxSamples {
                demangleFailSamples.append(sample)
            }
            if let sample = result.nodeTreeMismatchSample, nodeTreeMismatchSamples.count < maxSamples {
                nodeTreeMismatchSamples.append(sample)
            }
            if let sample = result.remangleMismatchSample, remangleMismatchSamples.count < maxSamples {
                remangleMismatchSamples.append(sample)
            }
            if let sample = result.printMismatchSample, printMismatchSamples.count < maxSamples {
                printMismatchSamples.append(sample)
            }
            if let sample = result.simplifiedPrintMismatchSample, simplifiedPrintMismatchSamples.count < maxSamples {
                simplifiedPrintMismatchSamples.append(sample)
            }
            if let shape = result.printMismatchShape {
                printMismatchCountsByShape[shape, default: 0] += 1
            }
        }

        // Print summary
        print("""

        ═══ Demangling Alignment Report ═══
        Toolchain demangler:   \(toolchainLibraryPath)
        Total symbols:         \(totalCount)
        Toolchain accepted:    \(toolchainAcceptedCount)
        Passed:                \(successCount)
        Known issues (skip):   \(knownIssueCount)
        Demangle failures:     \(demangleFailCount)
        Node tree mismatches:  \(nodeTreeMismatchCount)
        Remangle mismatches:   \(remangleMismatchCount)
        Print mismatches:      \(printMismatchCount) of \(printComparisonCount)
        Simplified mismatches: \(simplifiedPrintMismatchCount) of \(simplifiedPrintComparisonCount)
        """)

        if !demangleFailSamples.isEmpty {
            print("--- Demangle Failures (first \(demangleFailSamples.count)) ---")
            for sample in demangleFailSamples {
                print(sample)
            }
        }
        if !nodeTreeMismatchSamples.isEmpty {
            print("--- Node Tree Mismatches (first \(nodeTreeMismatchSamples.count)) ---")
            for sample in nodeTreeMismatchSamples {
                print(sample)
            }
        }
        if !remangleMismatchSamples.isEmpty {
            print("--- Remangle Mismatches (first \(remangleMismatchSamples.count)) ---")
            for sample in remangleMismatchSamples {
                print(sample)
            }
        }
        if !printMismatchSamples.isEmpty {
            print("--- Print Mismatches (first \(printMismatchSamples.count)) ---")
            for sample in printMismatchSamples {
                print(sample)
            }
        }
        if !simplifiedPrintMismatchSamples.isEmpty {
            print("--- Simplified Print Mismatches (first \(simplifiedPrintMismatchSamples.count)) ---")
            for sample in simplifiedPrintMismatchSamples {
                print(sample)
            }
        }
        if !printMismatchCountsByShape.isEmpty {
            print("--- Print Mismatches by Top-Level Node Kinds ---")
            for (shape, count) in printMismatchCountsByShape.sorted(by: { $0.value > $1.value }) {
                print("  \(count)\t\(shape)")
            }
        }

        // A run in which the toolchain accepted nothing compared nothing: the
        // tree and text checks below are all skipped for a symbol it rejects.
        #expect(toolchainAcceptedCount > 0, "the toolchain demangler accepted none of \(totalCount) symbols, so nothing was compared")
        // Text mismatches are counted rather than recorded one issue per
        // symbol: a preset-wide divergence would otherwise record one for
        // every symbol in the corpus. The samples above name them.
        #expect(printMismatchCount == 0, "\(printMismatchCount) symbols print differently from the toolchain under .default")
        #expect(simplifiedPrintMismatchCount == 0, "\(simplifiedPrintMismatchCount) symbols print differently from the toolchain under .simplified")
    }
}

private struct SymbolCheckResult: Sendable {
    var addSuccess: Int = 0
    var addKnownIssues: Int = 0
    var addToolchainAccepted: Int = 0
    var addDemangleFails: Int = 0
    var addNodeTreeMismatches: Int = 0
    var addRemangleMismatches: Int = 0
    var addPrintComparisons: Int = 0
    var addPrintMismatches: Int = 0
    var addSimplifiedPrintComparisons: Int = 0
    var addSimplifiedPrintMismatches: Int = 0
    var demangleFailSample: String?
    var nodeTreeMismatchSample: String?
    var remangleMismatchSample: String?
    var printMismatchSample: String?
    var simplifiedPrintMismatchSample: String?
    /// The kinds of the symbol's top-level nodes, for grouping text mismatches
    /// by what the symbol is.
    var printMismatchShape: String?
}

private func checkSymbol(mangledName: String) -> SymbolCheckResult {
    var result = SymbolCheckResult()
    let toolchainTree = ToolchainDemangler.nodeTree(for: mangledName)
    if toolchainTree != nil {
        result.addToolchainAccepted = 1
    }

    do {
        let node = try demangleAsNode(mangledName)
        var allPassed = true

        // 1. Node tree check
        if let toolchainTree {
            let ourTree = node.description + "\n"
            if toolchainTree != ourTree {
                if isOpaqueReturnTypeParentDifference(toolchainTree, ourTree) {
                    result.addKnownIssues += 1
                } else {
                    allPassed = false
                    result.addNodeTreeMismatches = 1
                    result.nodeTreeMismatchSample = mangledName
                    Issue.record("Node tree mismatch: \(mangledName)")
                }
            }
        }

        // 2. Remangle check
        let remangled = try Demangling.mangleAsString(node)
        if remangled != mangledName {
            // Known issue: Md vs MD (Apple-internal lowercase 'd')
            if mangledName.hasSuffix("Md"), remangled.hasSuffix("MD"),
               mangledName.dropLast(2) == remangled.dropLast(2) {
                result.addKnownIssues += 1
            } else {
                allPassed = false
                result.addRemangleMismatches = 1
                result.remangleMismatchSample = "  \(mangledName)\n    remangled: \(remangled)"
                Issue.record("Remangle mismatch: \(mangledName)")
            }
        }

        // 3. Printed text, under the two presets the toolchain library exports.
        // The tree check cannot see a printer that renders a correct tree
        // wrongly, and neither can the remangle check, which never prints.
        if let toolchainText = ToolchainDemangler.demangledName(for: mangledName) {
            result.addPrintComparisons = 1
            let ourText = node.print(using: .default.union(.synthesizeSugarOnTypes))
            if ourText != toolchainText {
                allPassed = false
                result.addPrintMismatches = 1
                result.printMismatchSample = "  \(mangledName)\n    toolchain: \(toolchainText)\n    ours:      \(ourText)"
                result.printMismatchShape = topLevelShape(of: node)
            }
        }
        if let toolchainSimplifiedText = ToolchainDemangler.simplifiedDemangledName(for: mangledName) {
            result.addSimplifiedPrintComparisons = 1
            let ourSimplifiedText = node.print(using: .simplified)
            if ourSimplifiedText != toolchainSimplifiedText {
                allPassed = false
                result.addSimplifiedPrintMismatches = 1
                result.simplifiedPrintMismatchSample = "  \(mangledName)\n    toolchain: \(toolchainSimplifiedText)\n    ours:      \(ourSimplifiedText)"
                result.printMismatchShape = topLevelShape(of: node)
            }
        }

        if allPassed { result.addSuccess = 1 }
    } catch {
        if toolchainTree != nil {
            // The toolchain succeeded but we failed
            result.addDemangleFails = 1
            result.demangleFailSample = "  \(mangledName) — \(error)"
            Issue.record("Demangle failed: \(mangledName): \(error)")
        } else {
            result.addSuccess = 1 // both failed = consistent
        }
    }

    return result
}

private func topLevelShape(of node: Node) -> String {
    node.children.map { "\($0.kind)" }.joined(separator: " ")
}

/// Check if the difference between two tree strings is only in OpaqueReturnTypeParent lines.
private func isOpaqueReturnTypeParentDifference(_ lhs: String, _ rhs: String) -> Bool {
    let filteredLhs = lhs.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.contains("OpaqueReturnTypeParent") }
    let filteredRhs = rhs.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.contains("OpaqueReturnTypeParent") }
    return filteredLhs == filteredRhs
}
