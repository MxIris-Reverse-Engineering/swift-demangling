import Testing
@testable import Demangling

/// Tests for `TypeDecoder`, ported from the Swift compiler's `test/TypeDecoder/`
/// directory. The Swift tests compile real source and use `lldb-moduleimport-test`
/// with the AST type printer; here we drive `TypeDecoder` with a `StringTypeBuilder`
/// that produces type strings directly. The output format mirrors the Swift AST
/// printer for the cases covered (builtins, sugar, lowered metatypes, reference
/// storage, simple functions). Module prefixes on nominal types are stripped to
/// match the Swift expected output.
@Suite("TypeDecoder")
struct TypeDecoderTests {
    // MARK: - Helpers

    private static func decodeType(_ mangled: String) throws -> String {
        let node = try demangleAsNode(mangled)
        let decoder = TypeDecoder(builder: StringTypeBuilder())
        return try decoder.decodeMangledType(node: node)
    }

    // MARK: - Builtin Types
    //
    // Source: swift/test/TypeDecoder/builtins.swift

    @Test(arguments: [
        ("$sBbD", "BridgeObject"),
        ("$sBoD", "NativeObject"),
        ("$sBpD", "RawPointer"),
        ("$sBwD", "Word"),
        ("$sBID", "IntLiteral"),
        ("$sBf32_D", "FPIEEE32"),
        ("$sBf64_D", "FPIEEE64"),
        ("$sBf80_D", "FPIEEE80"),
        ("$sBi1_D", "Int1"),
        ("$sBi8_D", "Int8"),
        ("$sBi16_D", "Int16"),
        ("$sBi32_D", "Int32"),
        ("$sBi64_D", "Int64"),
        ("$sBi128_D", "Int128"),
    ])
    func builtinTypes(mangled: String, expected: String) throws {
        #expect(try Self.decodeType(mangled) == expected)
    }

    @Test(arguments: [
        ("$sBf32_Bv2_D", "Vec2xFPIEEE32"),
        ("$sBf32_Bv4_D", "Vec4xFPIEEE32"),
        ("$sBf32_Bv8_D", "Vec8xFPIEEE32"),
        ("$sBf32_Bv16_D", "Vec16xFPIEEE32"),
        ("$sBf32_Bv32_D", "Vec32xFPIEEE32"),
        ("$sBf32_Bv64_D", "Vec64xFPIEEE32"),
        ("$sBi32_Bv2_D", "Vec2xInt32"),
        ("$sBi64_Bv4_D", "Vec4xInt64"),
        ("$sBi8_Bv16_D", "Vec16xInt8"),
    ])
    func builtinVectorTypes(mangled: String, expected: String) throws {
        #expect(try Self.decodeType(mangled) == expected)
    }

    // MARK: - Sugar Types
    //
    // Source: swift/test/TypeDecoder/sugar.swift

    @Test func sugarTuple() throws {
        // (Int?, [Float], [Double : String], Bool)
        let result = try Self.decodeType("$sSiXSq_SfXSaSdSSXSDSbXSptD")
        #expect(result == "(Int?, [Float], [Double : String], Bool)")
    }

    // MARK: - Reference Storage
    //
    // Source: swift/test/TypeDecoder/reference_storage.swift

    @Test(arguments: [
        ("$s17reference_storage5ClassCSgXwD", "@sil_weak Optional<Class>"),
        ("$s17reference_storage5ClassCXoD", "@sil_unowned Class"),
        ("$s17reference_storage5ClassCXuD", "@sil_unmanaged Class"),
    ])
    func referenceStorage(mangled: String, expected: String) throws {
        #expect(try Self.decodeType(mangled) == expected)
    }

    // MARK: - Lowered Metatypes
    //
    // Source: swift/test/TypeDecoder/lowered_metatypes.swift

    @Test(arguments: [
        ("$s17lowered_metatypes6StructVXMt", "@thin Struct.Type"),
        ("$s17lowered_metatypes6StructVXMT", "@thick Struct.Type"),
        ("$s17lowered_metatypes5ClassCXMo", "@objc_metatype Class.Type"),
    ])
    func loweredMetatypes(mangled: String, expected: String) throws {
        #expect(try Self.decodeType(mangled) == expected)
    }

    // MARK: - Dynamic Self
    //
    // Source: swift/test/TypeDecoder/dynamic_self.swift

    @Test func dynamicSelfMetatype() throws {
        // @thick Self.Type
        let result = try Self.decodeType("$s12dynamic_self2MeCXDXMTD")
        #expect(result == "@thick Self.Type")
    }

    // MARK: - Structural Types: Functions and Tuples
    //
    // Source: swift/test/TypeDecoder/structural_types.swift

    @Test(arguments: [
        ("$syycD", "() -> ()"),
        ("$sySSzcD", "(inout String) -> ()"),
        ("$sySSncD", "(__owned String) -> ()"),
        ("$sySi_SftcD", "(Int, Float) -> ()"),
        ("$sySiz_SftcD", "(inout Int, Float) -> ()"),
        ("$sySiz_SfztcD", "(inout Int, inout Float) -> ()"),
        ("$sySi_SfztcD", "(Int, inout Float) -> ()"),
        ("$sySi_SSzSftcD", "(Int, inout String, Float) -> ()"),
        ("$sySiz_SSSfzSdtcD", "(inout Int, String, inout Float, Double) -> ()"),
        ("$sySS_SiSdSftcD", "(String, Int, Double, Float) -> ()"),
        ("$sySi_Sft_tcD", "((Int, Float)) -> ()"),
        ("$sySid_tcD", "(Int...) -> ()"),
    ])
    func functionTypes(mangled: String, expected: String) throws {
        #expect(try Self.decodeType(mangled) == expected)
    }

    @Test(arguments: [
        ("$sSi_SfSitD", "(Int, Float, Int)"),
        ("$sSim_Sf1xSitD", "(Int.Type, x: Float, Int)"),
        ("$sSi1x_SfSim1ytD", "(x: Int, Float, y: Int.Type)"),
    ])
    func tupleTypes(mangled: String, expected: String) throws {
        #expect(try Self.decodeType(mangled) == expected)
    }

    @Test(arguments: [
        ("$syyyccD", "(@escaping () -> ()) -> ()"),
        ("$sSayyyXCGD", "Array<@convention(c) () -> ()>"),
    ])
    func functionTypesWithConventions(mangled: String, expected: String) throws {
        #expect(try Self.decodeType(mangled) == expected)
    }

    // Metatype-of-function and metatype-of-tuple from structural_types.swift.

    @Test(arguments: [
        ("$sSimD", "Int.Type"),
        ("$syycmD", "(() -> ()).Type"),
        ("$sySSzcmD", "((inout String) -> ()).Type"),
        ("$sySSncmD", "((__owned String) -> ()).Type"),
        ("$sySi_SftcmD", "((Int, Float) -> ()).Type"),
        ("$sySiz_SftcmD", "((inout Int, Float) -> ()).Type"),
        ("$sySi_Sft_tcmD", "(((Int, Float)) -> ()).Type"),
        ("$sySid_tcmD", "((Int...) -> ()).Type"),
        ("$sSi_SfSitmD", "(Int, Float, Int).Type"),
        ("$sSim_Sf1xSitmD", "(Int.Type, x: Float, Int).Type"),
        ("$sSi1x_SfSim1ytmD", "(x: Int, Float, y: Int.Type).Type"),
        ("$syyyccmD", "((@escaping () -> ()) -> ()).Type"),
        ("$sSayyyXCGmD", "Array<@convention(c) () -> ()>.Type"),
    ])
    func metatypeOfStructuralTypes(mangled: String, expected: String) throws {
        #expect(try Self.decodeType(mangled) == expected)
    }

    // MARK: - Concurrency
    //
    // Source: swift/test/TypeDecoder/concurrency.swift

    @Test(arguments: [
        ("$sSayySiYacG", "Array<(Int) async -> ()>"),
        ("$sSayySiYaKcG", "Array<(Int) async throws -> ()>"),
    ])
    func concurrencyTypes(mangled: String, expected: String) throws {
        #expect(try Self.decodeType(mangled) == expected)
    }

    /// Implementation function types (lowered SIL form). The string builder
    /// uses a simplified format `[@async] @callee_<conv> (params) -> (results)`.
    @Test func implFunctionType_async() throws {
        // Source: concurrency.swift  $sIegH_D  →  @async @callee_guaranteed () -> ()
        let result = try Self.decodeType("$sIegH_D")
        #expect(result == "@async @callee_guaranteed () -> ()")
    }

    // MARK: - Existential Metatypes (Protocols)
    //
    // Source: swift/test/TypeDecoder/lowered_metatypes.swift

    @Test(arguments: [
        ("$s17lowered_metatypes5ProtoPXmT", "@thick any Proto.Type"),
        ("$s17lowered_metatypes5ProtoPXmo", "@objc_metatype any Proto.Type"),
    ])
    func existentialMetatypes(mangled: String, expected: String) throws {
        #expect(try Self.decodeType(mangled) == expected)
    }
}

// MARK: - StringTypeBuilder

/// A `TypeBuilder` that produces a string representation of a type. Output
/// format approximates the Swift AST type printer: nominal types use just the
/// type name (module stripped), generics use `<>`, sugar types use `?`/`[]`,
/// metatypes use `T.Type` with optional `@repr` prefix.
private struct StringTypeBuilder: TypeBuilder {
    typealias BuiltType = String
    typealias BuiltTypeDecl = String
    typealias BuiltProtocolDecl = String
    typealias BuiltSILBoxField = String
    typealias BuiltSubstitution = String
    typealias BuiltRequirement = String
    typealias BuiltInverseRequirement = String
    typealias BuiltLayoutConstraint = String
    typealias BuiltGenericSignature = String
    typealias BuiltSubstitutionMap = String

    func getManglingFlavor() -> ManglingFlavor { .default }

    func decodeMangledType(node: Node?, forRequirement: Bool) throws(TypeLookupError) -> String {
        guard let node else { throw TypeLookupError("nil node") }
        let decoder = TypeDecoder(builder: self)
        return try decoder.decodeMangledType(node: node, forRequirement: forRequirement)
    }

    // MARK: Type Decls

    func createTypeDecl(node: Node, typeAlias: inout Bool) -> String? {
        typeAlias = node.kind == .typeAlias || node.kind == .boundGenericTypeAlias
        return Self.extractName(from: node)
    }

    func createProtocolDecl(node: Node) -> String? {
        return Self.extractName(from: node)
    }

    /// Extract the trailing identifier of a nominal/protocol node, ignoring the
    /// module prefix. E.g. `Structure(Module(Swift), Identifier(Int))` → "Int".
    private static func extractName(from node: Node) -> String? {
        for child in node.children.reversed() {
            switch child.kind {
            case .identifier, .privateDeclName:
                if let text = child.text { return text }
            default:
                continue
            }
        }
        return node.text
    }

    // MARK: Nominals

    func createNominalType(typeDecl: String, parent: String?) -> String {
        if let parent { return "\(parent).\(typeDecl)" }
        return typeDecl
    }

    func createBoundGenericType(typeDecl: String, args: [String], parent: String?) -> String {
        let head = parent.map { "\($0).\(typeDecl)" } ?? typeDecl
        return "\(head)<\(args.joined(separator: ", "))>"
    }

    func createTypeAliasType(typeDecl: String, parent: String?) -> String {
        return createNominalType(typeDecl: typeDecl, parent: parent)
    }

    // MARK: Builtins

    func createBuiltinType(name: String, mangledName: String) -> String {
        if let dot = name.firstIndex(of: ".") {
            return String(name[name.index(after: dot)...])
        }
        return name
    }

    func createBuiltinFixedArrayType(size: String, element: String) -> String {
        return "Builtin.FixedArray<\(size), \(element)>"
    }

    // MARK: Metatypes

    func createMetatypeType(instance: String, repr: ImplMetatypeRepresentation?) -> String {
        let prefix = Self.metatypePrefix(repr)
        let wrapped = Self.parenthesizeForMetatype(instance)
        return "\(prefix)\(wrapped).Type"
    }

    func createExistentialMetatypeType(instance: String, repr: ImplMetatypeRepresentation?) -> String {
        let prefix = Self.metatypePrefix(repr)
        let stripped = instance.hasPrefix("any ") ? String(instance.dropFirst(4)) : instance
        // Existentials like `any P` need `any P.Type`, but constrained `any P<...>`
        // gets `(any P<...>).Type`.
        if stripped.contains("<") || stripped.contains(" & ") {
            return "\(prefix)(any \(stripped)).Type"
        }
        return "\(prefix)any \(stripped).Type"
    }

    /// Add parens around a function type so it can be used before `.Type`,
    /// `?`, `!`, `[]` etc. Function types are recognized by starting with `(`
    /// (the parameter list) AND containing ` -> ` at the top level (not nested
    /// inside angle-bracket generic arguments).
    private static func parenthesizeForMetatype(_ text: String) -> String {
        guard text.hasPrefix("(") else { return text }
        // Walk paired parens; if we find ` -> ` at depth 0 after the matching
        // close paren, this is a function type that needs wrapping.
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "(" { depth += 1 }
            if char == ")" { depth -= 1 }
            if depth == 0 {
                let next = text.index(after: index)
                if next < text.endIndex, text[next...].hasPrefix(" -> ") {
                    return "(\(text))"
                }
            }
            index = text.index(after: index)
        }
        return text
    }

    private static func metatypePrefix(_ repr: ImplMetatypeRepresentation?) -> String {
        switch repr {
        case .thin: return "@thin "
        case .thick: return "@thick "
        case .objC: return "@objc_metatype "
        case .none: return ""
        }
    }

    // MARK: Existentials & Protocols

    func createProtocolCompositionType(protocols: [String], superclass: String?, isClassBound: Bool, forRequirement: Bool) -> String {
        var parts: [String] = []
        if let superclass { parts.append(superclass) }
        parts.append(contentsOf: protocols)
        if isClassBound && superclass == nil {
            parts.append("AnyObject")
        }
        if parts.isEmpty { return "Any" }
        if parts.count == 1, !forRequirement { return "any \(parts[0])" }
        if forRequirement { return parts.joined(separator: " & ") }
        return "any \(parts.joined(separator: " & "))"
    }

    func createProtocolCompositionType(protocol proto: String, superclass: String?, isClassBound: Bool, forRequirement: Bool) -> String {
        return createProtocolCompositionType(protocols: [proto], superclass: superclass, isClassBound: isClassBound, forRequirement: forRequirement)
    }

    func createConstrainedExistentialType(base: String, requirements: [String], inverseRequirements: [String]) -> String {
        let stripped = base.hasPrefix("any ") ? String(base.dropFirst(4)) : base
        return "any \(stripped)<\(requirements.joined(separator: ", "))>"
    }

    func createSymbolicExtendedExistentialType(shapeNode: Node, args: [String]) -> String {
        return "any <symbolic shape><\(args.joined(separator: ", "))>"
    }

    // MARK: Functions

    func createFunctionType(
        parameters: [FunctionParam<String>],
        result: String,
        flags: FunctionTypeFlags,
        extFlags: ExtendedFunctionTypeFlags,
        diffKind: FunctionMetadataDifferentiabilityKind,
        globalActorType: String?,
        thrownErrorType: String?
    ) -> String {
        var prefix = ""
        if flags.isSendable { prefix += "@Sendable " }
        if let globalActorType { prefix += "@\(globalActorType) " }
        if extFlags.isIsolatedAny { prefix += "@isolated(any) " }
        if extFlags.isNonIsolatedCaller { prefix += "nonisolated(nonsending) " }
        switch flags.convention {
        case .swift: break
        case .block: prefix += "@convention(block) "
        case .thin: prefix += "@convention(thin) "
        case .cFunctionPointer: prefix += "@convention(c) "
        }
        // @escaping is only meaningful when the function type is used as a parameter
        // of another function (where it distinguishes from @noescape). It is not
        // printed at the top level. `formatFunctionParams` adds it for swift-convention
        // function-typed parameters.

        let paramList = Self.formatFunctionParams(parameters)
        var middle = " -> "
        if extFlags.hasSendingResult { middle = " sending" + middle }
        // Effect-keyword order matches Swift source spelling: `async throws`.
        // Build by prepending throws first, then async, so async appears before throws.
        if flags.throws {
            if let thrownErrorType {
                middle = " throws(\(thrownErrorType))" + middle
            } else {
                middle = " throws" + middle
            }
        }
        if flags.isAsync { middle = " async" + middle }
        return "\(prefix)\(paramList)\(middle)\(result)"
    }

    private static func formatFunctionParams(_ params: [FunctionParam<String>]) -> String {
        let formatted = params.map { param -> String in
            var str = ""
            if let label = param.getLabel(), !label.isEmpty {
                str += "\(label): "
            }
            switch param.getFlags().ownership {
            case .default: break
            case .inout: str += "inout "
            case .shared: str += "__shared "
            case .owned: str += "__owned "
            }
            if param.getFlags().isIsolated { str += "isolated " }
            if param.getFlags().isSending { str += "sending " }
            let typeText = param.getType() ?? ""
            // Mimic Swift's printer: prepend `@escaping` for swift-convention
            // function-typed parameters (those starting with `(` and containing
            // `-> `, with no leading `@convention(...)` prefix).
            if Self.isSwiftFunctionType(typeText) {
                str += "@escaping "
            }
            str += typeText
            if param.getFlags().isVariadic { str += "..." }
            return str
        }
        return "(\(formatted.joined(separator: ", ")))"
    }

    private static func isSwiftFunctionType(_ text: String) -> Bool {
        guard text.hasPrefix("(") else { return false }
        // Reject if there's an attribute prefix on the function (e.g., the
        // string starts with "(" because the params list begins, but a leading
        // `@convention(...)` would mean it isn't a default-convention swift
        // function). Since we only add `@escaping` to default-convention swift
        // functions, accept only when there's an arrow with no preceding `@`.
        guard text.range(of: " -> ") != nil else { return false }
        return true
    }

    func createImplFunctionType(
        calleeConvention: ImplParameterConvention,
        coroutineKind: ImplCoroutineKind,
        parameters: [ImplFunctionParam<String>],
        yields: [ImplFunctionYield<String>],
        results: [ImplFunctionResult<String>],
        errorResult: ImplFunctionResult<String>?,
        flags: ImplFunctionTypeFlags
    ) -> String {
        var prefix = ""
        if flags.isAsync() { prefix += "@async " }
        if flags.isSendable() { prefix += "@Sendable " }

        switch calleeConvention {
        case .directGuaranteed: prefix += "@callee_guaranteed "
        case .directOwned: prefix += "@callee_owned "
        case .directUnowned: prefix += "@callee_unowned "
        default: break
        }

        let paramStrings = parameters.map { p in "\(p.getConvention().rawValue) \(p.getType())" }
        let resultStrings = results.map { r in "\(r.getConvention().rawValue) \(r.getType())" }
        let resultPart = resultStrings.isEmpty ? "()" : "(\(resultStrings.joined(separator: ", ")))"
        return "\(prefix)(\(paramStrings.joined(separator: ", "))) -> \(resultPart)"
    }

    // MARK: Tuples & Packs

    func createTupleType(elements: [String], labels: [String?]) -> String {
        let pairs = zip(elements, labels).map { element, label -> String in
            if let label, !label.isEmpty { return "\(label): \(element)" }
            return element
        }
        return "(\(pairs.joined(separator: ", ")))"
    }

    func createPackType(elements: [String]) -> String {
        return "Pack{\(elements.joined(separator: ", "))}"
    }

    func createSILPackType(elements: [String], isElementAddress: Bool) -> String {
        let prefix = isElementAddress ? "@sil_pack_indirect" : "@sil_pack_direct"
        return "\(prefix){\(elements.joined(separator: ", "))}"
    }

    func createExpandedPackElement(type: String) -> String {
        return type
    }

    // MARK: Generic Params

    func createGenericTypeParameterType(depth: Int, index: Int) -> String {
        return "τ_\(depth)_\(index)"
    }

    func createDependentMemberType(member: String, base: String) -> String {
        return "\(base).\(member)"
    }

    func createDependentMemberType(member: String, base: String, protocol proto: String) -> String {
        return "(\(base) as \(proto)).\(member)"
    }

    // MARK: Reference Storage

    func createUnownedStorageType(base: String) -> String { "@sil_unowned \(base)" }
    func createUnmanagedStorageType(base: String) -> String { "@sil_unmanaged \(base)" }
    func createWeakStorageType(base: String) -> String { "@sil_weak \(base)" }

    // MARK: SIL Box

    func createSILBoxType(base: String) -> String { "@box \(base)" }

    func createSILBoxField(type: String, isMutable: Bool) -> String {
        return isMutable ? "var \(type)" : "let \(type)"
    }

    func createSILBoxTypeWithLayout(
        fields: [String],
        substitutions: [String],
        requirements: [String],
        inverseRequirements: [String]
    ) -> String {
        return "@box{\(fields.joined(separator: ", "))}"
    }

    // MARK: Special Types

    func createDynamicSelfType(base: String) -> String { "Self" }

    func resolveOpaqueType(descriptor: Node, genericArgs: [ArraySlice<String>], ordinal: UInt64) -> String {
        return "some <opaque>"
    }

    // MARK: Sugar

    func createOptionalType(base: String) -> String { "\(base)?" }
    func createArrayType(element: String) -> String { "[\(element)]" }
    func createInlineArrayType(count: String, element: String) -> String { "[\(count) of \(element)]" }
    func createDictionaryType(key: String, value: String) -> String { "[\(key) : \(value)]" }

    // MARK: Integers

    func createIntegerType(value: Int) -> String { "\(value)" }
    func createNegativeIntegerType(value: Int) -> String { "-\(value)" }

    // MARK: Objective-C

    #if canImport(ObjectiveC)
    func createObjCClassType(name: String) -> String { name }
    func createObjCProtocolDecl(name: String) -> String { name }
    func createBoundGenericObjCClassType(name: String, args: [String]) -> String {
        "\(name)<\(args.joined(separator: ", "))>"
    }
    #endif

    // MARK: Requirements

    func createRequirement(kind: RequirementKind, subjectType: String, constraintType: String) -> String {
        switch kind {
        case .conformance: return "\(subjectType): \(constraintType)"
        case .superclass: return "\(subjectType): \(constraintType)"
        case .sameType: return "\(subjectType) == \(constraintType)"
        case .layout: return "\(subjectType): <layout>"
        }
    }

    func createRequirement(kind: RequirementKind, subjectType: String, layout: String) -> String {
        return "\(subjectType): \(layout)"
    }

    func createInverseRequirement(subjectType: String, kind: InvertibleProtocolKind) -> String {
        switch kind {
        case .copyable: return "\(subjectType): ~Copyable"
        case .escapable: return "\(subjectType): ~Escapable"
        }
    }

    func getLayoutConstraint(kind: LayoutConstraintKind) -> String { "\(kind)" }

    func getLayoutConstraintWithSizeAlign(kind: LayoutConstraintKind, size: Int, alignment: Int) -> String {
        return "\(kind)(\(size), \(alignment))"
    }

    func createSubstitution(firstType: String, secondType: String) -> String {
        return "\(firstType)=\(secondType)"
    }

    func isExistential(type: String) -> Bool {
        return type.hasPrefix("any ") || type == "Any"
    }

    // MARK: Pack Expansion

    func beginPackExpansion(countType: String) -> Int { 1 }
    func advancePackExpansion(index: Int) {}
    func endPackExpansion() {}
    func pushGenericParams(parameterPacks: [(Int, Int)]) {}
    func popGenericParams() {}
}
