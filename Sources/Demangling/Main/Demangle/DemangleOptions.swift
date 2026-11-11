/// These options mimic those used in the Swift project. Check that project for details.
public struct DemangleOptions: OptionSet, Codable, Sendable {
    public let rawValue: Int

    public static let synthesizeSugarOnTypes = DemangleOptions(rawValue: 1 << 0)
    public static let displayDebuggerGeneratedModule = DemangleOptions(rawValue: 1 << 1)
    public static let qualifyEntities = DemangleOptions(rawValue: 1 << 2)
    public static let displayExtensionContexts = DemangleOptions(rawValue: 1 << 3)
    public static let displayUnmangledSuffix = DemangleOptions(rawValue: 1 << 4)
    public static let displayModuleNames = DemangleOptions(rawValue: 1 << 5)
    public static let displayGenericSpecializations = DemangleOptions(rawValue: 1 << 6)
    public static let displayProtocolConformances = DemangleOptions(rawValue: 1 << 7)
    public static let displayWhereClauses = DemangleOptions(rawValue: 1 << 8)
    public static let displayEntityTypes = DemangleOptions(rawValue: 1 << 9)
    public static let shortenPartialApply = DemangleOptions(rawValue: 1 << 10)
    public static let shortenThunk = DemangleOptions(rawValue: 1 << 11)
    public static let shortenValueWitness = DemangleOptions(rawValue: 1 << 12)
    public static let shortenArchetype = DemangleOptions(rawValue: 1 << 13)
    public static let showPrivateDiscriminators = DemangleOptions(rawValue: 1 << 14)
    public static let showFunctionArgumentTypes = DemangleOptions(rawValue: 1 << 15)
    public static let showAsyncResumePartial = DemangleOptions(rawValue: 1 << 16)
    public static let displayStdlibModule = DemangleOptions(rawValue: 1 << 17)
    public static let displayObjCModule = DemangleOptions(rawValue: 1 << 18)
    public static let printForTypeName = DemangleOptions(rawValue: 1 << 19)
    public static let showClosureSignature = DemangleOptions(rawValue: 1 << 20)
    public static let showModuleInDependentMemberType = DemangleOptions(rawValue: 1 << 21)
    public static let removeWeakPrefix = DemangleOptions(rawValue: 1 << 22)
    public static let removeBoundGeneric = DemangleOptions(rawValue: 1 << 23)
    public static let removeReferenceStoragePrefix = DemangleOptions(rawValue: 1 << 24)
    public static let displayLocalNameContexts = DemangleOptions(rawValue: 1 << 25)
    /// Qualifies names with SE-0491 module selectors — `Swift::Int` instead of
    /// `Swift.Int` — the way the Swift 6.4 compiler writes a `.swiftinterface`
    /// (`PrintOptions::UseModuleSelectors`, which this option is named after).
    ///
    /// A nested type carries a selector of its own, naming the module that
    /// declared it: the module of the nearest enclosing extension, else the
    /// module at the root of its context chain
    /// (`Swift::Duration.Foundation::TimeFormatStyle`). A type declared inside
    /// a function or closure gets none, nor does the associated type of a
    /// type parameter (`A.Element`) — SE-0491 forbids both. A module the other
    /// options hide (`displayModuleNames`, `displayStdlibModule`, …) gets no
    /// selector either. The hard-coded `Builtin.`, `Swift.AnyObject` and
    /// `Swift.Copyable` / `Swift.Escapable` spellings follow suit.
    ///
    /// Not in any preset: upstream's demangler has no such option, and the
    /// presets stay byte-identical to it.
    public static let useModuleSelectors = DemangleOptions(rawValue: 1 << 26)
    /// Spells existential types with the `any` keyword — `any Swift.Error`,
    /// `any P & Q`, `(any P)?`, `any P.Type`, `(any P).Type` — the way the
    /// compiler writes a `.swiftinterface` (SE-0335; named after its upcoming
    /// feature `ExistentialAny`). Without it every existential prints bare, the
    /// metatype of one as `P.Protocol`.
    ///
    /// `Any` and `AnyObject` stay bare, as the compiler leaves them, except in
    /// a metatype, where the compiler writes the keyword for them too:
    /// `any Any.Type` for the existential metatype, `(any Any).Type` for the
    /// metatype of the existential. An existential spelled with the keyword is
    /// parenthesized wherever a suffix would otherwise bind to its last
    /// protocol — `(any P)?`, `(any P & Q)!`, `(any P.Type)?` — and the
    /// composition under an existential metatype's keyword is parenthesized
    /// too (`any (P & Q).Type`, which the bare spelling writes as the
    /// ambiguous `P & Q.Type`). A parameterized existential carries the
    /// keyword with or without this option (`any P<…>`); inside an existential
    /// metatype it is written once (`any P<…>.Type`).
    ///
    /// Not in any preset: upstream's demangler has no such option, and the
    /// presets stay byte-identical to it.
    public static let useExistentialAny = DemangleOptions(rawValue: 1 << 27)

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let `default`: DemangleOptions = [
        .displayDebuggerGeneratedModule,
        .qualifyEntities,
        .displayExtensionContexts,
        .displayUnmangledSuffix,
        .displayModuleNames,
        .displayGenericSpecializations,
        .displayProtocolConformances,
        .displayWhereClauses,
        .displayEntityTypes,
        .showPrivateDiscriminators,
        .showFunctionArgumentTypes,
        .showAsyncResumePartial,
        .displayStdlibModule,
        .displayObjCModule,
        .showClosureSignature,
        .showModuleInDependentMemberType,
        .displayLocalNameContexts,
    ]

    /// Upstream's `DemangleOptions::SimplifiedUIDemangleOptions()`, written the
    /// way upstream writes it: start from the default options and change the
    /// ones it names. Every other option keeps its default — local-name
    /// contexts, closure signatures, the standard-library, Objective-C and
    /// debugger module rules, and the contexts inside a dependent member type.
    /// Listing only the options upstream sets to `true` dropped those, which
    /// is how this preset once printed `Bar` where the toolchain prints
    /// `Bar #1 in foo()`.
    public static let simplified: DemangleOptions = {
        var options = DemangleOptions.default
        options.insert(.synthesizeSugarOnTypes)
        options.insert(.qualifyEntities)
        options.remove(.displayExtensionContexts)
        options.remove(.displayUnmangledSuffix)
        options.remove(.displayModuleNames)
        options.remove(.displayGenericSpecializations)
        options.remove(.displayProtocolConformances)
        options.remove(.displayWhereClauses)
        options.remove(.displayEntityTypes)
        options.insert(.shortenPartialApply)
        options.insert(.shortenThunk)
        options.insert(.shortenValueWitness)
        options.insert(.shortenArchetype)
        options.remove(.showPrivateDiscriminators)
        options.remove(.showFunctionArgumentTypes)
        options.remove(.showAsyncResumePartial)
        return options
    }()

    public static let interface: DemangleOptions = {
        var options = DemangleOptions.default
        options.remove(.displayObjCModule)
        options.insert(.synthesizeSugarOnTypes)
        options.remove(.displayWhereClauses)
        options.remove(.displayExtensionContexts)
        options.remove(.showPrivateDiscriminators)
        options.remove(.showModuleInDependentMemberType)
        options.remove(.displayUnmangledSuffix)
        return options
    }()

    public static let interfaceType: DemangleOptions = {
        var options = DemangleOptions.interface
        options.insert(.removeBoundGeneric)
        return options
    }()

    public static let interfaceBuilderOnly: DemangleOptions = {
        var options = DemangleOptions.interface
        options.insert(.displayObjCModule)
        return options
    }()

    public static let interfaceTypeBuilderOnly: DemangleOptions = {
        var options = DemangleOptions.interfaceBuilderOnly
        options.insert(.removeBoundGeneric)
        return options
    }()

    public static let opaqueTypeBuilderOnly: DemangleOptions = {
        var options = DemangleOptions.interfaceTypeBuilderOnly
        options.insert(.showModuleInDependentMemberType)
        return options
    }()
}
