/// Punycode encoding and decoding utilities
enum Punycode {
    // Punycode constants (from RFC 3492, adapted for Swift)
    private static let base = 36
    private static let tmin = 1
    private static let tmax = 26
    private static let skew = 38
    private static let damp = 700
    private static let initialBias = 72
    private static let initialN = 128
    private static let delimiter: Character = "_"

    /// Encode a string using Punycode
    ///
    /// - Parameters:
    ///   - input: The string to encode
    ///   - mapNonSymbolChars: Whether to map non-symbol characters (ASCII < 0x80) to 0xD800 range
    /// - Returns: The encoded string, or nil if encoding fails
    static func encodePunycode(_ input: String, mapNonSymbolChars: Bool) -> String? {
        // Convert input to Unicode scalars, applying character mapping as needed
        // This mirrors the C++ convertUTF8toUTF32 function behavior
        var codePoints = [UInt32]()

        for scalar in input.unicodeScalars {
            let value = scalar.value

            // For ASCII characters (< 0x80), check if we need to map non-symbol chars
            if value < 0x80 {
                // Check if it's a valid symbol character
                let isValidSymbol = isValidSymbolChar(UInt8(value))

                if isValidSymbol || !mapNonSymbolChars {
                    // Valid symbol char, or we're not mapping - use as-is
                    codePoints.append(value)
                } else {
                    // Non-symbol char and we're mapping - map to 0xD800 + value
                    codePoints.append(0xD800 + value)
                }
            } else {
                // Non-ASCII character - validate and use as-is
                if !isValidUnicodeScalar(value) {
                    return nil
                }
                codePoints.append(value)
            }
        }

        return encodePunycode(codePoints)
    }

    /// Check if a character is a valid symbol character (can appear in mangled names)
    /// Matches C++ isValidSymbolChar: letters, digits, underscore, dollar sign
    private static func isValidSymbolChar(_ ch: UInt8) -> Bool {
        return isValidSymbolStart(ch) || isDigit(ch)
    }

    /// Check if a character can start a symbol
    private static func isValidSymbolStart(_ ch: UInt8) -> Bool {
        return isLetter(ch) || ch == UInt8(ascii: "_") || ch == UInt8(ascii: "$")
    }

    /// Check if character is a letter (a-z, A-Z)
    private static func isLetter(_ ch: UInt8) -> Bool {
        return (ch >= UInt8(ascii: "a") && ch <= UInt8(ascii: "z")) ||
            (ch >= UInt8(ascii: "A") && ch <= UInt8(ascii: "Z"))
    }

    /// Check if character is a digit (0-9)
    private static func isDigit(_ ch: UInt8) -> Bool {
        return ch >= UInt8(ascii: "0") && ch <= UInt8(ascii: "9")
    }

    /// Encode Unicode code points using Punycode
    private static func encodePunycode(_ inputCodePoints: [UInt32]) -> String? {
        var output = ""

        var n = UInt32(initialN)
        var delta = 0
        var bias: Int = initialBias

        // Copy basic code points (< 0x80) to output
        // Using size_t equivalent (Int) for h and b to match C++
        var h = 0
        for c in inputCodePoints {
            if c < 0x80 {
                h += 1
                output.append(Character(UnicodeScalar(UInt8(c))))
            }
            if !isValidUnicodeScalar(c) {
                return nil
            }
        }
        let b: Int = h

        // Add delimiter if we have basic code points
        if b > 0 {
            output.append(delimiter)
        }

        // Main encoding loop
        while h < inputCodePoints.count {
            // Find minimum code point >= n
            var m: UInt32 = 0x10FFFF
            for codePoint in inputCodePoints {
                if codePoint >= n, codePoint < m {
                    m = codePoint
                }
            }

            // Check for overflow - matching C++ line 182
            // C++: if ((m - n) > (std::numeric_limits<int>::max() - delta) / (h + 1))
            let mMinusN = Int(m - n)
            let hPlusOne = h + 1
            if mMinusN > (Int.max - delta) / hPlusOne {
                return nil
            }
            delta = delta + mMinusN * hPlusOne
            n = m

            for c in inputCodePoints {
                if c < n {
                    if delta == Int.max {
                        return nil
                    }
                    delta += 1
                }

                if c == n {
                    var q: Int = delta
                    var k: Int = base
                    while true {
                        let t: Int = k <= bias ? tmin
                            : k >= bias + tmax ? tmax
                            : k - bias

                        if q < t { break }

                        output.append(digitValue(t + ((q - t) % (base - t))))
                        q = (q - t) / (base - t)
                        k += base
                    }

                    output.append(digitValue(q))
                    bias = adapt(delta, h + 1, h == b)
                    delta = 0
                    h += 1
                }
            }

            delta += 1
            n += 1
        }

        return output
    }

    /// Convert a digit to its character representation
    /// - Swift-specific: Uses 'a'-'z' for 0-25, 'A'-'J' for 26-35
    private static func digitValue(_ digit: Int) -> Character {
        assert(digit < base, "invalid punycode digit")
        if digit < 26 {
            return Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(digit)))
        }
        return Character(UnicodeScalar(UInt8(ascii: "A") - 26 + UInt8(digit)))
    }

    /// Bias adaptation function (from RFC 3492 Section 6.1)
    private static func adapt(_ delta: Int, _ numpoints: Int, _ firsttime: Bool) -> Int {
        var delta = delta
        if firsttime {
            delta = delta / damp
        } else {
            delta = delta / 2
        }

        delta += delta / numpoints
        var k = 0
        while delta > ((base - tmin) * tmax) / 2 {
            delta /= base - tmin
            k += base
        }
        return k + (((base - tmin + 1) * delta) / (delta + skew))
    }

    /// Check if a Unicode scalar value is valid
    private static func isValidUnicodeScalar(_ value: UInt32) -> Bool {
        // Accept the range 0xD800 - 0xD880 for non-symbol characters
        if value >= 0xD800 && value < 0xD880 {
            return true
        }
        // Standard Unicode scalar validation
        return value <= 0xD7FF || (value >= 0xE000 && value <= 0x10FFFF)
    }

    /// Rough adaptation of the pseudocode from 6.2 "Decoding procedure" in RFC3492
    static func decodePunycode(_ value: String) throws(DemanglingError) -> String {
        let input = value.unicodeScalars
        var output = [UnicodeScalar]()

        var pos = input.startIndex

        // Unlike RFC3492, Swift uses underscore for delimiting
        if let ipos = input.lastIndex(of: "_" as UnicodeScalar) {
            for basicScalar in input[input.startIndex ..< ipos] {
                // Upstream fails the decode on any non-basic code point here
                // (`decodePunycode`: `if (c > 0x7f) return false`). Copying
                // them through produced identifiers the toolchain rejects
                // outright.
                guard basicScalar.value <= 0x7F else {
                    throw DemanglingError.punycodeParseError
                }
                output.append(basicScalar)
            }
            pos = input.index(ipos, offsetBy: 1)
        }

        // Magic numbers from RFC3492
        var n = initialN
        var i = 0
        var bias = initialBias
        let symbolCount = base
        let alphaCount = tmax
        while pos != input.endIndex {
            let oldi = i
            var w = 1
            for k in stride(from: symbolCount, to: Int.max, by: symbolCount) {
                // The encoded number must not outrun the input. Only the
                // advance below was guarded, so a digit run that reaches the
                // end kept re-reading at `endIndex` and trapped instead of
                // rejecting the symbol.
                guard pos != input.endIndex else {
                    throw DemanglingError.punycodeParseError
                }
                // Unlike RFC3492, Swift uses letters A-J for values 26-35.
                //
                // Both ranges are closed. Upstream's `digit_index` returns -1
                // — which rejects the symbol — for every scalar outside `a`-`z`
                // and `A`-`J`; written as unbounded `>=` comparisons, `K`-`Z`
                // and `[ \ ] ^ _ \`` decoded as digits 36-57 through the
                // 26-based branch and `{ | } ~` upward through the 0-based one,
                // so the library accepted punycode the toolchain refuses and
                // fabricated identifier text for it.
                let digitScalar = input[pos]
                let digit: Int
                if digitScalar >= UnicodeScalar("a"), digitScalar <= UnicodeScalar("z") {
                    digit = Int(digitScalar.value - UnicodeScalar("a").value)
                } else if digitScalar >= UnicodeScalar("A"), digitScalar <= UnicodeScalar("J") {
                    digit = Int(digitScalar.value - UnicodeScalar("A").value) + alphaCount
                } else {
                    throw DemanglingError.punycodeParseError
                }

                pos = input.index(pos, offsetBy: 1)

                // Wrapping arithmetic let this accumulator go negative:
                // uppercase digits (values 26-51) never satisfy `digit < t`,
                // so `w` kept growing until it wrapped past Int64, and a
                // negative `i` survives the `% (output.count + 1)` below to
                // reach `output.insert(_:at:)` as a negative array index.
                // Upstream rejects the symbol when the accumulation
                // overflows; do that instead of wrapping.
                let (scaledDigit, digitScalingOverflowed) = digit.multipliedReportingOverflow(by: w)
                guard !digitScalingOverflowed else {
                    throw DemanglingError.punycodeParseError
                }
                let (accumulatedValue, accumulationOverflowed) = i.addingReportingOverflow(scaledDigit)
                guard !accumulationOverflowed else {
                    throw DemanglingError.punycodeParseError
                }
                i = accumulatedValue
                let t = max(min(k - bias, alphaCount), 1)
                if digit < t {
                    break
                }
                let (scaledWeight, weightScalingOverflowed) = w.multipliedReportingOverflow(by: symbolCount - t)
                guard !weightScalingOverflowed else {
                    throw DemanglingError.punycodeParseError
                }
                w = scaledWeight
            }

            // Bias adaptation function
            var delta = (i - oldi) / ((oldi == 0) ? 700 : 2)
            delta = delta + delta / (output.count + 1)
            var k = 0
            while delta > 455 {
                delta = delta / (symbolCount - 1)
                k = k + symbolCount
            }
            k += (symbolCount * delta) / (delta + symbolCount + 2)

            bias = k
            // `i` is bounded now but can still sit near `Int.max`, and `n`
            // only ever grows, so the last unguarded addition in this loop
            // gets the same treatment.
            let (advancedCodePoint, advanceOverflowed) = n.addingReportingOverflow(i / (output.count + 1))
            guard !advanceOverflowed else {
                throw DemanglingError.punycodeParseError
            }
            n = advancedCodePoint
            i = i % (output.count + 1)
            // Upstream validates every decoded code point and fails the whole
            // decode (`encodeToUTF8`: `if (!isValidUnicodeScalar(S)) return
            // false`). Substituting "." instead fabricated identifier text,
            // and "." is the structural separator in printed output too, so
            // the result was ambiguous as well as wrong — `main....()` cannot
            // be told apart from a real nested context. The predicate already
            // existed here; only the encode path ever called it.
            //
            // `UInt32(exactly:)` stands in for upstream's `uint32_t n`: the
            // accumulator is `Int` here, so a value past `UInt32.max` has to
            // be rejected rather than truncated.
            guard let codePoint = UInt32(exactly: n), isValidUnicodeScalar(codePoint) else {
                throw DemanglingError.punycodeParseError
            }
            var scalarValue = codePoint
            if scalarValue >= 0xD800, scalarValue < 0xD880 {
                scalarValue -= 0xD800
            }
            // Unreachable after the check above — every value it admits is a
            // representable scalar, and subtracting 0xD800 from the mapped
            // range lands in 0...0x7F. Kept as a throw rather than a force
            // unwrap so a future change to either range cannot turn it into a
            // process abort.
            guard let decodedScalar = UnicodeScalar(scalarValue) else {
                throw DemanglingError.punycodeParseError
            }
            output.insert(decodedScalar, at: i)
            i += 1
        }
        return String(output.map { Character($0) })
    }
}
