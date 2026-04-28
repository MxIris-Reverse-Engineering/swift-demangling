/// Describe a function parameter, parameterized on the type representation.
public struct FunctionParam<BuiltType> {
    public private(set) var label: String?
    public private(set) var type: BuiltType?
    public private(set) var flags: ParameterFlags = []

    public init() {}

    public init(type: BuiltType) {
        self.type = type
    }

    private init(label: String?, type: BuiltType?, flags: ParameterFlags) {
        self.label = label
        self.type = type
        self.flags = flags
    }

    public func getLabel() -> String? { label }
    public func getType() -> BuiltType? { type }
    public func getFlags() -> ParameterFlags { flags }

    public mutating func setLabel(_ label: String?) { self.label = label }
    public mutating func setType(_ type: BuiltType) { self.type = type }
    public mutating func setVariadic() { flags = flags.withVariadic(true) }
    public mutating func setAutoClosure() { flags = flags.withAutoClosure(true) }
    public mutating func setOwnership(_ ownership: ParameterOwnership) {
        flags = flags.withOwnership(ownership)
    }

    public mutating func setNoDerivative() { flags = flags.withNoDerivative(true) }
    public mutating func setIsolated() { flags = flags.withIsolated(true) }
    public mutating func setSending() { flags = flags.withSending(true) }
    public mutating func setFlags(_ flags: ParameterFlags) { self.flags = flags }

    public func withLabel(_ label: String?) -> FunctionParam {
        return FunctionParam(label: label, type: type, flags: flags)
    }

    public func withType(_ type: BuiltType) -> FunctionParam {
        return FunctionParam(label: label, type: type, flags: flags)
    }

    public func withFlags(_ flags: ParameterFlags) -> FunctionParam {
        return FunctionParam(label: label, type: type, flags: flags)
    }
}

/// Parameter flags. Bit layout matches Swift ABI `TargetParameterTypeFlags`
/// (see `swift/ABI/MetadataValues.h`).
public struct ParameterFlags: OptionSet {
    public let rawValue: UInt32

    public init(rawValue: UInt32 = 0) {
        self.rawValue = rawValue
    }

    private static let ownershipMask: UInt32 = 0x7F
    private static let variadicMask: UInt32 = 0x80
    private static let autoClosureMask: UInt32 = 0x100
    private static let noDerivativeMask: UInt32 = 0x200
    private static let isolatedMask: UInt32 = 0x400
    private static let sendingMask: UInt32 = 0x800

    public var isVariadic: Bool { (rawValue & Self.variadicMask) != 0 }
    public var isAutoClosure: Bool { (rawValue & Self.autoClosureMask) != 0 }
    public var isNoDerivative: Bool { (rawValue & Self.noDerivativeMask) != 0 }
    public var isIsolated: Bool { (rawValue & Self.isolatedMask) != 0 }
    public var isSending: Bool { (rawValue & Self.sendingMask) != 0 }

    public var ownership: ParameterOwnership {
        return ParameterOwnership(rawValue: UInt8(rawValue & Self.ownershipMask)) ?? .default
    }

    public func withVariadic(_ value: Bool) -> ParameterFlags {
        if value {
            return ParameterFlags(rawValue: rawValue | Self.variadicMask)
        } else {
            return ParameterFlags(rawValue: rawValue & ~Self.variadicMask)
        }
    }

    public func withAutoClosure(_ value: Bool) -> ParameterFlags {
        if value {
            return ParameterFlags(rawValue: rawValue | Self.autoClosureMask)
        } else {
            return ParameterFlags(rawValue: rawValue & ~Self.autoClosureMask)
        }
    }

    public func withOwnership(_ ownership: ParameterOwnership) -> ParameterFlags {
        let cleared = rawValue & ~Self.ownershipMask
        return ParameterFlags(rawValue: cleared | UInt32(ownership.rawValue))
    }

    public func withNoDerivative(_ value: Bool) -> ParameterFlags {
        if value {
            return ParameterFlags(rawValue: rawValue | Self.noDerivativeMask)
        } else {
            return ParameterFlags(rawValue: rawValue & ~Self.noDerivativeMask)
        }
    }

    public func withIsolated(_ value: Bool) -> ParameterFlags {
        if value {
            return ParameterFlags(rawValue: rawValue | Self.isolatedMask)
        } else {
            return ParameterFlags(rawValue: rawValue & ~Self.isolatedMask)
        }
    }

    public func withSending(_ value: Bool) -> ParameterFlags {
        if value {
            return ParameterFlags(rawValue: rawValue | Self.sendingMask)
        } else {
            return ParameterFlags(rawValue: rawValue & ~Self.sendingMask)
        }
    }
}

/// Describe a lowered function parameter, parameterized on the type representation.
public struct ImplFunctionParam<BuiltType> {
    public let type: BuiltType
    public let convention: ImplParameterConvention
    public let options: ImplParameterInfoOptions

    public typealias ConventionType = ImplParameterConvention
    public typealias OptionsType = ImplParameterInfoOptions

    public init(type: BuiltType, convention: ImplParameterConvention, options: ImplParameterInfoOptions = []) {
        self.type = type
        self.convention = convention
        self.options = options
    }

    public func getConvention() -> ImplParameterConvention { convention }
    public func getOptions() -> ImplParameterInfoOptions { options }
    public func getType() -> BuiltType { type }

    public static func getConventionFromString(_ conventionString: String) -> ImplParameterConvention? {
        return ImplParameterConvention(string: conventionString)
    }

    public static func getDifferentiabilityFromString(_ string: String) -> ImplParameterInfoOptions? {
        if string.isEmpty {
            return ImplParameterInfoOptions()
        }
        if string == "@noDerivative" {
            return .notDifferentiable
        }
        return nil
    }

    public static func getSending() -> ImplParameterInfoOptions {
        return .sending
    }

    public static func getIsolated() -> ImplParameterInfoOptions {
        return .isolated
    }

    public static func getImplicitLeading() -> ImplParameterInfoOptions {
        return .implicitLeading
    }
}

public typealias ImplFunctionYield<Type> = ImplFunctionParam<Type>

/// Describe a lowered function result, parameterized on the type representation.
public struct ImplFunctionResult<BuiltType> {
    public let type: BuiltType
    public let convention: ImplResultConvention
    public let options: ImplResultInfoOptions

    public typealias ConventionType = ImplResultConvention
    public typealias OptionsType = ImplResultInfoOptions

    public init(type: BuiltType, convention: ImplResultConvention, options: ImplResultInfoOptions = []) {
        self.type = type
        self.convention = convention
        self.options = options
    }

    public func getConvention() -> ImplResultConvention { convention }
    public func getOptions() -> ImplResultInfoOptions { options }
    public func getType() -> BuiltType { type }

    public static func getConventionFromString(_ conventionString: String) -> ImplResultConvention? {
        return ImplResultConvention(string: conventionString)
    }

    public static func getDifferentiabilityFromString(_ string: String) -> ImplResultInfoOptions? {
        if string.isEmpty {
            return ImplResultInfoOptions()
        }
        if string == "@noDerivative" {
            return .notDifferentiable
        }
        return nil
    }

    public static func getSending() -> ImplResultInfoOptions {
        return .isSending
    }
}

/// Function type flags. Bit layout matches Swift ABI `TargetFunctionTypeFlags`
/// (see `swift/ABI/MetadataValues.h`).
public struct FunctionTypeFlags: OptionSet {
    public let rawValue: UInt32

    public init(rawValue: UInt32 = 0) {
        self.rawValue = rawValue
    }

    private static let numParametersMask: UInt32 = 0x0000_FFFF
    private static let conventionMask: UInt32 = 0x00FF_0000
    private static let conventionShift: UInt32 = 16
    private static let throwsMask: UInt32 = 0x0100_0000
    private static let parameterFlagsMask: UInt32 = 0x0200_0000
    private static let escapingMask: UInt32 = 0x0400_0000
    private static let differentiableMask: UInt32 = 0x0800_0000
    private static let globalActorMask: UInt32 = 0x1000_0000
    private static let asyncMask: UInt32 = 0x2000_0000
    private static let sendableMask: UInt32 = 0x4000_0000
    private static let extendedFlagsMask: UInt32 = 0x8000_0000

    public var convention: FunctionMetadataConvention {
        let raw = (rawValue & Self.conventionMask) >> Self.conventionShift
        switch raw {
        case 1: return .block
        case 2: return .thin
        case 3: return .cFunctionPointer
        default: return .swift
        }
    }

    public var isSendable: Bool { (rawValue & Self.sendableMask) != 0 }
    public var isAsync: Bool { (rawValue & Self.asyncMask) != 0 }
    public var `throws`: Bool { (rawValue & Self.throwsMask) != 0 }
    public var isDifferentiable: Bool { (rawValue & Self.differentiableMask) != 0 }
    public var isEscaping: Bool { (rawValue & Self.escapingMask) != 0 }
    public var hasParameterFlags: Bool { (rawValue & Self.parameterFlagsMask) != 0 }
    public var hasGlobalActor: Bool { (rawValue & Self.globalActorMask) != 0 }
    public var hasExtendedFlags: Bool { (rawValue & Self.extendedFlagsMask) != 0 }

    public var numParameters: Int {
        return Int(rawValue & Self.numParametersMask)
    }

    public func withConvention(_ convention: FunctionMetadataConvention) -> FunctionTypeFlags {
        let cleared = rawValue & ~Self.conventionMask
        let conventionRaw: UInt32
        switch convention {
        case .swift: conventionRaw = 0
        case .block: conventionRaw = 1
        case .thin: conventionRaw = 2
        case .cFunctionPointer: conventionRaw = 3
        }
        return FunctionTypeFlags(rawValue: cleared | (conventionRaw << Self.conventionShift))
    }

    public func withSendable(_ value: Bool) -> FunctionTypeFlags {
        if value {
            return FunctionTypeFlags(rawValue: rawValue | Self.sendableMask)
        } else {
            return FunctionTypeFlags(rawValue: rawValue & ~Self.sendableMask)
        }
    }

    public func withAsync(_ value: Bool) -> FunctionTypeFlags {
        if value {
            return FunctionTypeFlags(rawValue: rawValue | Self.asyncMask)
        } else {
            return FunctionTypeFlags(rawValue: rawValue & ~Self.asyncMask)
        }
    }

    public func withThrows(_ value: Bool) -> FunctionTypeFlags {
        if value {
            return FunctionTypeFlags(rawValue: rawValue | Self.throwsMask)
        } else {
            return FunctionTypeFlags(rawValue: rawValue & ~Self.throwsMask)
        }
    }

    public func withDifferentiable(_ value: Bool) -> FunctionTypeFlags {
        if value {
            return FunctionTypeFlags(rawValue: rawValue | Self.differentiableMask)
        } else {
            return FunctionTypeFlags(rawValue: rawValue & ~Self.differentiableMask)
        }
    }

    public func withEscaping(_ value: Bool) -> FunctionTypeFlags {
        if value {
            return FunctionTypeFlags(rawValue: rawValue | Self.escapingMask)
        } else {
            return FunctionTypeFlags(rawValue: rawValue & ~Self.escapingMask)
        }
    }

    public func withParameterFlags(_ value: Bool) -> FunctionTypeFlags {
        if value {
            return FunctionTypeFlags(rawValue: rawValue | Self.parameterFlagsMask)
        } else {
            return FunctionTypeFlags(rawValue: rawValue & ~Self.parameterFlagsMask)
        }
    }

    public func withGlobalActor(_ value: Bool) -> FunctionTypeFlags {
        if value {
            return FunctionTypeFlags(rawValue: rawValue | Self.globalActorMask)
        } else {
            return FunctionTypeFlags(rawValue: rawValue & ~Self.globalActorMask)
        }
    }

    public func withExtendedFlags(_ value: Bool) -> FunctionTypeFlags {
        if value {
            return FunctionTypeFlags(rawValue: rawValue | Self.extendedFlagsMask)
        } else {
            return FunctionTypeFlags(rawValue: rawValue & ~Self.extendedFlagsMask)
        }
    }

    public func withNumParameters(_ count: Int) -> FunctionTypeFlags {
        let cleared = rawValue & ~Self.numParametersMask
        let countBits = UInt32(count) & Self.numParametersMask
        return FunctionTypeFlags(rawValue: cleared | countBits)
    }
}

/// Implementation function type flags
public struct ImplFunctionTypeFlags {
    private var rep: UInt8 = 0
    private var pseudogeneric: Bool = false
    private var escaping: Bool = false
    private var concurrent: Bool = false
    private var async: Bool = false
    private var erasedIsolation: Bool = false
    private var differentiabilityKind: UInt8 = 0
    private var sendingResult: Bool = false

    public init() {}

    public init(
        rep: ImplFunctionRepresentation,
        pseudogeneric: Bool,
        noescape: Bool,
        concurrent: Bool,
        async: Bool,
        erasedIsolation: Bool,
        diffKind: ImplFunctionDifferentiabilityKind,
        hasSendingResult: Bool
    ) {
        self.rep = repToUInt8(rep)
        self.pseudogeneric = pseudogeneric
        self.escaping = noescape
        self.concurrent = concurrent
        self.async = async
        self.erasedIsolation = erasedIsolation
        self.differentiabilityKind = diffKindToUInt8(diffKind)
        self.sendingResult = hasSendingResult
    }

    private func repToUInt8(_ rep: ImplFunctionRepresentation) -> UInt8 {
        switch rep {
        case .thick: return 0
        case .block: return 1
        case .thin: return 2
        case .cFunctionPointer: return 3
        case .method: return 4
        case .objCMethod: return 5
        case .witnessMethod: return 6
        case .closure: return 7
        }
    }

    private func uint8ToRep(_ value: UInt8) -> ImplFunctionRepresentation {
        switch value {
        case 1: return .block
        case 2: return .thin
        case 3: return .cFunctionPointer
        case 4: return .method
        case 5: return .objCMethod
        case 6: return .witnessMethod
        case 7: return .closure
        default: return .thick
        }
    }

    private func diffKindToUInt8(_ kind: ImplFunctionDifferentiabilityKind) -> UInt8 {
        switch kind {
        case .nonDifferentiable: return 0
        case .forward: return 1
        case .reverse: return 2
        case .normal: return 3
        case .linear: return 4
        }
    }

    private func uint8ToDiffKind(_ value: UInt8) -> ImplFunctionDifferentiabilityKind {
        switch value {
        case 1: return .forward
        case 2: return .reverse
        case 3: return .normal
        case 4: return .linear
        default: return .nonDifferentiable
        }
    }

    public func getRepresentation() -> ImplFunctionRepresentation {
        return uint8ToRep(rep)
    }

    public func getDifferentiabilityKind() -> ImplFunctionDifferentiabilityKind {
        return uint8ToDiffKind(differentiabilityKind)
    }

    public func isAsync() -> Bool { async }
    public func isEscaping() -> Bool { escaping }
    public func isSendable() -> Bool { concurrent }
    public func isPseudogeneric() -> Bool { pseudogeneric }
    public func hasErasedIsolation() -> Bool { erasedIsolation }
    public func hasSendingResult() -> Bool { sendingResult }
    public func isDifferentiable() -> Bool {
        return getDifferentiabilityKind() != .nonDifferentiable
    }

    public func withRepresentation(_ newRep: ImplFunctionRepresentation) -> ImplFunctionTypeFlags {
        var copy = self
        copy.rep = repToUInt8(newRep)
        return copy
    }

    public func withSendable() -> ImplFunctionTypeFlags {
        var copy = self
        copy.concurrent = true
        return copy
    }

    public func withAsync() -> ImplFunctionTypeFlags {
        var copy = self
        copy.async = true
        return copy
    }

    public func withEscaping() -> ImplFunctionTypeFlags {
        var copy = self
        copy.escaping = true
        return copy
    }

    public func withErasedIsolation() -> ImplFunctionTypeFlags {
        var copy = self
        copy.erasedIsolation = true
        return copy
    }

    public func withPseudogeneric() -> ImplFunctionTypeFlags {
        var copy = self
        copy.pseudogeneric = true
        return copy
    }

    public func withDifferentiabilityKind(_ kind: ImplFunctionDifferentiabilityKind) -> ImplFunctionTypeFlags {
        var copy = self
        copy.differentiabilityKind = diffKindToUInt8(kind)
        return copy
    }

    public func withSendingResult() -> ImplFunctionTypeFlags {
        var copy = self
        copy.sendingResult = true
        return copy
    }
}

// Type decoder specific enums

public enum ImplMetatypeRepresentation: Sendable {
    case thin
    case thick
    case objC
}

public enum ImplCoroutineKind: Sendable {
    case none
    case yieldOnce
    case yieldOnce2
    case yieldMany
}

public enum ImplParameterConvention: String, Sendable {
    case indirectIn = "@in"
    case indirectInConstant = "@in_constant"
    case indirectInGuaranteed = "@in_guaranteed"
    case indirectInout = "@inout"
    case indirectInoutAliasable = "@inout_aliasable"
    case directOwned = "@owned"
    case directUnowned = "@unowned"
    case directGuaranteed = "@guaranteed"
    case packOwned = "@pack_owned"
    case packGuaranteed = "@pack_guaranteed"
    case packInout = "@pack_inout"

    public init?(string: String) {
        self.init(rawValue: string)
    }
}

public enum ImplParameterInfoFlags: UInt8, CaseIterable, Sendable {
    case notDifferentiable = 0x1
    case sending = 0x2
    case isolated = 0x4
    case implicitLeading = 0x8
}

public struct ImplParameterInfoOptions: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let notDifferentiable = ImplParameterInfoOptions(rawValue: ImplParameterInfoFlags.notDifferentiable.rawValue)
    public static let sending = ImplParameterInfoOptions(rawValue: ImplParameterInfoFlags.sending.rawValue)
    public static let isolated = ImplParameterInfoOptions(rawValue: ImplParameterInfoFlags.isolated.rawValue)
    public static let implicitLeading = ImplParameterInfoOptions(rawValue: ImplParameterInfoFlags.implicitLeading.rawValue)
}

public enum ImplResultInfoFlags: UInt8, CaseIterable, Sendable {
    case notDifferentiable = 0x1
    case isSending = 0x2
}

public struct ImplResultInfoOptions: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let notDifferentiable = ImplResultInfoOptions(rawValue: ImplResultInfoFlags.notDifferentiable.rawValue)
    public static let isSending = ImplResultInfoOptions(rawValue: ImplResultInfoFlags.isSending.rawValue)
}

public enum ImplResultConvention: String, Sendable {
    case indirect = "@out"
    case owned = "@owned"
    case unowned = "@unowned"
    case unownedInnerPointer = "@unowned_inner_pointer"
    case autoreleased = "@autoreleased"
    case pack = "@pack_out"

    public init?(string: String) {
        self.init(rawValue: string)
    }
}

public enum ImplResultDifferentiability: Sendable {
    case differentiableOrNotApplicable
    case notDifferentiable
}

public enum ImplFunctionRepresentation: Sendable {
    case thick
    case block
    case thin
    case cFunctionPointer
    case method
    case objCMethod
    case witnessMethod
    case closure
}

public enum ImplFunctionDifferentiabilityKind: Sendable {
    case nonDifferentiable
    case forward
    case reverse
    case normal
    case linear
}

/// Parameter ownership modes. Raw values match Swift ABI `ParameterOwnership`
/// (see `swift/ABI/MetadataValues.h`).
public enum ParameterOwnership: UInt8, Sendable {
    case `default` = 0
    case `inout` = 1
    case shared = 2
    case owned = 3
}

/// Function metadata convention
public enum FunctionMetadataConvention: Sendable {
    case swift
    case block
    case thin
    case cFunctionPointer
}

/// Function metadata differentiability
public enum FunctionMetadataDifferentiabilityKind: Sendable {
    case nonDifferentiable
    case forward
    case reverse
    case normal
    case linear

    public var isDifferentiable: Bool {
        return self != .nonDifferentiable
    }
}

/// Extended function type flags. Bit layout matches Swift ABI
/// `TargetExtendedFunctionTypeFlags` (see `swift/ABI/MetadataValues.h`).
///
/// Note: `IsolationMask` (bits 1-3) is an enumerated 3-bit field, not a set of
/// independent bits. `IsolatedAny` and `NonIsolatedCaller` are mutually exclusive
/// values within that field; the `with*` methods clear the field before setting.
public struct ExtendedFunctionTypeFlags: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    private static let typedThrowsMask: UInt32 = 0x0000_0001
    private static let isolationMask: UInt32 = 0x0000_000E
    private static let isolatedAnyValue: UInt32 = 0x0000_0002
    private static let nonIsolatedCallerValue: UInt32 = 0x0000_0004
    private static let hasSendingResultMask: UInt32 = 0x0000_0010
    private static let invertedProtocolShift: UInt32 = 16
    private static let invertedProtocolMask: UInt32 = 0xFFFF_0000

    public var isTypedThrows: Bool { (rawValue & Self.typedThrowsMask) != 0 }
    public var isIsolatedAny: Bool { (rawValue & Self.isolationMask) == Self.isolatedAnyValue }
    public var isNonIsolatedCaller: Bool { (rawValue & Self.isolationMask) == Self.nonIsolatedCallerValue }
    public var hasSendingResult: Bool { (rawValue & Self.hasSendingResultMask) != 0 }

    public func withIsolatedAny() -> ExtendedFunctionTypeFlags {
        return ExtendedFunctionTypeFlags(rawValue: (rawValue & ~Self.isolationMask) | Self.isolatedAnyValue)
    }

    public func withNonIsolatedCaller() -> ExtendedFunctionTypeFlags {
        return ExtendedFunctionTypeFlags(rawValue: (rawValue & ~Self.isolationMask) | Self.nonIsolatedCallerValue)
    }

    public func withNonIsolated() -> ExtendedFunctionTypeFlags {
        return ExtendedFunctionTypeFlags(rawValue: rawValue & ~Self.isolationMask)
    }

    public func withSendingResult(_ value: Bool = true) -> ExtendedFunctionTypeFlags {
        if value {
            return ExtendedFunctionTypeFlags(rawValue: rawValue | Self.hasSendingResultMask)
        } else {
            return ExtendedFunctionTypeFlags(rawValue: rawValue & ~Self.hasSendingResultMask)
        }
    }

    public func withTypedThrows(_ value: Bool) -> ExtendedFunctionTypeFlags {
        if value {
            return ExtendedFunctionTypeFlags(rawValue: rawValue | Self.typedThrowsMask)
        } else {
            return ExtendedFunctionTypeFlags(rawValue: rawValue & ~Self.typedThrowsMask)
        }
    }

    public var invertedProtocols: UInt16 {
        return UInt16((rawValue & Self.invertedProtocolMask) >> Self.invertedProtocolShift)
    }

    public func withInvertedProtocols(_ inverted: UInt16) -> ExtendedFunctionTypeFlags {
        let cleared = rawValue & ~Self.invertedProtocolMask
        let bits = (UInt32(inverted) << Self.invertedProtocolShift) & Self.invertedProtocolMask
        return ExtendedFunctionTypeFlags(rawValue: cleared | bits)
    }
}

/// Layout constraint kinds
public enum LayoutConstraintKind: Sendable {
    case unknownLayout
    case refCountedObject
    case nativeRefCountedObject
    case `class`
    case nativeClass
    case trivial
    case bridgeObject
    case trivialOfExactSize
    case trivialOfAtMostSize
    case trivialStride
}

extension LayoutConstraintKind {
    init?(from text: String) {
        switch text {
        case "U": self = .unknownLayout
        case "R": self = .refCountedObject
        case "N": self = .nativeRefCountedObject
        case "C": self = .class
        case "D": self = .nativeClass
        case "T": self = .trivial
        case "B": self = .bridgeObject
        case "E",
             "e": self = .trivialOfExactSize
        case "M",
             "m": self = .trivialOfAtMostSize
        case "S": self = .trivialStride
        default: return nil
        }
    }

    var needsSizeAlignment: Bool {
        switch self {
        case .trivialOfExactSize,
             .trivialOfAtMostSize,
             .trivialStride:
            return true
        default:
            return false
        }
    }
}

/// Requirement kinds
public enum RequirementKind: Sendable {
    case conformance
    case superclass
    case sameType
    case layout
}

/// Invertible protocol kinds
public enum InvertibleProtocolKind: UInt32, Sendable {
    case copyable = 0
    case escapable = 1
}

extension FunctionMetadataDifferentiabilityKind {
    init(from rawValue: UInt8) {
        switch rawValue {
        case 1:
            self = .forward
        case 2:
            self = .reverse
        case 3:
            self = .normal
        case 4:
            self = .linear
        default:
            self = .nonDifferentiable
        }
    }
}

extension ImplFunctionDifferentiabilityKind {
    init(from rawValue: UInt8) {
        switch rawValue {
        case 0:
            self = .nonDifferentiable
        case 1:
            self = .forward
        case 2:
            self = .reverse
        case 3:
            self = .normal
        case 4:
            self = .linear
        default:
            self = .nonDifferentiable
        }
    }
}

protocol ImplFunctionParamProtocol {
    associatedtype BuiltTypeParam
    associatedtype ConventionType
    associatedtype OptionsType: OptionSet

    init(type: BuiltTypeParam, convention: ConventionType, options: OptionsType)

    static func getConventionFromString(_ string: String) -> ConventionType?
    static func getDifferentiabilityFromString(_ string: String) -> OptionsType?
    static func getSending() -> OptionsType
    static func getIsolated() -> OptionsType
    static func getImplicitLeading() -> OptionsType
}

protocol ImplFunctionResultProtocol {
    associatedtype BuiltTypeParam
    associatedtype ConventionType
    associatedtype OptionsType: OptionSet

    init(type: BuiltTypeParam, convention: ConventionType, options: OptionsType)

    static func getConventionFromString(_ string: String) -> ConventionType?
    static func getDifferentiabilityFromString(_ string: String) -> OptionsType?
    static func getSending() -> OptionsType
}

extension ImplFunctionParam: ImplFunctionParamProtocol {
    typealias BuiltTypeParam = BuiltType
}

extension ImplFunctionResult: ImplFunctionResultProtocol {
    typealias BuiltTypeParam = BuiltType
}

extension ImplMetatypeRepresentation {
    init?(from text: String) {
        switch text {
        case "@thin":
            self = .thin
        case "@thick":
            self = .thick
        case "@objc_metatype":
            self = .objC
        default:
            return nil
        }
    }
}
