/// The kind of text a rich target is receiving, delivered through
/// ``NodePrintContext``.
///
/// `Sendable` is spelled out because the conformance is part of the contract,
/// not an implementation detail: implicit `Sendable` inference does not cross
/// the module boundary for `public` types, so downstream a
/// `NodePrinterTarget` — itself `Sendable` — could not store the state it is
/// handed. In-module tests cannot see this; there the inference applies.
public enum NodePrintState: Sendable {
    case printIdentifier
    case printFunctionParameters
    case printModule
    case printKeyword
    case printType
}
