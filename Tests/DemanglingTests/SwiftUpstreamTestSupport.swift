import Foundation
import Testing

struct ManglingCase: Sendable, CustomStringConvertible {
    let input: String
    let expected: String
    let sourceFile: String
    let sourceLine: Int

    var description: String {
        "\(sourceFile):\(sourceLine) \(input)"
    }
}

enum UpstreamTestInputLoader {
    static func load(_ fileName: String) -> [ManglingCase] {
        guard let resourceURL = Bundle.module.url(
            forResource: fileName,
            withExtension: "txt",
            subdirectory: "UpstreamInputs"
        ) else {
            fatalError("Missing upstream input: UpstreamInputs/\(fileName).txt")
        }

        let contents: String
        do {
            contents = try String(contentsOf: resourceURL, encoding: .utf8)
        } catch {
            fatalError("Failed to read \(resourceURL.path): \(error)")
        }

        let separator = " ---> "
        var cases: [ManglingCase] = []
        cases.reserveCapacity(512)

        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        for (zeroBasedIndex, line) in lines.enumerated() {
            let sourceLine = zeroBasedIndex + 1
            if line.isEmpty { continue }
            let trimmedLeading = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmedLeading.isEmpty { continue }
            if trimmedLeading.hasPrefix(";") || trimmedLeading.hasPrefix("//") { continue }
            guard let separatorRange = line.range(of: separator) else { continue }
            var input = String(line[..<separatorRange.lowerBound])
            while input.last == " " || input.last == "\t" {
                input.removeLast()
            }
            let expected = String(line[separatorRange.upperBound...])
            cases.append(ManglingCase(
                input: input,
                expected: expected,
                sourceFile: "\(fileName).txt",
                sourceLine: sourceLine
            ))
        }

        return cases
    }
}
