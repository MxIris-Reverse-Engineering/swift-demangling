import Foundation
import Testing
import Demangling

public protocol DemanglingTests {
    func allSymbols() async throws -> [MachOSwiftSymbol]
    func mainTest() async throws
}

extension DemanglingTests {
    public func mainTest() async throws {
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
        var demangleFailCount = 0
        var nodeTreeMismatchCount = 0
        var remangleMismatchCount = 0

        let maxSamples = 10
        var demangleFailSamples: [String] = []
        var nodeTreeMismatchSamples: [String] = []
        var remangleMismatchSamples: [String] = []

        for result in allResults {
            successCount += result.addSuccess
            knownIssueCount += result.addKnownIssues
            demangleFailCount += result.addDemangleFails
            nodeTreeMismatchCount += result.addNodeTreeMismatches
            remangleMismatchCount += result.addRemangleMismatches

            if let sample = result.demangleFailSample, demangleFailSamples.count < maxSamples {
                demangleFailSamples.append(sample)
            }
            if let sample = result.nodeTreeMismatchSample, nodeTreeMismatchSamples.count < maxSamples {
                nodeTreeMismatchSamples.append(sample)
            }
            if let sample = result.remangleMismatchSample, remangleMismatchSamples.count < maxSamples {
                remangleMismatchSamples.append(sample)
            }
        }

        // Print summary
        print("""

        ═══ Demangling Alignment Report ═══
        Total symbols:         \(totalCount)
        Passed:                \(successCount)
        Known issues (skip):   \(knownIssueCount)
        Demangle failures:     \(demangleFailCount)
        Node tree mismatches:  \(nodeTreeMismatchCount)
        Remangle mismatches:   \(remangleMismatchCount)
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
    }
}

private struct SymbolCheckResult: Sendable {
    var addSuccess: Int = 0
    var addKnownIssues: Int = 0
    var addDemangleFails: Int = 0
    var addNodeTreeMismatches: Int = 0
    var addRemangleMismatches: Int = 0
    var demangleFailSample: String?
    var nodeTreeMismatchSample: String?
    var remangleMismatchSample: String?
}

private func checkSymbol(mangledName: String) -> SymbolCheckResult {
    var result = SymbolCheckResult()
    let stdlibTree = stdlib_demangleNodeTree(mangledName)

    do {
        let node = try demangleAsNode(mangledName)
        var allPassed = true

        // 1. Node tree check
        if let stdlibTree {
            let ourTree = node.description + "\n"
            if stdlibTree != ourTree {
                if isOpaqueReturnTypeParentDifference(stdlibTree, ourTree) {
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

        if allPassed { result.addSuccess = 1 }
    } catch {
        if stdlibTree != nil {
            // stdlib succeeded but we failed
            result.addDemangleFails = 1
            result.demangleFailSample = "  \(mangledName) — \(error)"
            Issue.record("Demangle failed: \(mangledName): \(error)")
        } else {
            result.addSuccess = 1 // both failed = consistent
        }
    }

    return result
}

/// Check if the difference between two tree strings is only in OpaqueReturnTypeParent lines.
private func isOpaqueReturnTypeParentDifference(_ lhs: String, _ rhs: String) -> Bool {
    let filteredLhs = lhs.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.contains("OpaqueReturnTypeParent") }
    let filteredRhs = rhs.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.contains("OpaqueReturnTypeParent") }
    return filteredLhs == filteredRhs
}
