import FoundationToolbox

/// Generic tree-printing engine shared by the public `NodePrinter<Target>`
/// (specialized on `Node`) and store-backed printing (specialized on
/// `NodeReference`). See evolution proposal 0001, Phase 2.
///
/// SPI note: exposed as `@_spi(Internals)` so deep consumers (MachOSwiftSection)
/// can print `NodeReference` trees into custom rich targets.
/// `NodePrintContext.node` is populated on both paths via `materializedNode` —
/// free on the `Node` path, a small per-unique-node materialization on the
/// store path (context-carrying writes happen inside cached fragments, so each
/// unique node pays once). The type-reference scope hooks also deliver on both
/// paths, but only the `Node` path delivers a canonical instance: store-backed
/// printing materializes a fresh subtree per evaluation, so scopes must be
/// keyed by structure (e.g. the remangled string) rather than by
/// `===`/`ObjectIdentifier`. Print through the static ``print(_:options:)``,
/// which routes the walk through `StackSafeExecutor` — the instance-level walk
/// is deliberately not public, so no consumer can accidentally tie the depth a
/// tree survives to the stack its calling thread happens to have left.
@_spi(Internals)
public struct DemanglingPrinter<Target: NodePrinterTarget, SomeNode: DemanglingNode>: DemanglingLogging, Sendable {
    /// Bails the print recursion with `<<too complex>>` once a single
    /// root-to-leaf path would exceed this many ``printName`` frames.
    ///
    /// This is upstream's value, and it is upstream's for a reason: the limit
    /// exists to stop pathological input, not to bound real symbols.
    ///
    /// It was briefly lowered to 512 on the `feature/node-store` branch,
    /// reasoning from an unoptimized-build stack measurement (~11.6KB per
    /// ``printName`` level; 725 levels survived an 8MB thread, 745 overflowed
    /// it) and from a corpus scan that put the deepest real-world symbol at 41
    /// levels. **That corpus figure was wrong.** Downstream consumers reported
    /// `<<too complex>>` on ordinary SwiftUI and similarly generic-heavy
    /// modules under the 512 limit — real symbols do exceed it, so the limit
    /// was truncating correct output. Restored to 768.
    ///
    /// The debug-build stack risk the lowering was meant to address is real
    /// and remains: at 768 levels an unoptimized build can exhaust an 8MB
    /// thread before the counter fires. That is tracked as a stack-safety
    /// issue (`Documentations/KnownIssues.md`), not paid for by silently
    /// truncating output a release build renders fine. Do not lower this
    /// again without corpus evidence gathered from downstream workloads.
    public static var maxPrintDepth: Int { 768 }

    /// Bound for ``findSugar(_:depth:)``, the only print recursion that does
    /// not converge on ``printName(_:asPrefixContext:)``. Sugar wrappers are a
    /// handful of nodes deep in any tree the demangler produces.
    static var maxSugarWrapperDepth: Int { 64 }

    private var target: Target
    private var specializationPrefixPrinted: Bool
    private var options: DemangleOptions
    private var hidingCurrentModule: String = ""
    private var dependentMemberTypeDepth: Int = 0
    private var printDepth: Int = 0
    /// Number of times the walk hit ``maxPrintDepth`` and gave up. Used to
    /// detect that a subtree's rendering is a truncation and must not enter
    /// ``printCache``.
    private var truncationCount: Int = 0
    /// Number of times ``printSpecializationPrefix`` consulted the one-shot
    /// "specialized " latch. A fragment during whose rendering that happened
    /// depends on walk-global state — it either contains the prefix (and a
    /// cache replay would print it a second time) or omits it (and a replay at
    /// a position where the latch is clear would drop it) — so such fragments
    /// must not enter ``printCache``.
    private var specializationPrefixVisitCount: Int = 0
    /// Depth of scopes that temporarily override ``options``. Today the only
    /// such scope is ``printExtendedExistentialTypeShape(_:)`` forcing
    /// `.displayWhereClauses` on (an option flip inherited from the C++
    /// printer). The fragment cache is keyed by node identity alone, so a
    /// fragment rendered under overridden options is not interchangeable with
    /// one rendered under the surrounding options: while this is non-zero,
    /// ``printName(_:asPrefixContext:)`` bypasses the cache entirely — reads
    /// as well as writes. Blocking only writes would not be enough: a
    /// fragment cached *outside* the override (without its where clause) must
    /// not be replayed *inside* it either.
    private var optionsOverrideDepth: Int = 0
    /// Memoizes the rendered fragment for each shared substitution node.
    /// The demangler returns the same ``SomeNode`` instance for every
    /// back-reference (``A23_`` etc.), so one mangling can produce a DAG
    /// that — naively walked child-by-child — expands into hundreds of
    /// thousands of node visits (a SwiftUI ``View.Body`` typealias was
    /// measured at 394k visits / 246 unique nodes, max-repeat 19, depth
    /// 41). Caching the printed fragment keyed by ``ObjectIdentifier(node)``
    /// brings cost back to the size of the unique node set instead of the
    /// exponential expansion. Apple's own C++ ``NodePrinter`` does not do
    /// this (so ``swift demangle`` itself hangs on the same input).
    private var printCache: [SomeNode.PrintCacheIdentity: Target] = [:]

    /// Internal, matching ``printRoot(_:)``.
    ///
    /// This used to be `public` while `printRoot` was not, which made the type
    /// constructible from outside the module and then useless — the instance
    /// had no reachable way to run a walk. Printing is deliberately
    /// static-only (see the type doc): every public entry routes through
    /// `StackSafeExecutor`, so a tree's surviving depth never depends on the
    /// calling thread's remaining stack. Keeping the initializer public would
    /// only advertise an instance API that cannot be driven.
    init(options: DemangleOptions = .default) {
        self.target = .init()
        self.specializationPrefixPrinted = false
        self.options = options
    }

    /// Prints `root` into a fresh `Target` on a stack large enough for real
    /// symbols.
    ///
    /// This is the only public way to run the walk: it routes through
    /// `StackSafeExecutor`, so the depth a tree survives does not depend on
    /// how much stack the calling thread happens to have left.
    public static func print(_ root: SomeNode, options: DemangleOptions = .default) -> Target {
        StackSafeExecutor.executeWithUncheckedSendability {
            var printer = DemanglingPrinter(options: options)
            return printer.printRoot(root)
        }
    }

    /// Prints `root` and returns the finished target.
    ///
    /// Every piece of walk state is reset here, not just the stack budget.
    /// A printer is a reusable value, and each of these carried the previous
    /// walk into the next one: the target appended the second symbol to the
    /// first, the fragment cache replayed the first symbol's output for a
    /// colliding key, and the "specialized " latch stayed set so the second
    /// symbol silently lost its prefix. The cache key is where it bit hardest
    /// — on the store path it is a per-store node index, and index 0 of one
    /// store means nothing in another.
    mutating func printRoot(_ root: SomeNode) -> Target {
        target = Target()
        printCache.removeAll(keepingCapacity: true)
        specializationPrefixPrinted = false
        dependentMemberTypeDepth = 0
        printDepth = 0
        truncationCount = 0
        specializationPrefixVisitCount = 0
        optionsOverrideDepth = 0
        _ = printName(root)
        return target
    }

    private mutating func printName(_ name: SomeNode, asPrefixContext: Bool = false) -> SomeNode? {
        // `<=`, not `<`: `printDepth` is still the *enclosing* frame count here
        // (the increment is below), so upstream's `if (depth > MaxDepth)` with a
        // depth-0 root truncates on the 770th frame. Spelling this `<` shaved a
        // level off the budget — the direction the comment on `maxPrintDepth`
        // argues against at length, since the limit was restored from 512 to 768
        // precisely because real symbols were being truncated
        // (PR #7 review, finding 3).
        guard printDepth <= Self.maxPrintDepth else {
            // Matches the C++ printer's behaviour when it hits `MaxDepth`: emit
            // the marker in place and unwind this path only, so siblings of the
            // too-deep path still print.
            target.write("<<too complex>>")
            truncationCount += 1
            return nil
        }
        // Only memoize prints that don't depend on caller-side state. A
        // `dependentMemberTypeDepth > 0` chain or `asPrefixContext` changes
        // the rendered output for the same node, and so does a temporary
        // options override (`optionsOverrideDepth > 0`), so those calls
        // bypass the cache to stay correct.
        let canCache = !asPrefixContext && dependentMemberTypeDepth == 0 && optionsOverrideDepth == 0
        if canCache, let cached = printCache[name.printCacheIdentity] {
            target.append(cached)
            return nil
        }
        printDepth += 1
        defer { printDepth -= 1 }
        if canCache {
            // Redirect output into a fresh sub-target so we can capture the
            // exact slice produced for `name`, then splice it back into the
            // live target and remember it for later reuse.
            var subTarget = Target()
            swap(&target, &subTarget)
            let truncationCountBefore = truncationCount
            let specializationPrefixVisitCountBefore = specializationPrefixVisitCount
            let result = dispatchPrintName(name, asPrefixContext: asPrefixContext)
            swap(&target, &subTarget)
            // Only memoize a rendering that is complete and position-
            // independent. A fragment whose descendant hit the depth limit
            // ends in `<<too complex>>`, and one that consulted the one-shot
            // "specialized " latch renders differently depending on where in
            // the walk it runs; caching either replays the wrong output at
            // positions the uncached walk would have handled correctly.
            if truncationCount == truncationCountBefore,
               specializationPrefixVisitCount == specializationPrefixVisitCountBefore {
                printCache[name.printCacheIdentity] = subTarget
            }
            target.append(subTarget)
            return result
        }
        return dispatchPrintName(name, asPrefixContext: asPrefixContext)
    }

    /// The `#N` discriminator displayed for a node index.
    ///
    /// `demangleIndex` rejects `UInt64.max` and then returns `value + 1`, so a
    /// mangled index of `UInt64.max - 1` legitimately arrives here already
    /// saturated and the display increment has nowhere to go. Printing is
    /// public and non-throwing — there is no error channel to reject it the
    /// way `demangleAsNode` rejects a malformed index — so the value wraps and
    /// the wrap is logged. Without the log a malformed symbol would render an
    /// ordinary-looking `#0` and leave no trace at all.
    ///
    /// The unsaturated path keeps trapping `+`: the guard has already ruled
    /// out the only value that could overflow it, so a trap here would mean
    /// this invariant broke rather than that the input was malformed.
    private func displayDiscriminator(_ rawIndex: UInt64, of kind: Node.Kind) -> UInt64 {
        guard rawIndex != .max else {
            reportSaturatedDiscriminator(of: kind)
            return 0
        }
        return rawIndex + 1
    }

    /// Out of line so the dispatch switch carries one comparison and none of
    /// the logging machinery.
    @inline(never)
    private func reportSaturatedDiscriminator(of kind: Node.Kind) {
        #log(
            .error,
            "\(String(describing: kind), privacy: .public) discriminator saturates its display increment; printing #0 instead. Only a malformed mangled index reaches this value."
        )
    }

    private mutating func dispatchPrintName(_ name: SomeNode, asPrefixContext: Bool = false) -> SomeNode? {
        switch name.kind {
        case .accessibleFunctionRecord:
            if !options.contains(.shortenThunk) {
                target.write("accessible function runtime record for ")
            }
        case .accessorAttachedMacroExpansion:
            return printMacro(name: name, asPrefixContext: asPrefixContext, label: "accessor")
        case .accessorFunctionReference:
            target.write("accessor function at \(name.index ?? 0)")
        case .allocator:
            return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .functionStyle, hasName: false, extraName: (name.children.first?.kind == .class) ? "__allocating_init" : "init")
        case .anonymousContext:
            printAnonymousContext(name)
        case .anonymousDescriptor:
            printFirstChild(name, prefix: "anonymous descriptor ")
        case .anyProtocolConformanceList:
            printChildren(name, prefix: "(", suffix: ")", separator: ", ")
        case .argumentTuple:
            printFunctionParameters(labelList: nil, parameterType: name, showTypes: options.contains(.showFunctionArgumentTypes))
        case .associatedConformanceDescriptor:
            printAssociatedConformanceDescriptor(name)
        case .associatedType:
            return nil
        case .associatedTypeDescriptor:
            printFirstChild(name, prefix: "associated type descriptor for ")
        case .associatedTypeGenericParamRef:
            printChildren(name, prefix: "generic parameter reference for associated type ")
        case .associatedTypeMetadataAccessor:
            printAssociatedTypeMetadataAccessor(name)
        case .associatedTypeRef:
            printAssociatedTypeRef(name)
        case .associatedTypeWitnessTableAccessor:
            printAssociatedTypeWitnessTableAccessor(name)
        case .assocTypePath:
            printChildren(name, separator: ".")
        case .asyncAnnotation:
            target.write(" async")
        case .asyncAwaitResumePartialFunction:
            printAsyncAwaitResumePartialFunction(name)
        case .asyncFunctionPointer:
            target.write("async function pointer to ")
        case .asyncRemoved:
            printFirstChild(name, prefix: "async demotion of ")
        case .asyncSuspendResumePartialFunction:
            printAsyncSuspendResumePartialFunction(name)
        case .autoDiffFunction,
             .autoDiffDerivativeVTableThunk:
            printAutoDiffFunctionOrSimpleThunk(name)
        case .autoDiffFunctionKind:
            printAutoDiffFunctionKind(name)
        case .autoDiffSelfReorderingReabstractionThunk:
            printAutoDiffSelfReorderingReabstractionThunk(name)
        case .autoDiffSubsetParametersThunk:
            printAutoDiffSubsetParametersThunk(name)
        case .backDeploymentFallback:
            if !options.contains(.shortenThunk) {
                target.write("back deployment fallback for ")
            }
        case .backDeploymentThunk:
            if !options.contains(.shortenThunk) {
                target.write("back deployment thunk for ")
            }
        case .baseConformanceDescriptor:
            printBaseConformanceDescriptor(name)
        case .baseWitnessTableAccessor:
            printBaseWitnessTableAccessor(name)
        case .borrowAccessor: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "borrow")
        case .bodyAttachedMacroExpansion:
            return printMacro(name: name, asPrefixContext: asPrefixContext, label: "body")
        case .boundGenericClass,
             .boundGenericStructure,
             .boundGenericEnum,
             .boundGenericProtocol,
             .boundGenericOtherNominalType,
             .boundGenericTypeAlias:
            // Barrier scope: angle brackets, commas, and sugar punctuation
            // written by the bound-generic printer belong to no type
            // reference; the base type and each argument push their own
            // scopes when they recurse through the nominal cases below.
            target.pushTypeReferenceScope(nil)
            defer { target.popTypeReferenceScope() }
            printBoundGeneric(name)
        case .builtinBorrow:
            target.write("Builtin.Borrow<")
            printFirstChild(name)
            target.write(">")
        case .builtinFixedArray:
            printBuildInFixedArray(name)
        case .builtinTupleType:
            target.write("Builtin.TheTupleType")
        case .builtinTypeName:
            target.write(name.text ?? "")
        case .canonicalPrespecializedGenericTypeCachingOnceToken:
            printFirstChild(name, prefix: "flag for loading of canonical specialized generic type metadata for ")
        case .canonicalSpecializedGenericMetaclass: printFirstChild(name, prefix: "specialized generic metaclass for ")
        case .canonicalSpecializedGenericTypeMetadataAccessFunction: printFirstChild(name, prefix: "canonical specialized generic type metadata accessor for ")
        case .cFunctionPointer,
             .objCBlock,
             .noEscapeFunctionType,
             .escapingAutoClosureType,
             .autoClosureType,
             .thinFunctionType,
             .functionType,
             .escapingObjCBlock,
             .uncurriedFunctionType: printFunctionType(name)
        case .clangType: target.write(name.text ?? "")
        case .class,
             .structure,
             .enum,
             .protocol,
             .typeAlias:
            // The full qualified-name print (module, dots, identifier) for
            // this nominal reference runs inside one scope so rich targets
            // can group the writes into a single span keyed by `name`.
            // The autoclosure defers materialization: targets that ignore
            // scopes (String) never evaluate it, so store-backed plain-text
            // printing stays allocation-free; rich targets materialize only
            // this nominal reference's small subtree.
            target.pushTypeReferenceScope(name.materializedNode)
            defer { target.popTypeReferenceScope() }
            return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .noType, hasName: true)
        case .classMetadataBaseOffset: printFirstChild(name, prefix: "class metadata base offset for ")
        case .compileTimeLiteral: printFirstChild(name, prefix: "_const ")
        case .constValue: printFirstChild(name, prefix: "@const ")
        case .concreteProtocolConformance: printConcreteProtocolConformance(name)
        case .concurrentFunctionType: target.write("@Sendable ")
        case .conformanceAttachedMacroExpansion: return printMacro(name: name, asPrefixContext: asPrefixContext, label: "conformance")
        case .constrainedExistential: printConstrainedExistential(name)
        case .constrainedExistentialRequirementList: printChildren(name, separator: ", ")
        case .constrainedExistentialSelf: target.write("Self")
        case .constructor: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .functionStyle, hasName: name.children.count > 2, extraName: "init")
        case .coroutineContinuationPrototype: printFirstChild(name, prefix: "coroutine continuation prototype for ")
        case .curryThunk: printFirstChild(name, prefix: "curry thunk of ")
        case .deallocator: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .noType, hasName: false, extraName: (name.children.first?.kind == .class) ? "__deallocating_deinit" : "deinit")
        case .declContext: printFirstChild(name)
        case .defaultArgumentInitializer: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .noType, hasName: false, extraName: "default argument \(name.children.at(1)?.index ?? 0)")
        case .defaultAssociatedConformanceAccessor: printDefaultAssociatedConformanceAccessor(name)
        case .defaultAssociatedTypeMetadataAccessor: printFirstChild(name, prefix: "default associated type metadata accessor for ")
        case .dependentAssociatedConformance: printChildren(name, prefix: "dependent associated conformance ")
        case .dependentAssociatedTypeRef: printDependentAssociatedTypeRef(name)
        case .dependentGenericConformanceRequirement: printDependentGenericConformanceRequirement(name)
        case .dependentGenericInverseConformanceRequirement: printDependentGenericInverseConformanceRequirement(name)
        case .dependentGenericLayoutRequirement: printDependentGenericLayoutRequirement(name)
        case .dependentGenericParamCount: return nil
        case .dependentGenericParamPackMarker: break
        case .dependentGenericParamType: target.write(name.text ?? "")
        case .dependentGenericParamValueMarker: break
        case .dependentGenericSameShapeRequirement: printDependentGenericSameShapeRequirement(name)
        case .dependentGenericSameTypeRequirement: printDependentGenericSameTypeRequirement(name)
        case .dependentGenericType: printDependentGenericType(name)
        case .dependentMemberType: printDependentMemberType(name)
        case .dependentProtocolConformanceAssociated: printDependentProtocolConformanceAssociated(name)
        case .dependentProtocolConformanceInherited: printDependentProtocolConformanceInherited(name)
        case .dependentProtocolConformanceRoot: printDependentProtocolConformanceRoot(name)
        case .dependentProtocolConformanceOpaque: printDependentProtocolConformanceOpaque(name)
        case .dependentPseudogenericSignature,
             .dependentGenericSignature: printGenericSignature(name)
        case .destructor: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .noType, hasName: false, extraName: "deinit")
        case .didSet: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "didset")
        case .differentiabilityWitness: printDifferentiabilityWitness(name)
        case .differentiableFunctionType: printDifferentiableFunctionType(name)
        case .directMethodReferenceAttribute: target.write("super ")
        case .directness: name.index.flatMap { Directness(rawValue: $0)?.description }.map { target.write("\($0) ") }
        case .dispatchThunk: printFirstChild(name, prefix: "dispatch thunk of ")
        case .distributedAccessor:
            if !options.contains(.shortenThunk) {
                target.write("distributed accessor for ")
            }
        case .distributedThunk:
            if !options.contains(.shortenThunk) {
                target.write("distributed thunk ")
            }
        case .droppedArgument: target.write("param\(name.index ?? 0)-removed")
        case .dynamicallyReplaceableFunctionImpl:
            if !options.contains(.shortenThunk) {
                target.write("dynamically replaceable thunk for ")
            }
        case .dynamicallyReplaceableFunctionKey:
            if !options.contains(.shortenThunk) {
                target.write("dynamically replaceable key for ")
            }
        case .dynamicallyReplaceableFunctionVar:
            if !options.contains(.shortenThunk) {
                target.write("dynamically replaceable variable for ")
            }
        case .dynamicAttribute: target.write("dynamic ")
        case .dynamicSelf: target.write("Self")
        case .emptyList: target.write(" empty-list ")
        case .enumCase: printFirstChild(name, prefix: "enum case for ", asPrefixContext: false)
        case .errorType: target.write("<ERROR TYPE>")
        case .existentialMetatype: printExistentialMetatype(name)
        case .explicitClosure: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: options.contains(.showFunctionArgumentTypes) ? .functionStyle : .noType, hasName: false, extraName: "closure #", extraIndex: displayDiscriminator(name.children.at(1)?.index ?? 0, of: name.kind))
        case .extendedExistentialTypeShape: printExtendedExistentialTypeShape(name)
        case .extension: printExtension(name)
        case .extensionAttachedMacroExpansion: return printMacro(name: name, asPrefixContext: asPrefixContext, label: "extension")
        case .preambleAttachedMacroExpansion: return printMacro(name: name, asPrefixContext: asPrefixContext, label: "preamble")
        case .extensionDescriptor: printFirstChild(name, prefix: "extension descriptor ")
        case .fieldOffset: printFieldOffset(name)
        case .firstElementMarker: target.write(" first-element-marker ")
        case .freestandingMacroExpansion: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .noType, hasName: true, extraName: "freestanding macro expansion #", extraIndex: displayDiscriminator(name.children.at(2)?.index ?? 0, of: name.kind))
        case .fullObjCResilientClassStub: printFirstChild(name, prefix: "full ObjC resilient class stub for ")
        case .fullTypeMetadata: printFirstChild(name, prefix: "full type metadata for ")
        case .function,
             .boundGenericFunction: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .functionStyle, hasName: true)
        case .functionSignatureSpecialization: printSpecializationPrefix(name, description: "function signature specialization")
        case .functionSignatureSpecializationParam: printFunctionSignatureSpecializationParam(name)
        case .functionSignatureSpecializationParamKind: printFunctionSignatureSpecializationParamKind(name)
        case .functionSignatureSpecializationParamPayload:
            if let text = name.text {
                let demangledName = (try? demangleAsNodeTransient(text))?.print(using: options) ?? ""
                if demangledName.isEmpty {
                    target.write(text)
                } else {
                    target.write(demangledName)
                }
            } else if name.hasIndex {
                target.write("\(name.index ?? 0)")
            }
        case .functionSignatureSpecializationReturn: printFunctionSignatureSpecializationParam(name)
        case .genericPartialSpecialization: printSpecializationPrefix(name, description: "generic partial specialization", paramPrefix: "Signature = ")
        case .genericPartialSpecializationNotReAbstracted: printSpecializationPrefix(name, description: "generic not-reabstracted partial specialization", paramPrefix: "Signature = ")
        case .genericProtocolWitnessTable: printFirstChild(name, prefix: "generic protocol witness table for ")
        case .genericProtocolWitnessTableInstantiationFunction: printFirstChild(name, prefix: "instantiation function for generic protocol witness table for ")
        case .genericSpecialization,
             .genericSpecializationInResilienceDomain: printSpecializationPrefix(name, description: "generic specialization")
        case .genericSpecializationNotReAbstracted: printSpecializationPrefix(name, description: "generic not re-abstracted specialization")
        case .genericSpecializationParam: printGenericSpecializationParam(name)
        case .genericSpecializationPrespecialized: printSpecializationPrefix(name, description: "generic pre-specialization")
        case .genericTypeMetadataPattern: printFirstChild(name, prefix: "generic type metadata pattern for ")
        case .genericTypeParamDecl: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .noType, hasName: true)
        case .getter: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "getter")
        case .global: printChildren(name)
        case .globalActorFunctionType: printGlobalActorFunctionType(name)
        case .globalGetter: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "getter")
        case .globalVariableOnceDeclList: printGlobalVariableOnceDeclList(name)
        case .globalVariableOnceFunction,
             .globalVariableOnceToken: printGlobalVariableOnceFunction(name)
        case .hasSymbolQuery: target.write("#_hasSymbol query for ")
        case .identifier: printIdentifier(name, asPrefixContext: asPrefixContext)
        case .implConvention: target.write(name.text ?? "")
        case .implCoroutineKind: printImplCoroutineKind(name)
        case .implDifferentiabilityKind: printImplDifferentiabilityKind(name)
        case .implErasedIsolation: target.write("@isolated(any)")
        case .implErrorResult: printChildren(name, prefix: "@error ", separator: " ")
        case .implParameter,
             .implResult: printImplParameter(name)
        case .implEscaping: target.write("@escaping")
        case .implFunctionAttribute: target.write(name.text ?? "")
        case .implFunctionConvention: printImplFunctionConvention(name)
        case .implFunctionConventionName: break
        case .implFunctionType: printImplFunctionType(name)
        case .implicitClosure: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: options.contains(.showFunctionArgumentTypes) ? .functionStyle : .noType, hasName: false, extraName: "implicit closure #", extraIndex: displayDiscriminator(name.children.at(1)?.index ?? 0, of: name.kind))
        case .implInvocationSubstitutions: printImplInvocationSubstitutions(name)
        case .implParameterResultDifferentiability: printImplParameterName(name)
        case .implParameterSending,
             .implParameterIsolated,
             .implParameterImplicitLeading: printImplParameterName(name)
        case .implPatternSubstitutions: printImplPatternSubstitutions(name)
        case .implSendingResult: target.write("sending")
        case .implYield: printChildren(name, prefix: "@yields ", separator: " ")
        case .index: target.write("\(name.index ?? 0)")
        case .indexSubset: printIndexSubset(name)
        case .infixOperator: target.write("\(name.text ?? "") infix")
        case .initAccessor: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "init")
        case .initializer: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .noType, hasName: false, extraName: "variable initialization expression")
        case .inlinedGenericFunction: printSpecializationPrefix(name, description: "inlined generic function")
        case .inOut: printFirstChild(name, prefix: "inout ")
        case .integer: target.write("\(name.index ?? 0)")
        case .isolated: printFirstChild(name, prefix: "isolated ")
        case .isolatedAnyFunctionType: target.write("@isolated(any) ")
        case .isolatedDeallocator: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .noType, hasName: false, extraName: name.children.first?.kind == .class ? "__isolated_deallocating_deinit" : "deinit")
        case .isSerialized: target.write("serialized")
        case .iVarDestroyer: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .noType, hasName: false, extraName: "__ivar_destroyer")
        case .iVarInitializer: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .noType, hasName: false, extraName: "__ivar_initializer")
        case .keyPathEqualsThunkHelper,
             .keyPathHashThunkHelper: printKeyPathEqualityThunkHelper(name)
        case .keyPathGetterThunkHelper,
             .keyPathSetterThunkHelper,
             .keyPathAppliedMethodThunkHelper,
             .keyPathUnappliedMethodThunkHelper: printKeyPathAccessorThunkHelper(name)
        case .labelList: break
        case .lazyProtocolWitnessTableAccessor: printLazyProtocolWitnesstableAccessor(name)
        case .lazyProtocolWitnessTableCacheVariable: printLazyProtocolWitnesstableCacheVariable(name)
        case .localDeclName: _ = printOptional(name.children.at(1), suffix: options.contains(.displayLocalNameContexts) ? " #\(displayDiscriminator(name.children.at(0)?.index ?? 0, of: name.kind))" : nil)
        case .macro: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: name.children.count == 3 ? .withColon : .functionStyle, hasName: true)
        case .macroExpansionLoc: printMacroExpansionLoc(name)
        case .macroExpansionUniqueName: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .noType, hasName: true, extraName: "unique name #", extraIndex: displayDiscriminator(name.children.at(2)?.index ?? 0, of: name.kind))
        case .materializeForSet: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "materializeForSet")
        case .memberAttachedMacroExpansion: return printMacro(name: name, asPrefixContext: asPrefixContext, label: "member")
        case .memberAttributeAttachedMacroExpansion: return printMacro(name: name, asPrefixContext: asPrefixContext, label: "memberAttribute")
        case .mergedFunction: target.write(!options.contains(.shortenThunk) ? "merged " : "")
        case .metaclass: printFirstChild(name, prefix: "metaclass for ")
        case .metadataInstantiationCache: printFirstChild(name, prefix: "metadata instantiation cache for ")
        case .metatype: printMetatype(name)
        case .metatypeRepresentation: target.write(name.text ?? "")
        case .methodDescriptor: printFirstChild(name, prefix: "method descriptor for ")
        case .methodLookupFunction: printFirstChild(name, prefix: "method lookup function for ")
        case .modifyAccessor: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "modify")
        case .modify2Accessor: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "modify2")
        case .mutateAccessor: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "mutate")
        case .module: printModule(name)
        case .moduleDescriptor: printFirstChild(name, prefix: "module descriptor ")
        case .nativeOwningAddressor: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "nativeOwningAddressor")
        case .nativeOwningMutableAddressor: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "nativeOwningMutableAddressor")
        case .nativePinningAddressor: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "nativePinningAddressor")
        case .nativePinningMutableAddressor: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "nativePinningMutableAddressor")
        case .negativeInteger: target.write("-\(name.index ?? 0)")
        case .noDerivative: printFirstChild(name, prefix: "@noDerivative ")
        case .nominalTypeDescriptor: printFirstChild(name, prefix: "nominal type descriptor for ")
        case .nominalTypeDescriptorRecord: printFirstChild(name, prefix: "nominal type descriptor runtime record for ")
        case .noncanonicalSpecializedGenericTypeMetadata: printFirstChild(name, prefix: "noncanonical specialized generic type metadata for ")
        case .noncanonicalSpecializedGenericTypeMetadataCache: printFirstChild(name, prefix: "cache variable for noncanonical specialized generic type metadata for ")
        case .nonObjCAttribute: target.write("@nonobjc ")
        case .nonUniqueExtendedExistentialTypeShapeSymbolicReference:
            target.write("non-unique existential shape symbolic reference 0x")
            target.write((name.index ?? 0).hexadecimalString)
        case .number: target.write("\(name.index ?? 0)")
        case .objCAsyncCompletionHandlerImpl,
             .checkedObjCAsyncCompletionHandlerImpl: printObjCAsyncCompletionHandlerImpl(name)
        case .objCAttribute: target.write("@objc ")
        case .objCMetadataUpdateFunction: printFirstChild(name, prefix: "ObjC metadata update function for ")
        case .objCResilientClassStub: printFirstChild(name, prefix: "ObjC resilient class stub for ")
        case .objectiveCProtocolSymbolicReference:
            target.write("objective-c protocol symbolic reference 0x")
            target.write((name.index ?? 0).hexadecimalString)
        case .opaqueReturnType: target.write("some")
        case .opaqueReturnTypeIndex: break
        case .opaqueReturnTypeOf: printChildren(name, prefix: "<<opaque return type of ", suffix: ">>")
        case .opaqueReturnTypeParent: break
        case .opaqueType: printOpaqueType(name)
        case .opaqueTypeDescriptor: printFirstChild(name, prefix: "opaque type descriptor for ")
        case .opaqueTypeDescriptorAccessor: printFirstChild(name, prefix: "opaque type descriptor accessor for ")
        case .opaqueTypeDescriptorAccessorImpl: printFirstChild(name, prefix: "opaque type descriptor accessor impl for ")
        case .opaqueTypeDescriptorAccessorKey: printFirstChild(name, prefix: "opaque type descriptor accessor key for ")
        case .opaqueTypeDescriptorAccessorVar: printFirstChild(name, prefix: "opaque type descriptor accessor var for ")
        case .opaqueTypeDescriptorRecord: printFirstChild(name, prefix: "opaque type descriptor runtime record for ")
        case .opaqueTypeDescriptorSymbolicReference:
            target.write("opaque type symbolic reference 0x")
            target.write((name.index ?? 0).hexadecimalString)
        case .otherNominalType: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .noType, hasName: true)
        case .outlinedAssignWithCopy,
             .outlinedAssignWithCopyNoValueWitness: printFirstChild(name, prefix: "outlined assign with copy of ")
        case .outlinedAssignWithTake,
             .outlinedAssignWithTakeNoValueWitness: printFirstChild(name, prefix: "outlined assign with take of ")
        case .outlinedBridgedMethod: target.write("outlined bridged method (\(name.text ?? "")) of ")
        case .outlinedConsume:
            printFirstChild(name, prefix: "outlined consume of ")
            _ = printOptional(name.children.at(1))
        case .outlinedCopy:
            printFirstChild(name, prefix: "outlined copy of ")
            _ = printOptional(name.children.at(1))
        case .outlinedDestroy,
             .outlinedDestroyNoValueWitness: printFirstChild(name, prefix: "outlined destroy of ")
        case .outlinedEnumGetTag: printFirstChild(name, prefix: "outlined enum get tag of ")
        case .outlinedEnumProjectDataForLoad: printFirstChild(name, prefix: "outlined enum project data for load of ")
        case .outlinedEnumTagStore: printFirstChild(name, prefix: "outlined enum tag store of ")
        case .outlinedInitializeWithCopy,
             .outlinedInitializeWithCopyNoValueWitness: printFirstChild(name, prefix: "outlined init with copy of ")
        case .outlinedInitializeWithTake,
             .outlinedInitializeWithTakeNoValueWitness: printFirstChild(name, prefix: "outlined init with take of ")
        case .outlinedReadOnlyObject: target.write("outlined read-only object #\(name.index ?? 0) of ")
        case .outlinedRelease: printFirstChild(name, prefix: "outlined release of ")
        case .outlinedRetain: printFirstChild(name, prefix: "outlined retain of ")
        case .outlinedVariable: target.write("outlined variable #\(name.index ?? 0) of ")
        case .owned: printFirstChild(name, prefix: "__owned ")
        case .owningAddressor: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "owningAddressor")
        case .owningMutableAddressor: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "owningMutableAddressor")
        case .pack: printChildren(name, prefix: "Pack{", suffix: "}", separator: ", ")
        case .packElement: printFirstChild(name, prefix: "/* level: \(name.children.at(1)?.index ?? 0) */ each ")
        case .packElementLevel: break
        case .packExpansion: printFirstChild(name, prefix: "repeat ")
        case .packProtocolConformance: printChildren(name, prefix: "pack protocol conformance ")
        case .partialApplyForwarder: printPartialApplyForwarder(name)
        case .partialApplyObjCForwarder: printPartialApplyObjCForwarder(name)
        case .peerAttachedMacroExpansion: return printMacro(name: name, asPrefixContext: asPrefixContext, label: "peer")
        case .postfixOperator: target.write("\(name.text ?? "") postfix")
        case .prefixOperator: target.write("\(name.text ?? "") prefix")
        case .privateDeclName: printPrivateDeclName(name)
        case .propertyDescriptor: printFirstChild(name, prefix: "property descriptor for ")
        case .propertyWrapperBackingInitializer: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .noType, hasName: false, extraName: "property wrapper backing initializer")
        case .propertyWrapperInitFromProjectedValue: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .noType, hasName: false, extraName: "property wrapper init from projected value")
        case .propertyWrappedFieldInitAccessor: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .noType, hasName: false, extraName: "property wrapped field init accessor")
        case .protocolConformance: printProtocolConformance(name)
        case .protocolConformanceDescriptor: printFirstChild(name, prefix: "protocol conformance descriptor for ")
        case .protocolConformanceDescriptorRecord: printFirstChild(name, prefix: "protocol conformance descriptor runtime record for ")
        case .protocolConformanceRefInOtherModule: printChildren(name, prefix: "protocol conformance ref (retroactive) ")
        case .protocolConformanceRefInProtocolModule: printChildren(name, prefix: "protocol conformance ref (protocol's module) ")
        case .protocolConformanceRefInTypeModule: printChildren(name, prefix: "protocol conformance ref (type's module) ")
        case .protocolDescriptor: printFirstChild(name, prefix: "protocol descriptor for ")
        case .protocolDescriptorRecord: printFirstChild(name, prefix: "protocol descriptor runtime record for ")
        case .protocolList: printProtocolList(name)
        case .protocolListWithAnyObject: printProtocolListWithAnyObject(name)
        case .protocolListWithClass: printProtocolListWithClass(name)
        case .protocolRequirementsBaseDescriptor: printFirstChild(name, prefix: "protocol requirements base descriptor for ")
        case .protocolSelfConformanceDescriptor: printFirstChild(name, prefix: "protocol self-conformance descriptor for ")
        case .protocolSelfConformanceWitness: printFirstChild(name, prefix: "protocol self-conformance witness for ")
        case .protocolSelfConformanceWitnessTable: printFirstChild(name, prefix: "protocol self-conformance witness table for ")
        case .protocolSymbolicReference: target.write("protocol symbolic reference \("0x" + String(name.index ?? 0, radix: 16, uppercase: true))")
        case .protocolWitness: printProtocolWitness(name)
        case .protocolWitnessTable: printFirstChild(name, prefix: "protocol witness table for ")
        case .protocolWitnessTableAccessor: printFirstChild(name, prefix: "protocol witness table accessor for ")
        case .protocolWitnessTablePattern: printFirstChild(name, prefix: "protocol witness table pattern for ")
        case .reabstractionThunk,
             .reabstractionThunkHelper: printReabstractionThunk(name)
        case .reabstractionThunkHelperWithGlobalActor: printReabstracctionThunkHelperWithGlobalActor(name)
        case .reabstractionThunkHelperWithSelf: printReabstractionThunkHelperWithSelf(name)
        case .readAccessor: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "read")
        case .read2Accessor: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "read2")
        case .reflectionMetadataAssocTypeDescriptor: printFirstChild(name, prefix: "reflection metadata associated type descriptor ")
        case .reflectionMetadataBuiltinDescriptor: printFirstChild(name, prefix: "reflection metadata builtin descriptor ")
        case .reflectionMetadataFieldDescriptor: printFirstChild(name, prefix: "reflection metadata field descriptor ")
        case .reflectionMetadataSuperclassDescriptor: printFirstChild(name, prefix: "reflection metadata superclass descriptor ")
        case .representationChanged: target.write("representation changed")
        case .relatedEntityDeclName:
            printFirstChild(name, prefix: "related decl '", suffix: "' for ")
            _ = printOptional(name.children.at(1))
        case .resilientProtocolWitnessTable: printFirstChild(name, prefix: "resilient protocol witness table for ")
        case .retroactiveConformance: printRetroactiveConformance(name)
        case .returnType: printReturnType(name)
        case .sending: printFirstChild(name, prefix: "sending ")
        case .sendingResultFunctionType: target.write("sending ")
        case .setter: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "setter")
        case .shared: printFirstChild(name, prefix: "__shared ")
        case .silBoxImmutableField,
             .silBoxMutableField: printFirstChild(name, prefix: name.kind == .silBoxImmutableField ? "let " : "var ")
        case .silBoxLayout: printSequence(name.children, prefix: "{\(name.children.isEmpty ? "" : " ")", suffix: " }", separator: ", ")
        case .silBoxType: printFirstChild(name, prefix: "@box ")
        case .silBoxTypeWithLayout: printSilBoxTypeWithLayout(name)
        case .silPackDirect: printChildren(name, prefix: "@direct Pack{", suffix: "}", separator: ", ")
        case .silPackIndirect: printChildren(name, prefix: "@indirect Pack{", suffix: "}", separator: ", ")
        case .silThunkIdentity: printFirstChild(name, prefix: "identity thunk of ")
        case .specializationPassID: target.write("\(name.index ?? 0)")
        case .static: printFirstChild(name, prefix: "static ")
        case .subscript: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .functionStyle, hasName: true, overwriteName: "subscript")
        case .suffix: printSuffix(name)
        case .sugaredArray: printFirstChild(name, prefix: "[", suffix: "]")
        case .sugaredInlineArray: printChildren(name, prefix: "[", suffix: "]", separator: " of ")
        case .sugaredDictionary: printSugaredDictionary(name)
        case .sugaredOptional: printSugaredOptional(name)
        case .sugaredParen: printFirstChild(name, prefix: "(", suffix: ")")
        case .symbolicExtendedExistentialType: printSymbolicExtendedExistentialType(name)
        case .throwsAnnotation: target.write(" throws")
        case .tuple: printChildren(name, prefix: "(", suffix: ")", separator: ", ")
        case .tupleElement: printTupleElement(name)
        case .tupleElementName: target.write("\(name.text ?? ""): ")
        case .type: printFirstChild(name)
        case .typedThrowsAnnotation: printTypeThrowsAnnotation(name)
        case .typeList: printChildren(name)
        case .typeMangling: printFirstChild(name)
        case .typeMetadata: printFirstChild(name, prefix: "type metadata for ")
        case .typeMetadataAccessFunction: printFirstChild(name, prefix: "type metadata accessor for ")
        case .typeMetadataCompletionFunction: printFirstChild(name, prefix: "type metadata completion function for ")
        case .typeMetadataDemanglingCache: printFirstChild(name, prefix: "demangling cache variable for type metadata for ")
        case .typeMetadataMangledNameRef: printFirstChild(name, prefix: "mangled name ref for type metadata for ")
        case .typeMetadataInstantiationCache: printFirstChild(name, prefix: "type metadata instantiation cache for ")
        case .typeMetadataInstantiationFunction: printFirstChild(name, prefix: "type metadata instantiation function for ")
        case .typeMetadataLazyCache: printFirstChild(name, prefix: "lazy cache variable for type metadata for ")
        case .typeMetadataSingletonInitializationCache: printFirstChild(name, prefix: "type metadata singleton initialization cache for ")
        case .typeSymbolicReference: target.write("type symbolic reference \("0x" + String(name.index ?? 0, radix: 16, uppercase: true))")
        case .uniquable: printFirstChild(name, prefix: "uniquable ")
        case .uniqueExtendedExistentialTypeShapeSymbolicReference:
            target.write("unique existential shape symbolic reference 0x")
            target.write((name.index ?? 0).hexadecimalString)
        case .unknownIndex: target.write("unknown index")
        case .unmanaged: printFirstChild(name, prefix: options.contains(.removeReferenceStoragePrefix) ? "" : "unowned(unsafe) ")
        case .unowned: printFirstChild(name, prefix: options.contains(.removeReferenceStoragePrefix) ? "" : "unowned ")
        case .unsafeAddressor: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "unsafeAddressor")
        case .unsafeMutableAddressor: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "unsafeMutableAddressor")
        case .valueWitness: printValueWitness(name)
        case .valueWitnessTable: printFirstChild(name, prefix: "value witness table for ")
        case .variable: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .withColon, hasName: true)
        case .variadicMarker: target.write(" variadic-marker ")
        case .vTableAttribute: target.write("override ")
        case .vTableThunk: printVTableThunk(name)
        case .weak: printFirstChild(name, prefix: (options.contains(.removeWeakPrefix) || options.contains(.removeReferenceStoragePrefix)) ? "" : "weak ")
        case .willSet: return printAbstractStorage(name.children.first, asPrefixContext: asPrefixContext, extraName: "willset")
        case .nonIsolatedCallerFunctionType: target.write("nonisolated(nonsending) ")
        case .coroFunctionPointer:
            target.write("coro function pointer to ")
        case .defaultOverride:
            target.write("default override of ")
        }

        return nil
    }

    private func shouldPrintContext(_ context: SomeNode) -> Bool {
        guard options.contains(.qualifyEntities) else {
            return false
        }
        if !options.contains(.showModuleInDependentMemberType), dependentMemberTypeDepth > 0 {
            return false
        }
        if context.kind == .module, let text = context.text, !text.isEmpty {
            switch text {
            case stdlibName: return options.contains(.displayStdlibModule)
            case objcModule: return options.contains(.displayObjCModule)
            case hidingCurrentModule: return false
            default:
                if text.starts(with: lldbExpressionsModuleNamePrefix) {
                    return options.contains(.displayDebuggerGeneratedModule)
                }
            }
        }
        return true
    }

    private mutating func printOptional(_ optional: SomeNode?, prefix: String? = nil, suffix: String? = nil, asPrefixContext: Bool = false) -> SomeNode? {
        guard let o = optional else { return nil }
        prefix.map { target.write($0) }
        let r = printName(o)
        suffix.map { target.write($0) }
        return r
    }

    private mutating func printFirstChild(_ ofName: SomeNode, prefix: String? = nil, suffix: String? = nil, asPrefixContext: Bool = false) {
        _ = printOptional(ofName.children.at(0), prefix: prefix, suffix: suffix)
    }

    private mutating func printSequence<S>(_ names: S, prefix: String? = nil, suffix: String? = nil, separator: String? = nil) where S: Sequence, S.Element == SomeNode {
        var isFirst = true
        prefix.map { target.write($0) }
        for c in names {
            if let s = separator, !isFirst {
                target.write(s)
            } else {
                isFirst = false
            }
            _ = printName(c)
        }
        suffix.map { target.write($0) }
    }

    private mutating func printChildren(_ ofName: SomeNode, prefix: String? = nil, suffix: String? = nil, separator: String? = nil) {
        printSequence(ofName.children, prefix: prefix, suffix: suffix, separator: separator)
    }

    private mutating func printMacro(name: SomeNode, asPrefixContext: Bool, label: String) -> SomeNode? {
        return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .noType, hasName: true, extraName: "\(label) macro @\(name.children.at(2)?.print(using: options) ?? "") expansion #", extraIndex: displayDiscriminator(name.children.at(3)?.index ?? 0, of: name.kind))
    }

    private mutating func printAnonymousContext(_ name: SomeNode) {
        if options.contains(.qualifyEntities), options.contains(.displayExtensionContexts) {
            _ = printOptional(name.children.at(1))
            target.write(".(unknown context at " + (name.children.first?.text ?? "") + ")")
            if let second = name.children.at(2), !second.children.isEmpty {
                target.write("<")
                _ = printName(second)
                target.write(">")
            }
        }
    }

    private mutating func printExtension(_ name: SomeNode) {
        if options.contains(.qualifyEntities), options.contains(.displayExtensionContexts) {
            printFirstChild(name, prefix: "(extension in ", suffix: "):", asPrefixContext: true)
        }
        _ = printOptional(name.children.at(1))
        _ = printOptional(!options.contains(.printForTypeName) ? name.children.at(2) : nil)
    }

    private mutating func printSuffix(_ name: SomeNode) {
        if options.contains(.displayUnmangledSuffix) {
            target.write(" with unmangled suffix ")
            quotedString(name.text ?? "")
        }
    }

    private mutating func printPrivateDeclName(_ name: SomeNode) {
        _ = printOptional(name.children.at(1), prefix: options.contains(.showPrivateDiscriminators) ? "(" : nil)
        target.write(options.contains(.showPrivateDiscriminators) ? "\(name.children.count > 1 ? " " : "(")in \(name.children.at(0)?.text ?? ""))" : "")
    }

    private mutating func printModule(_ name: SomeNode) {
        if options.contains(.displayModuleNames) {
            target.write(name.text ?? "", context: .context(for: name.materializedNode, state: .printModule))
        }
    }

    private mutating func printReturnType(_ name: SomeNode) {
        if name.children.isEmpty, let t = name.text {
            target.write(t)
        } else {
            printChildren(name)
        }
    }

    private mutating func printRetroactiveConformance(_ name: SomeNode) {
        if name.children.count == 2 {
            printChildren(name, prefix: "retroactive @ ")
        }
    }

    private mutating func printGenericSpecializationParam(_ name: SomeNode) {
        printFirstChild(name)
        _ = printOptional(name.children.at(1), prefix: " with ")
        for slouse in name.children.slice(2, name.children.endIndex) {
            target.write(" and ")
            _ = printName(slouse)
        }
    }

    private mutating func printFunctionSignatureSpecializationParam(_ name: SomeNode) {
        var idx = 0
        var argIdx = 0
        let end = name.children.count
        while idx < end {
            guard let child = name.children.at(idx), child.hasIndex else { return }
            let v = child.index ?? 0
            let k = FunctionSigSpecializationParamKind(rawValue: v)
            switch k {
            case .boxToValue,
                 .boxToStack,
                 .inOutToOut:
                _ = printOptional(name.children.at(idx))
                idx += 1
            case .constantPropFunction,
                 .constantPropGlobal:
                target.write("[")
                _ = printOptional(name.children.at(idx))
                idx += 1
                target.write(" : ")
                printNextParamChildNode(name, argIdx: &argIdx, kind: k)
                target.write("]")
            case .constantPropInteger,
                 .constantPropFloat:
                _ = printOptional(name.children.at(idx), prefix: "[")
                idx += 1
                _ = printOptional(name.children.at(idx), prefix: " : ", suffix: "]")
                idx += 1
            case .constantPropString:
                if idx + 2 > end { return }
                target.write("[")
                _ = printOptional(name.children.at(idx))
                idx += 1
                _ = printOptional(name.children.at(idx), prefix: " : ")
                idx += 1
                target.write("'")
                printNextParamChildNode(name, argIdx: &argIdx, kind: k)
                target.write("'")
                target.write("]")
            case .constantPropKeyPath:
                target.write("[")
                _ = printOptional(name.children.at(idx))
                idx += 1
                target.write(" : ")
                printNextParamChildNode(name, argIdx: &argIdx, kind: k)
                target.write("<")
                printNextParamChildNode(name, argIdx: &argIdx, kind: k)
                target.write(",")
                printNextParamChildNode(name, argIdx: &argIdx, kind: k)
                target.write(">]")
            case .constantPropStruct:
                target.write("[")
                _ = printOptional(name.children.at(idx))
                idx += 1
                target.write(" : ")
                printNextParamChildNode(name, argIdx: &argIdx, kind: k)
                target.write("]")
            case .closureProp:
                if idx + 2 > end { return }
                target.write("[")
                _ = printOptional(name.children.at(idx))
                idx += 1
                target.write(" : ")
                printNextParamChildNode(name, argIdx: &argIdx, kind: k)
                target.write(", Argument Types : [")
                while argIdx < name.children.count {
                    guard let typeChild = name.children.at(argIdx), typeChild.kind == .type else { break }
                    argIdx += 1
                    _ = printName(typeChild)
                    if argIdx < name.children.count, name.children.at(argIdx)?.kind == .type {
                        target.write(", ")
                    }
                }
                target.write("]")
            case .closurePropPreviousArg:
                if idx + 2 > end { return }
                target.write("[")
                _ = printOptional(name.children.at(idx))
                idx += 1
                target.write(" ")
                _ = printOptional(name.children.at(idx))
                idx += 1
                target.write("]")
            default:
                _ = printOptional(name.children.at(idx))
                idx += 1
            }
        }
    }

    /// Prints the next non-kind/non-payload child node from a specialization param,
    /// applying demangling for function/global props and string leading underscore stripping.
    private mutating func printNextParamChildNode(_ node: SomeNode, argIdx: inout Int, kind: FunctionSigSpecializationParamKind?) {
        while argIdx < node.children.count {
            let child = node.children[argIdx]
            argIdx += 1
            if child.kind == .functionSignatureSpecializationParamKind ||
               child.kind == .functionSignatureSpecializationParamPayload {
                continue
            }
            switch kind {
            case .constantPropInteger, .constantPropFloat:
                guard let text = child.text else { return }
                let demangledName = (try? demangleAsNodeTransient(text))?.print(using: options) ?? ""
                if demangledName.isEmpty {
                    target.write(text)
                } else {
                    target.write(demangledName)
                }
            case .constantPropString:
                if let text = child.text, !text.isEmpty, text.first == "_" {
                    target.write(String(text.dropFirst()))
                    return
                }
                _ = printName(child)
            case .constantPropFunction, .constantPropGlobal:
                let text = child.text ?? ""
                let demangledName = (try? demangleAsNodeTransient(text))?.print(using: options) ?? ""
                if demangledName.isEmpty {
                    target.write(text)
                } else {
                    target.write(demangledName)
                }
            default:
                _ = printName(child)
            }
            return
        }
    }

    private mutating func printFunctionSignatureSpecializationParamKind(_ name: SomeNode) {
        let raw = name.index ?? 0
        var printedOptionSet = false
        if raw & FunctionSigSpecializationParamKind.existentialToGeneric.rawValue != 0 {
            printedOptionSet = true
            target.write(FunctionSigSpecializationParamKind.existentialToGeneric.description)
        }
        if raw & FunctionSigSpecializationParamKind.dead.rawValue != 0 {
            if printedOptionSet { target.write(" and ") }
            printedOptionSet = true
            target.write(FunctionSigSpecializationParamKind.dead.description)
        }
        if raw & FunctionSigSpecializationParamKind.ownedToGuaranteed.rawValue != 0 {
            if printedOptionSet { target.write(" and ") }
            printedOptionSet = true
            target.write(FunctionSigSpecializationParamKind.ownedToGuaranteed.description)
        }
        if raw & FunctionSigSpecializationParamKind.guaranteedToOwned.rawValue != 0 {
            if printedOptionSet { target.write(" and ") }
            printedOptionSet = true
            target.write(FunctionSigSpecializationParamKind.guaranteedToOwned.description)
        }
        if raw & FunctionSigSpecializationParamKind.sroa.rawValue != 0 {
            if printedOptionSet { target.write(" and ") }
            printedOptionSet = true
            target.write(FunctionSigSpecializationParamKind.sroa.description)
        }

        if printedOptionSet {
            return
        }

        if let single = FunctionSigSpecializationParamKind(rawValue: raw) {
            target.write(single.description)
        }
    }

    private mutating func printLazyProtocolWitnesstableAccessor(_ name: SomeNode) {
        _ = printOptional(name.children.at(0), prefix: "lazy protocol witness table accessor for type ")
        _ = printOptional(name.children.at(1), prefix: " and conformance ")
    }

    private mutating func printLazyProtocolWitnesstableCacheVariable(_ name: SomeNode) {
        _ = printOptional(name.children.at(0), prefix: "lazy protocol witness table cache variable for type ")
        _ = printOptional(name.children.at(1), prefix: " and conformance ")
    }

    private mutating func printVTableThunk(_ name: SomeNode) {
        _ = printOptional(name.children.at(1), prefix: "vtable thunk for ")
        _ = printOptional(name.children.at(0), prefix: " dispatching to ")
    }

    private mutating func printProtocolWitness(_ name: SomeNode) {
        _ = printOptional(name.children.at(1), prefix: "protocol witness for ")
        _ = printOptional(name.children.at(0), prefix: " in conformance ")
    }

    private mutating func printPartialApplyForwarder(_ name: SomeNode) {
        target.write("partial apply\(options.contains(.shortenPartialApply) ? "" : " forwarder")")
        if !name.children.isEmpty {
            printChildren(name, prefix: " for ")
        }
    }

    private mutating func printPartialApplyObjCForwarder(_ name: SomeNode) {
        target.write("partial apply\(options.contains(.shortenPartialApply) ? "" : " ObjC forwarder")")
        if !name.children.isEmpty {
            printChildren(name, prefix: " for ")
        }
    }

    private mutating func printKeyPathAccessorThunkHelper(_ name: SomeNode) {
        let prefix = switch name.kind {
        case .keyPathGetterThunkHelper: "getter for "
        case .keyPathSetterThunkHelper: "setter for "
        case .keyPathUnappliedMethodThunkHelper: "unapplied method "
        case .keyPathAppliedMethodThunkHelper: "applied method "
        default: ""
        }
        printFirstChild(name, prefix: "key path \(prefix)", suffix: " : ")
        for child in name.children.dropFirst() {
            if child.kind == .isSerialized {
                target.write(", ")
            }
            _ = printName(child)
        }
    }

    private mutating func printKeyPathEqualityThunkHelper(_ name: SomeNode) {
        target.write("key path index \(name.kind == .keyPathEqualsThunkHelper ? "equality" : "hash") operator for ")
        var dropLast = false
        if let lastChild = name.children.last, lastChild.kind == .dependentGenericSignature {
            _ = printName(lastChild)
            dropLast = true
        }
        if dropLast {
            printSequence(name.children.dropLast(), prefix: "(", suffix: ")", separator: ", ")
        } else {
            printSequence(name.children, prefix: "(", suffix: ")", separator: ", ")
        }
    }

    private mutating func printFieldOffset(_ name: SomeNode) {
        printFirstChild(name)
        _ = printOptional(name.children.at(1), prefix: "field offset for ", asPrefixContext: true)
    }

    private mutating func printReabstractionThunk(_ name: SomeNode) {
        if options.contains(.shortenThunk) {
            _ = printOptional(name.children.at(name.children.count - 2), prefix: "thunk for ")
        } else {
            target.write("reabstraction thunk ")
            target.write(name.kind == .reabstractionThunkHelper ? "helper " : "")
            _ = printOptional(name.children.at(name.children.count - 3), suffix: " ")
            _ = printOptional(name.children.at(name.children.count - 1), prefix: "from ")
            _ = printOptional(name.children.at(name.children.count - 2), prefix: " to ")
        }
    }

    private mutating func printAssociatedConformanceDescriptor(_ name: SomeNode) {
        _ = printOptional(name.children.at(0), prefix: "associated conformance descriptor for ")
        _ = printOptional(name.children.at(1), prefix: ".")
        _ = printOptional(name.children.at(2), prefix: ": ")
    }

    private mutating func printDefaultAssociatedConformanceAccessor(_ name: SomeNode) {
        _ = printOptional(name.children.at(0), prefix: "default associated conformance accessor for ")
        _ = printOptional(name.children.at(1), prefix: ".")
        _ = printOptional(name.children.at(2), prefix: ": ")
    }

    private mutating func printAssociatedTypeMetadataAccessor(_ name: SomeNode) {
        _ = printOptional(name.children.at(1), prefix: "associated type metadata accessor for ")
        _ = printOptional(name.children.at(0), prefix: " in ")
    }

    private mutating func printAssociatedTypeWitnessTableAccessor(_ name: SomeNode) {
        _ = printOptional(name.children.at(1), prefix: "associated type witness table accessor for ")
        _ = printOptional(name.children.at(2), prefix: " : ")
        _ = printOptional(name.children.at(0), prefix: " in ")
    }

    private mutating func printValueWitness(_ name: SomeNode) {
        // ValueWitness node structure: first child is Index node with the witness kind
        let witnessIndex = name.children.first?.index ?? 0
        target.write(ValueWitnessKind(rawValue: witnessIndex)?.description ?? "")
        target.write(options.contains(.shortenValueWitness) ? " for " : " value witness for ")
        // Print the type (second child, at index 1)
        _ = printOptional(name.children.at(1))
    }

    private mutating func printConcreteProtocolConformance(_ name: SomeNode) {
        target.write("concrete protocol conformance ")
        if let index = name.index {
            target.write("#\(index) ")
        }
        printFirstChild(name)
        target.write(" to ")
        _ = printOptional(name.children.at(1))
        if let thirdChild = name.children.at(2), !thirdChild.children.isEmpty {
            target.write(" with conditional requirements: ")
            _ = printName(thirdChild)
        }
    }

    private mutating func printMetatype(_ name: SomeNode) {
        if name.children.count == 2 {
            printFirstChild(name, suffix: " ")
        }
        guard let type = name.children.at(name.children.count == 2 ? 1 : 0)?.children.first else { return }
        let needParens = !type.isSimpleType
        target.write(needParens ? "(" : "")
        _ = printName(type)
        target.write(needParens ? ")" : "")
        target.write(type.kind.isExistentialType ? ".Protocol" : ".Type")
    }

    private mutating func printExistentialMetatype(_ name: SomeNode) {
        if name.children.count == 2 {
            printFirstChild(name, suffix: " ")
        }
        _ = printOptional(name.children.at(name.children.count == 2 ? 1 : 0), suffix: ".Type")
    }

    private mutating func printAssociatedTypeRef(_ name: SomeNode) {
        printFirstChild(name)
        target.write(".\(name.children.at(1)?.text ?? "")")
    }

    private mutating func printProtocolList(_ name: SomeNode) {
        guard let typeList = name.children.first else { return }
        if typeList.children.isEmpty {
            target.write("Any")
        } else {
            printChildren(typeList, separator: " & ")
        }
    }

    private mutating func printProtocolListWithClass(_ name: SomeNode) {
        guard name.children.count >= 2 else { return }
        _ = printOptional(name.children.at(1), suffix: " & ")
        if let protocolsTypeList = name.children.first?.children.first {
            printChildren(protocolsTypeList, separator: " & ")
        }
    }

    private mutating func printProtocolListWithAnyObject(_ name: SomeNode) {
        guard let prot = name.children.first, let protocolsTypeList = prot.children.first else { return }
        if protocolsTypeList.children.count > 0 {
            printChildren(protocolsTypeList, suffix: " & ", separator: " & ")
        }
        if options.contains(.qualifyEntities) && options.contains(.displayStdlibModule) {
            target.write("Swift.")
        }
        target.write("AnyObject")
    }

    private mutating func printProtocolConformance(_ name: SomeNode) {
        if name.children.count == 4 {
            _ = printOptional(name.children.at(2), prefix: "property behavior storage of ")
            _ = printOptional(name.children.at(0), prefix: " in ")
            _ = printOptional(name.children.at(1), prefix: " : ")
        } else {
            printFirstChild(name)
            if options.contains(.displayProtocolConformances) {
                _ = printOptional(name.children.at(1), prefix: " : ")
                _ = printOptional(name.children.at(2), prefix: " in ")
            }
        }
    }

    private mutating func printImplParameter(_ name: SomeNode) {
        printFirstChild(name, suffix: " ")
        if name.children.count == 3 {
            _ = printOptional(name.children.at(1))
        } else if name.children.count == 4 {
            _ = printOptional(name.children.at(1))
            _ = printOptional(name.children.at(2))
        }
        _ = printOptional(name.children.last)
    }

    private mutating func printDependentProtocolConformanceAssociated(_ name: SomeNode) {
        target.write("dependent associated protocol conformance ")
        if let index = name.children.at(2)?.index {
            target.write("#\(index) ")
        }
        printFirstChild(name)
        target.write(" to ")
        _ = printOptional(name.children.at(1))
    }

    private mutating func printDependentProtocolConformanceInherited(_ name: SomeNode) {
        target.write("dependent inherited protocol conformance ")
        if let index = name.children.at(2)?.index {
            target.write("#\(index) ")
        }
        printFirstChild(name)
        target.write(" to ")
        _ = printOptional(name.children.at(1))
    }

    private mutating func printDependentProtocolConformanceRoot(_ name: SomeNode) {
        target.write("dependent root protocol conformance ")
        if let index = name.children.at(2)?.index {
            target.write("#\(index) ")
        }
        printFirstChild(name)
        target.write(" to ")
        _ = printOptional(name.children.at(1))
    }

    private mutating func printDependentProtocolConformanceOpaque(_ name: SomeNode) {
        target.write("opaque result conformance ")
        printFirstChild(name)
        target.write(" of ")
        _ = printOptional(name.children.at(1))
    }

    private static func genericParameterName(depth: UInt64, index: UInt64) -> String {
        var name = ""
        var index = index
        repeat {
            if let scalar = UnicodeScalar(UnicodeScalar("A").value + UInt32(index % 26)) {
                name.unicodeScalars.append(scalar)
            }
            index /= 26
        } while index != 0
        if depth != 0 {
            name.append("\(depth)")
        }
        return name
    }

    private mutating func printGenericSignature(_ name: SomeNode) {
        target.write("<")
        var numGenericParams = 0
        for c in name.children {
            guard c.kind == .dependentGenericParamCount else { break }
            numGenericParams += 1
        }
        var firstRequirement = numGenericParams
        for var c in name.children.dropFirst(numGenericParams) {
            if c.kind == .type {
                c = c.children.first ?? c
            }
            guard c.kind == .dependentGenericParamPackMarker || c.kind == .dependentGenericParamValueMarker else {
                break
            }
            firstRequirement += 1
        }

        let isGenericParamPack = { (depth: UInt64, index: UInt64) -> Bool in
            for var child in name.children.dropFirst(numGenericParams).prefix(firstRequirement) {
                guard child.kind == .dependentGenericParamPackMarker else { continue }

                child = child.children.first ?? child
                guard child.kind == .type else { continue }

                child = child.children.first ?? child
                guard child.kind == .dependentGenericParamType else { continue }

                if index == child.children.at(0)?.index, depth == child.children.at(1)?.index {
                    return true
                }
            }

            return false
        }

        let isGenericParamValue = { (depth: UInt64, index: UInt64) -> SomeNode? in
            for var child in name.children.dropFirst(numGenericParams).prefix(firstRequirement) {
                guard child.kind == .dependentGenericParamValueMarker else { continue }
                child = child.children.first ?? child

                guard child.kind == .type else { continue }

                guard
                    let param = child.children.at(0),
                    let type = child.children.at(1),
                    param.kind == .dependentGenericParamType
                else {
                    continue
                }

                if index == param.children.at(0)?.index, depth == param.children.at(1)?.index {
                    return type
                }
            }

            return nil
        }

        for gpDepth in 0 ..< numGenericParams {
            if gpDepth != 0 {
                target.write("><")
            }

            guard let count = name.children.at(gpDepth)?.index else { continue }
            for index in 0 ..< count {
                if index != 0 {
                    target.write(", ")
                }

                // Limit the number of printed generic parameters. In practice this
                // it will never be exceeded. The limit is only important for malformed
                // symbols where count can be really huge.
                if index >= 128 {
                    target.write("...")
                    break
                }

                if isGenericParamPack(UInt64(gpDepth), UInt64(index)) {
                    target.write("each ")
                }

                let value = isGenericParamValue(UInt64(gpDepth), UInt64(index))
                if value != nil {
                    target.write("let ")
                }

                target.write(Self.genericParameterName(depth: UInt64(gpDepth), index: UInt64(index)))

                if let value {
                    target.write(": ")
                    _ = printName(value)
                }
            }
        }

        if firstRequirement != name.children.count {
            if options.contains(.displayWhereClauses) {
                target.write(" where ")
                printSequence(name.children.dropFirst(firstRequirement), separator: ", ")
            }
        }
        target.write(">")
    }

    private mutating func printDependentGenericConformanceRequirement(_ name: SomeNode) {
        printFirstChild(name)
        _ = printOptional(name.children.at(1), prefix: ": ")
    }

    private mutating func printDependentGenericLayoutRequirement(_ name: SomeNode) {
        guard let layout = name.children.at(1), let c = layout.text?.unicodeScalars.first else { return }
        printFirstChild(name, suffix: ": ")
        switch c {
        case "U": target.write("_UnknownLayout")
        case "R": target.write("_RefCountedObject")
        case "N": target.write("_NativeRefCountedObject")
        case "C": target.write("AnyObject")
        case "D": target.write("_NativeClass")
        case "T": target.write("_Trivial")
        case "E",
             "e": target.write("_Trivial")
        case "M",
             "m": target.write("_TrivialAtMost")
        default: break
        }
        if name.children.count > 2 {
            _ = printOptional(name.children.at(2), prefix: "(")
            _ = printOptional(name.children.at(3), prefix: ", ")
            target.write(")")
        }
    }

    private mutating func printDependentGenericSameTypeRequirement(_ name: SomeNode) {
        printFirstChild(name)
        _ = printOptional(name.children.at(1), prefix: " == ")
    }

    private mutating func printDependentGenericType(_ name: SomeNode) {
        guard let depType = name.children.at(1) else { return }
        printFirstChild(name)
        _ = printOptional(depType, prefix: depType.needSpaceBeforeType ? " " : "")
    }

    private mutating func printDependentMemberType(_ name: SomeNode) {
        dependentMemberTypeDepth += 1
        defer { dependentMemberTypeDepth -= 1 }
        printFirstChild(name)
        target.write(".")
        _ = printOptional(name.children.at(1))
    }

    private mutating func printDependentAssociatedTypeRef(_ name: SomeNode) {
        _ = printOptional(name.children.at(1), suffix: ".")
        printFirstChild(name)
    }

    private mutating func printSilBoxTypeWithLayout(_ name: SomeNode) {
        guard let layout = name.children.first else { return }
        _ = printOptional(name.children.at(1), suffix: " ")
        _ = printName(layout)
        if let genericArgs = name.children.at(2) {
            printSequence(genericArgs.children, prefix: " <", suffix: ">", separator: ", ")
        }
    }

    private mutating func printSugaredOptional(_ name: SomeNode) {
        if let type = name.children.first {
            let needParens = !type.isSimpleType
            target.write(needParens ? "(" : "")
            _ = printName(type)
            target.write(needParens ? ")" : "")
            target.write("?")
        }
    }

    private mutating func printSugaredDictionary(_ name: SomeNode) {
        printFirstChild(name, prefix: "[", suffix: " : ")
        _ = printOptional(name.children.at(1), suffix: "]")
    }

    private mutating func printOpaqueType(_ name: SomeNode) {
        printFirstChild(name)
        target.write(".")
        _ = printOptional(name.children.at(1))
//        _ = printOptional(name.children.at(2))
//        printChildren(name, separator: ".")
    }

    private mutating func printImplInvocationsSubstitutions(_ name: SomeNode) {
        if let secondChild = name.children.at(0) {
            target.write(" for <")
            printChildren(secondChild, separator: ", ")
            target.write(">")
        }
    }

    private mutating func printImplPatternSubstitutions(_ name: SomeNode) {
        target.write("@substituted ")
        printFirstChild(name)
        if let secondChild = name.children.at(1) {
            target.write(" for <")
            printChildren(secondChild, separator: ", ")
            target.write(">")
        }
    }

    private mutating func printImplDifferentiability(_ name: SomeNode) {
        if let text = name.text, !text.isEmpty {
            target.write("\(text) ")
        }
    }

    private mutating func printMacroExpansionLoc(_ name: SomeNode) {
        if let module = name.children.at(0) {
            target.write("module ")
            _ = printName(module)
        }
        if let file = name.children.at(1) {
            target.write(" file ")
            _ = printName(file)
        }
        if let line = name.children.at(2) {
            target.write(" line ")
            _ = printName(line)
        }
        if let column = name.children.at(3) {
            target.write(" column ")
            _ = printName(column)
        }
    }

    private mutating func printGlobalActorFunctionType(_ name: SomeNode) {
        if let firstChild = name.children.first {
            target.write("@")
            _ = printName(firstChild)
            target.write(" ")
        }
    }

    private mutating func printGlobalVariableOnceFunction(_ name: SomeNode) {
        target.write(name.kind == .globalVariableOnceToken ? "one-time initialization token for " : "one-time initialization function for ")
        if let firstChild = name.children.first {
            _ = shouldPrintContext(firstChild)
        }
        if let secondChild = name.children.at(1) {
            _ = printName(secondChild)
        }
    }

    private mutating func printGlobalVariableOnceDeclList(_ name: SomeNode) {
        if name.children.count == 1 {
            printFirstChild(name)
        } else {
            printSequence(name.children, prefix: "(", suffix: ")", separator: ", ")
        }
    }

    private mutating func printTypeThrowsAnnotation(_ name: SomeNode) {
        target.write(" throws(")
        if let child = name.children.first {
            _ = printName(child)
        }
        target.write(")")
    }

    private mutating func printDifferentiableFunctionType(_ name: SomeNode) {
        target.write("@differentiable")
        // `UInt8(name.index ?? 0)` trapped for any index above 255, inside a
        // public non-throwing API with no error channel to reject it. The
        // failable `Differentiability` initializer is the spelling
        // `printDifferentiabilityWitness` ten lines below already uses.
        switch Differentiability(name.index ?? 0) {
        case .forward: target.write("(_forward)")
        case .reverse: target.write("(reverse)")
        case .linear: target.write("(_linear)")
        default: break
        }
    }

    private mutating func printDifferentiabilityWitness(_ name: SomeNode) {
        let kindNodeIndex = name.children.count - (name.children.last?.kind == .dependentGenericSignature ? 4 : 3)
        let kind = (name.children.at(kindNodeIndex)?.index).flatMap { Differentiability($0) }
        switch kind {
        case .forward: target.write("forward-mode")
        case .reverse: target.write("reverse-mode")
        case .normal: target.write("normal")
        case .linear: target.write("linear")
        default: return
        }
        target.write(" differentiability witness for ")
        var idx = 0
        while idx < name.children.count, name.children.at(idx)?.kind != .index {
            _ = printOptional(name.children.at(idx))
            idx += 1
        }
        _ = printOptional(name.children.at(idx + 1), prefix: " with respect to parameters ")
        _ = printOptional(name.children.at(idx + 2), prefix: " and results ")
        _ = printOptional(name.children.at(idx + 3), prefix: " with ")
    }

    // The two force unwraps these replaced were the only ones left in the
    // printer. The demangler always gives these nodes a child, but a tree built
    // through `Node.createTransient`, `NodeStoreBuilder.intern(kind:)` or a
    // `Node.Rewriter` need not — and `.showAsyncResumePartial`, which is what
    // reaches them, is part of `.default`.
    private mutating func printAsyncAwaitResumePartialFunction(_ name: SomeNode) {
        if options.contains(.showAsyncResumePartial) {
            target.write("(")
            if let child = name.children.first {
                _ = printName(child)
            }
            target.write(")")
            target.write(" await resume partial function for ")
        }
    }

    private mutating func printAsyncSuspendResumePartialFunction(_ name: SomeNode) {
        if options.contains(.showAsyncResumePartial) {
            target.write("(")
            if let child = name.children.first {
                _ = printName(child)
            }
            target.write(")")
            target.write(" suspend resume partial function for ")
        }
    }

    private mutating func printExtendedExistentialTypeShape(_ name: SomeNode) {
        // Printing the requirement signature is useless without its where
        // clause, so the C++ printer forces `DisplayWhereClauses` on for this
        // subtree; the flip itself is faithful to upstream. Upstream has no
        // fragment cache, so flipping is all it needs; here the flip must
        // also suspend the cache (`optionsOverrideDepth`), otherwise a
        // signature node shared between this subtree and the surrounding walk
        // replays with — or without — its where clause depending on which
        // position happened to render first.
        let overridesDisplayWhereClauses = !options.contains(.displayWhereClauses)
        if overridesDisplayWhereClauses {
            options.insert(.displayWhereClauses)
            optionsOverrideDepth += 1
        }
        defer {
            if overridesDisplayWhereClauses {
                options.remove(.displayWhereClauses)
                optionsOverrideDepth -= 1
            }
        }
        // Indices 1 and 2 are upstream's, and they are upstream's off-by-one:
        // `demangleExtendedExistentialShape` builds the children at 0 and 1 —
        // as does `createWithChildren` in the C++ demangler — so reading 1 and
        // 2 prints the requirement signature in the type position and leaves
        // the type itself `<null node pointer>`. Both the two-child and the
        // one-child shape come out that way.
        //
        // **Do not "fix" this to read 0 and 1.** This port's contract is
        // reproducing the Swift compiler's demangler, so matching
        // `swift demangle` byte for byte outranks producing nicer output here;
        // a consumer diffing against the toolchain must see what the toolchain
        // sees. Reading 0 and 1 has been proposed in review and rejected —
        // recorded under "adjudicated non-defects" in
        // `Documentations/KnownIssues.md`. If upstream ever fixes its printer,
        // follow it there rather than ahead of it.
        var genericSignature: SomeNode?
        var shapeType: SomeNode?
        if name.children.count == 2 {
            genericSignature = name.children.at(1)
            shapeType = name.children.at(2)
        } else {
            shapeType = name.children.at(1)
        }
        target.write("existential shape for ")
        if let genericSignature {
            _ = printName(genericSignature)
            target.write(" ")
        }
        target.write("any ")
        if let shapeType {
            _ = printName(shapeType)
        } else {
            target.write("<null node pointer>")
        }
    }

    private mutating func printSymbolicExtendedExistentialType(_ name: SomeNode) {
        guard let shape = name.children.first else { return }
        let isUnique = shape.kind == .uniqueExtendedExistentialTypeShapeSymbolicReference
        target.write("symbolic existential type (\(isUnique ? "" : "non-")unique) 0x")
        target.write((shape.index ?? 0).hexadecimalString)
        target.write(" <")
        guard let second = name.children.at(1) else { return }
        _ = printName(second)
        if let third = name.children.at(2) {
            target.write(", ")
            _ = printName(third)
        }
        target.write(">")
    }

    private mutating func printTupleElement(_ name: SomeNode) {
        if let label = name.children.first(where: { $0.kind == .tupleElementName }) {
            target.write("\(label.text ?? ""): ")
        }
        guard let type = name.children.first(where: { $0.kind == .type }) else { return }
        _ = printName(type)
        if let _ = name.children.first(where: { $0.kind == .variadicMarker }) {
            target.write("...")
        }
    }

    private mutating func printObjCAsyncCompletionHandlerImpl(_ name: SomeNode) {
        if name.kind == .checkedObjCAsyncCompletionHandlerImpl {
            target.write("predefined ")
        }
        target.write("@objc completion handler block implementation for ")
        if name.children.count >= 4 {
            _ = printOptional(name.children.at(3))
        }
        printFirstChild(name, suffix: " with result type ")
        _ = printOptional(name.children.at(1))
        switch name.children.at(2)?.index {
        case 0: break
        case 1: target.write(" nonzero on error")
        case 2: target.write(" zero on error")
        default: target.write(" <invalid error flag>")
        }
    }

    private mutating func printImplInvocationSubstitutions(_ name: SomeNode) {
        if let secondChild = name.children.at(0) {
            target.write(" for <")
            printChildren(secondChild, separator: ", ")
            target.write(">")
        }
    }

    private mutating func printImplDifferentiabilityKind(_ name: SomeNode) {
        target.write("@differentiable")
        if let value = name.index, let differentiability = Differentiability(value) {
            switch differentiability {
            case .normal: break
            case .linear: target.write("(_linear)")
            case .forward: target.write("(_forward)")
            case .reverse: target.write("(reverse)")
            }
        }
    }

    private mutating func printImplCoroutineKind(_ name: SomeNode) {
        guard let value = name.text, !value.isEmpty else { return }
        target.write("@\(value)")
    }

    private mutating func printImplFunctionConvention(_ name: SomeNode) {
        target.write("@convention(")
        if let second = name.children.at(1) {
            target.write("\(name.children.at(0)?.text ?? ""), mangledCType: \"")
            _ = printName(second)
            target.write("\"")
        } else {
            target.write("\(name.children.at(0)?.text ?? "")")
        }
        target.write(")")
    }

    private mutating func printImplParameterName(_ name: SomeNode) {
        guard let value = name.text, !value.isEmpty else { return }
        target.write("\(value) ")
    }

    private mutating func printBaseConformanceDescriptor(_ name: SomeNode) {
        printFirstChild(name, prefix: "base conformance descriptor for ")
        _ = printOptional(name.children.at(1), prefix: ": ")
    }

    private mutating func printReabstractionThunkHelperWithSelf(_ name: SomeNode) {
        target.write("reabstraction thunk ")
        var idx = 0
        if name.children.count == 4 {
            printFirstChild(name, suffix: " ")
            idx += 1
        }
        _ = printOptional(name.children.at(idx + 2), prefix: "from ")
        _ = printOptional(name.children.at(idx + 1), prefix: " to ")
        _ = printOptional(name.children.at(idx), prefix: " self ")
    }

    private mutating func printReabstracctionThunkHelperWithGlobalActor(_ name: SomeNode) {
        printFirstChild(name)
        _ = printOptional(name.children.at(1), prefix: " with global actor constraint ")
    }

    private mutating func printBuildInFixedArray(_ name: SomeNode) {
        _ = printOptional(name.children.first, prefix: "Builtin.FixedArray<")
        _ = printOptional(name.children.at(1), prefix: ", ", suffix: ">")
    }

    private mutating func printAutoDiffFunctionOrSimpleThunk(_ name: SomeNode) {
        var prefixEndIndex = 0
        while prefixEndIndex < name.children.count, name.children[prefixEndIndex].kind != .autoDiffFunctionKind {
            prefixEndIndex += 1
        }

        let funcKind = name.children.at(prefixEndIndex)
        let paramIndices = name.children.at(prefixEndIndex + 1)
        let resultIndices = name.children.at(prefixEndIndex + 2)
        if name.kind == .autoDiffDerivativeVTableThunk {
            target.write("vtable thunk for ")
        }
        _ = printOptional(funcKind)
        target.write(" of ")
        var optionalGenSig: SomeNode?
        for i in 0 ..< prefixEndIndex {
            if i == prefixEndIndex - 1, name.children.at(i)?.kind == .dependentGenericSignature {
                optionalGenSig = name.children.at(i)
                break
            }
            _ = printOptional(name.children.at(i))
        }
        if options.contains(.shortenThunk) {
            return
        }
        target.write(" with respect to parameters ")
        _ = printOptional(paramIndices)
        target.write(" and results ")
        _ = printOptional(resultIndices)
        _ = printOptional(options.contains(.displayWhereClauses) ? optionalGenSig : nil, prefix: " with ")
    }

    private mutating func printAutoDiffFunctionKind(_ name: SomeNode) {
        guard let kind = name.index else { return }
        switch AutoDiffFunctionKind(kind) {
        case .forward: target.write("forward-mode derivative")
        case .reverse: target.write("reverse-mode derivative")
        case .differential: target.write("differential")
        case .pullback: target.write("pullback")
        default: break
        }
    }

    private mutating func printAutoDiffSelfReorderingReabstractionThunk(_ name: SomeNode) {
        target.write("autodiff self-reordering reabstraction thunk ")
        let fromType = name.children.first
        _ = printOptional(options.contains(.shortenThunk) ? fromType : nil, prefix: "for ")
        let toType = name.children.at(1)
        var kindIndex = 2
        var optionalGenSig: SomeNode?
        if name.children.at(kindIndex)?.kind == .dependentGenericSignature {
            optionalGenSig = name.children.at(kindIndex)
            kindIndex += 1
        }
        target.write("for ")
        _ = printOptional(name.children.at(kindIndex))
        _ = printOptional(optionalGenSig, suffix: " ")
        _ = printOptional(fromType, prefix: " from ")
        _ = printOptional(toType, prefix: " to ")
    }

    private mutating func printAutoDiffSubsetParametersThunk(_ name: SomeNode) {
        target.write("autodiff subset parameters thunk for ")
        let lastIndex = name.children.count - 1
        let toParamIndices = name.children.at(lastIndex)
        let resultIndices = name.children.at(lastIndex - 1)
        let paramIndices = name.children.at(lastIndex - 2)
        let kind = name.children.at(lastIndex - 3)
        let currentIndex = lastIndex - 4
        _ = printOptional(kind, suffix: " from ")
        // Upstream only ever reaches this printer from a demangler-built tree,
        // which always carries the four trailing children read above, so
        // `lastIndex - 4` is never negative there. Public node construction
        // has no such guarantee: a node with fewer children sends a negative
        // length into `prefix(_:)`, which traps — and `print(using:)` is
        // non-throwing, so there is no channel to reject it. Print what the
        // node does carry instead.
        if currentIndex == 0 {
            printFirstChild(name)
        } else if currentIndex > 0 {
            printSequence(name.children.prefix(currentIndex))
        }
        if options.contains(.shortenThunk) {
            return
        }
        target.write(" with respect to parameters ")
        _ = printOptional(paramIndices)
        target.write(" and results ")
        _ = printOptional(resultIndices)
        target.write(" to parameters ")
        _ = printOptional(toParamIndices)
        _ = printOptional(currentIndex > 0 ? name.children.at(currentIndex) : nil, prefix: " of type ")
    }

    private mutating func printIndexSubset(_ name: SomeNode) {
        target.write("{")
        var printedAnyIndex = false
        for (i, c) in (name.text ?? "").enumerated() {
            if c != "S" {
                continue
            }
            if printedAnyIndex {
                target.write(", ")
            }
            target.write("\(i)")
            printedAnyIndex = true
        }
        target.write("}")
    }

    private mutating func printBaseWitnessTableAccessor(_ name: SomeNode) {
        _ = printOptional(name.children.at(1), prefix: "base witness table accessor for ")
        _ = printOptional(name.children.at(0), prefix: " in ")
    }

    private mutating func printDependentGenericInverseConformanceRequirement(_ name: SomeNode) {
        printFirstChild(name, suffix: ": ~")
        switch name.children.at(1)?.index {
        case 0: target.write("Swift.Copyable")
        case 1: target.write("Swift.Escapable")
        default: target.write("Swift.<bit \(name.children.at(1)?.index ?? 0)>")
        }
    }

    private mutating func printDependentGenericSameShapeRequirement(_ name: SomeNode) {
        _ = printOptional(name.children.at(0), suffix: ".shape == ")
        _ = printOptional(name.children.at(1), suffix: ".shape")
    }

    private mutating func printConstrainedExistential(_ name: SomeNode) {
        printFirstChild(name, prefix: "any ")
        _ = printOptional(name.children.at(1), prefix: "<", suffix: ">")
    }

    private mutating func printIdentifier(_ name: SomeNode, asPrefixContext: Bool = false, parentKind: Node.Kind? = nil) {
        target.write(name.text ?? "", context: .context(for: name.materializedNode, parentKind: parentKind, state: .printIdentifier))
    }

    private mutating func printAbstractStorage(_ name: SomeNode?, asPrefixContext: Bool, extraName: String) -> SomeNode? {
        guard let n = name else { return nil }
        switch n.kind {
        case .variable: return printEntity(n, asPrefixContext: asPrefixContext, typePrinting: .withColon, hasName: true, extraName: extraName)
        case .subscript: return printEntity(n, asPrefixContext: asPrefixContext, typePrinting: .withColon, hasName: false, extraName: extraName, extraIndex: nil, overwriteName: "subscript")
        default: return nil
        }
    }

    private mutating func printEntityType(name: SomeNode, type: SomeNode, genericFunctionTypeList: SomeNode?) {
        let labelList = name.children.first(where: { $0.kind == .labelList })
        if labelList != nil || genericFunctionTypeList != nil {
            if let gftl = genericFunctionTypeList {
                printChildren(gftl, prefix: "<", suffix: ">", separator: ", ")
            }
            var t = type
            if type.kind == .dependentGenericType {
                if genericFunctionTypeList == nil {
                    _ = printOptional(type.children.first)
                }
                if let dt = type.children.at(1) {
                    if dt.needSpaceBeforeType {
                        target.write(" ")
                    }
                    if let first = dt.children.first {
                        t = first
                    }
                }
            }
            printFunctionType(labelList: labelList, t)
        } else {
            _ = printName(type)
        }
    }

    /// Mirrors upstream NodePrinter::shouldShowEntityType: a closure's type
    /// signature is only printed when `showClosureSignature` is set (it is
    /// otherwise uniquely identified by its index + parent).
    private func shouldShowEntityType(entityKind: Node.Kind) -> Bool {
        switch entityKind {
        case .explicitClosure, .implicitClosure:
            return options.contains(.showClosureSignature)
        default:
            return true
        }
    }

    private mutating func printEntity(_ name: SomeNode, asPrefixContext: Bool, typePrinting: TypePrinting, hasName: Bool, extraName: String? = nil, extraIndex: UInt64? = nil, overwriteName: String? = nil) -> SomeNode? {
        var genericFunctionTypeList: SomeNode?
        var name = name
        if name.kind == .boundGenericFunction, let first = name.children.at(0), let second = name.children.at(1) {
            name = first
            genericFunctionTypeList = second
        }

        let localName = hasName && name.children.at(1)?.kind == .localDeclName
        let multiWordName = extraName?.contains(" ") == true || (localName && options.contains(.displayLocalNameContexts))
        if asPrefixContext && (typePrinting != .noType || multiWordName) {
            return name
        }

        guard let context = name.children.first else { return nil }
        var postfixContext: SomeNode?
        if shouldPrintContext(context) {
            if multiWordName {
                postfixContext = context
            } else {
                let currentPos = target.count
                postfixContext = printName(context, asPrefixContext: true)
                if target.count != currentPos {
                    // A module→type dot stays inside the current type's scope
                    // so a fully-qualified name selects as one span; a nested
                    // type's separator dot joins two independently navigable
                    // spans, so emit it under a barrier instead of fusing it
                    // onto this leaf's span.
                    if context.kind == .module {
                        target.write(".")
                    } else {
                        target.pushTypeReferenceScope(nil)
                        target.write(".")
                        target.popTypeReferenceScope()
                    }
                }
            }
        }

        var extraNameConsumed = extraName == nil
        if hasName || overwriteName != nil {
            if !extraNameConsumed, multiWordName {
                target.write(extraName ?? "")
                if let extraIndex {
                    target.write("\(extraIndex)")
                }
                target.write(" of ")
                extraNameConsumed = true
            }
            let currentPos = target.count
            if let o = overwriteName {
                target.write(o)
            } else {
                if let one = name.children.at(1) {
                    if one.kind != .privateDeclName {
                        if one.kind == .identifier {
                            printIdentifier(one, parentKind: name.kind)
                        } else {
                            _ = printName(one)
                        }
                    }
                    if let pdn = name.children.first(where: { $0.kind == .privateDeclName }) {
                        _ = printName(pdn)
                    }
                }
            }
            if target.count != currentPos, !extraNameConsumed {
                target.write(".")
            }
        }
        if !extraNameConsumed {
            target.write(extraName ?? "")
            if let ei = extraIndex {
                target.write("\(ei)")
            }
        }
        if typePrinting != .noType {
            guard var type = name.children.first(where: { $0.kind == .type }) else { return nil }
            if type.kind != .type {
                guard let nextType = name.children.at(2) else { return nil }
                type = nextType
            }
            guard type.kind == .type, let firstChild = type.children.first else { return nil }
            type = firstChild
            var typePr = typePrinting
            if typePr == .functionStyle {
                var t = type
                while t.kind == .dependentGenericType, let next = t.children.at(1)?.children.at(0) {
                    t = next
                }
                switch t.kind {
                case .functionType,
                     .noEscapeFunctionType,
                     .uncurriedFunctionType,
                     .cFunctionPointer,
                     .thinFunctionType: break
                default: typePr = .withColon
                }
            }
            if typePr == .withColon {
                if options.contains(.displayEntityTypes) {
                    target.write(" : ")
                    printEntityType(name: name, type: type, genericFunctionTypeList: genericFunctionTypeList)
                }
            } else if shouldShowEntityType(entityKind: name.kind) {
                if multiWordName || type.needSpaceBeforeType {
                    target.write(" ")
                }
                printEntityType(name: name, type: type, genericFunctionTypeList: genericFunctionTypeList)
            }
        }
        if !asPrefixContext, let pfc = postfixContext, !localName || options.contains(.displayLocalNameContexts) {
            switch name.kind {
            case .defaultArgumentInitializer,
                 .initializer,
                 .propertyWrapperBackingInitializer,
                 .propertyWrapperInitFromProjectedValue,
                 .propertyWrappedFieldInitAccessor:
                target.write(" of ")
            default:
                target.write(" in ")
            }
            _ = printName(pfc)
            return nil
        }
        return postfixContext
    }

    private mutating func printSpecializationPrefix(_ name: SomeNode, description: String, paramPrefix: String = "") {
        if !options.contains(.displayGenericSpecializations) {
            // Counted here, not on entry: the counter exists to mark fragments
            // whose rendering *consulted the latch* (its own doc comment says
            // so), and the latch is read nowhere else. `.default` contains
            // `.displayGenericSpecializations`, so bumping it on entry moved the
            // counter on a path that never touches the latch, and `printName`'s
            // cache-write guard then failed for this node and every ancestor up
            // to the root. `truncationCount`, the sibling counter, already sits
            // inside its branch (PR #7 review, finding 2).
            specializationPrefixVisitCount += 1
            if !specializationPrefixPrinted {
                if name.children.first?.kind == .representationChanged {
                    target.write("representation changed of ")
                } else {
                    target.write("specialized ")
                }
                specializationPrefixPrinted = true
            }
            return
        }
        target.write("\(description) <")
        var separator = ""
        var argNum = 0
        for c in name.children {
            switch c.kind {
            case .specializationPassID,
                 .droppedArgument,
                 .representationChanged: break
            case .isSerialized:
                target.write(separator)
                separator = ", "
                _ = printName(c)
            default:
                if !c.children.isEmpty {
                    target.write(separator)
                    target.write(paramPrefix)
                    separator = ", "
                    switch c.kind {
                    case .functionSignatureSpecializationParam:
                        target.write("Arg[\(argNum)] = ")
                        printFunctionSignatureSpecializationParam(c)
                    case .functionSignatureSpecializationReturn:
                        target.write("Return = ")
                        printFunctionSignatureSpecializationParam(c)
                    default:
                        _ = printName(c)
                    }
                }
                argNum += 1
            }
        }
        target.write("> of ")
    }

    private mutating func printFunctionParameters(labelList: SomeNode?, parameterType: SomeNode, showTypes: Bool) {
        guard parameterType.kind == .argumentTuple else { return }
        guard let t = parameterType.children.first, t.kind == .type else { return }
        guard let parameters = t.children.first else { return }

        if parameters.kind != .tuple {
            if showTypes {
                target.write("(")
                _ = printName(parameters)
                target.write(")")
            } else {
                target.write("(_:)")
            }
            return
        }

        target.write("(")
        for tuple in parameters.children.enumerated() {
            if let label = labelList?.children.at(tuple.offset) {
                target.write(label.kind == .identifier ? (label.text ?? "") : "_", context: .context(for: parameterType.materializedNode, state: .printFunctionParameters))
                target.write(":")
                if showTypes {
                    target.write(" ")
                }
            } else if !showTypes {
                if let label = tuple.element.children.first(where: { $0.kind == .tupleElementName }) {
                    target.write(label.text ?? "", context: .context(for: parameterType.materializedNode, state: .printFunctionParameters))
                    target.write(":")
                } else {
                    target.write("_", context: .context(for: parameterType.materializedNode, state: .printFunctionParameters))
                    target.write(":")
                }
            }

            if showTypes {
                _ = printName(tuple.element)
                if tuple.offset != parameters.children.count - 1 {
                    target.write(", ")
                }
            }
        }
        target.write(")")
    }

    private mutating func printConventionWithMangledCType(_ name: SomeNode, label: String) {
        target.write("@convention(\(label)")
        if let firstChild = name.children.first, firstChild.kind == .clangType {
            target.write(", mangledCType: \"")
            _ = printName(firstChild)
            target.write("\"")
        }
        target.write(") ")
    }

    private mutating func printFunctionType(labelList: SomeNode? = nil, _ name: SomeNode) {
        switch name.kind {
        case .autoClosureType,
             .escapingAutoClosureType: target.write("@autoclosure ")
        case .thinFunctionType: target.write("@convention(thin) ")
        case .cFunctionPointer:
            printConventionWithMangledCType(name, label: "c")
        case .escapingObjCBlock:
            target.write("@escaping ")
            fallthrough
        case .objCBlock:
            printConventionWithMangledCType(name, label: "block")
        default: break
        }

        let argIndex = name.children.count - 2
        var startIndex = 0
        var isSendable = false
        var isAsync = false
        var hasSendingResult = false
        var diffKind = UnicodeScalar(0)
        if name.children.at(startIndex)?.kind == .clangType {
            startIndex += 1
        }
        if name.children.at(startIndex)?.kind == .sendingResultFunctionType {
            startIndex += 1
            hasSendingResult = true
        }
        if name.children.at(startIndex)?.kind == .isolatedAnyFunctionType {
            _ = printOptional(name.children.at(startIndex))
            startIndex += 1
        }
        var nonIsolatedCallerNode: SomeNode?
        if name.children.at(startIndex)?.kind == .nonIsolatedCallerFunctionType {
            nonIsolatedCallerNode = name.children.at(startIndex)
            startIndex += 1
        }
        if name.children.at(startIndex)?.kind == .globalActorFunctionType {
            _ = printOptional(name.children.at(startIndex))
            startIndex += 1
        }
        if name.children.at(startIndex)?.kind == .differentiableFunctionType {
            // Same narrowing trap as `printDifferentiableFunctionType`; an
            // index that names no differentiability leaves `diffKind` at its
            // initial scalar, which the switch below already ignores.
            diffKind = Differentiability(name.children.at(startIndex)?.index ?? 0)?.rawValue ?? UnicodeScalar(0)
            startIndex += 1
        }
        var thrownErrorNode: SomeNode?
        if name.children.at(startIndex)?.kind == .throwsAnnotation || name.children.at(startIndex)?.kind == .typedThrowsAnnotation {
            thrownErrorNode = name.children.at(startIndex)
            startIndex += 1
        }
        if name.children.at(startIndex)?.kind == .concurrentFunctionType {
            startIndex += 1
            isSendable = true
        }
        if name.children.at(startIndex)?.kind == .asyncAnnotation {
            startIndex += 1
            isAsync = true
        }

        switch diffKind {
        case "f": target.write("@differentiable(_forward) ")
        case "r": target.write("@differentiable(reverse) ")
        case "l": target.write("@differentiable(_linear) ")
        case "d": target.write("@differentiable ")
        default: break
        }

        if let nonIsolatedCallerNode {
            _ = printName(nonIsolatedCallerNode)
        }

        if isSendable {
            target.write("@Sendable ")
        }

        guard let parameterType = name.children.at(argIndex) else { return }
        printFunctionParameters(labelList: labelList, parameterType: parameterType, showTypes: options.contains(.showFunctionArgumentTypes))
        if !options.contains(.showFunctionArgumentTypes) {
            return
        }
        if isAsync {
            target.write(" async")
        }
        if let thrownErrorNode {
            _ = printName(thrownErrorNode)
        }
        target.write(" -> ")
        if hasSendingResult {
            target.write("sending ")
        }

        _ = printOptional(name.children.at(argIndex + 1))
    }

    private mutating func printBoundGenericNoSugar(_ name: SomeNode) {
        guard let typeList = name.children.at(1) else { return }
        printFirstChild(name)
        guard !options.contains(.removeBoundGeneric) else { return }
        printChildren(typeList, prefix: "<", suffix: ">", separator: ", ")
    }

    /// The one recursion in this engine that does not pass back through
    /// ``printName(_:asPrefixContext:)``, so it carries its own bound: it walks
    /// single-child `.type` wrappers, which a well-formed tree never nests
    /// deeply, but a malformed one could.
    private func findSugar(_ name: SomeNode, depth: Int = 0) -> SugarType {
        guard depth <= Self.maxSugarWrapperDepth else { return .none }
        guard let firstChild = name.children.at(0) else { return .none }
        if name.children.count == 1, firstChild.kind == .type { return findSugar(firstChild, depth: depth + 1) }

        guard name.kind == .boundGenericEnum || name.kind == .boundGenericStructure else { return .none }
        guard let secondChild = name.children.at(1) else { return .none }
        guard name.children.count == 2 else { return .none }

        guard let unboundType = firstChild.children.first, unboundType.children.count > 1 else { return .none }
        let typeArgs = secondChild

        let c0 = unboundType.children.at(0)
        let c1 = unboundType.children.at(1)

        if name.kind == .boundGenericEnum {
            if c1?.isIdentifier(desired: "Optional") == true && typeArgs.children.count == 1 && c0?.isSwiftModule == true {
                return .optional
            }
            if c1?.isIdentifier(desired: "ImplicitlyUnwrappedOptional") == true && typeArgs.children.count == 1 && c0?.isSwiftModule == true {
                return .implicitlyUnwrappedOptional
            }
            return .none
        }
        if c1?.isIdentifier(desired: "Array") == true && typeArgs.children.count == 1 && c0?.isSwiftModule == true {
            return .array
        }
        if c1?.isIdentifier(desired: "Dictionary") == true && typeArgs.children.count == 2 && c0?.isSwiftModule == true {
            return .dictionary
        }
        return .none
    }

    private mutating func printBoundGeneric(_ name: SomeNode) {
        guard name.children.count >= 2 else { return }
        guard name.children.count == 2, options.contains(.synthesizeSugarOnTypes), name.kind != .boundGenericClass else {
            printBoundGenericNoSugar(name)
            return
        }

        if name.kind == .boundGenericProtocol {
            _ = printOptional(name.children.at(1))
            _ = printOptional(name.children.at(0), prefix: " as ")
            return
        }

        let sugarType = findSugar(name)
        switch sugarType {
        case .optional,
             .implicitlyUnwrappedOptional:
            if let type = name.children.at(1)?.children.at(0) {
                let needParens = !type.isSimpleType
                _ = printOptional(type, prefix: needParens ? "(" : "", suffix: needParens ? ")" : "")
                target.write(sugarType == .optional ? "?" : "!")
            }
        case .array,
             .dictionary:
            _ = printOptional(name.children.at(1)?.children.at(0), prefix: "[")
            if sugarType == .dictionary {
                _ = printOptional(name.children.at(1)?.children.at(1), prefix: " : ")
            }
            target.write("]")
        default: printBoundGenericNoSugar(name)
        }
    }

    private enum PrintImplFunctionTypeState: Int { case attrs, inputs, results }
    private mutating func printImplFunctionType(_ name: SomeNode) {
        var curState: PrintImplFunctionTypeState = .attrs
        var patternSubs: SomeNode?
        var invocationSubs: SomeNode?
        var sendingResult: SomeNode?
        let transitionTo = { (printer: inout Self, newState: PrintImplFunctionTypeState) in
            while curState != newState {
                switch curState {
                case .attrs:
                    if let patternSubs {
                        printer.printFirstChild(patternSubs, prefix: "@substituted ", suffix: " ")
                    }
                    printer.target.write("(")
                case .inputs:
                    printer.target.write(") -> ")
                    if let sendingResult {
                        _ = printer.printName(sendingResult)
                        printer.target.write(" ")
                    }
                    printer.target.write("(")
                case .results: break
                }
                guard let nextState = PrintImplFunctionTypeState(rawValue: curState.rawValue + 1) else { break }
                curState = nextState
            }
        }
        childLoop: for c in name.children {
            if c.kind == .implParameter {
                if curState == .inputs {
                    target.write(", ")
                }
                transitionTo(&self, .inputs)
                _ = printName(c)
            } else if c.kind == .implResult || c.kind == .implYield || c.kind == .implErrorResult {
                if curState == .results {
                    target.write(", ")
                }
                transitionTo(&self, .results)
                _ = printName(c)
            } else if c.kind == .implPatternSubstitutions {
                patternSubs = c
            } else if c.kind == .implInvocationSubstitutions {
                invocationSubs = c
            } else if c.kind == .implSendingResult {
                sendingResult = c

            } else {
                _ = printName(c)
                target.write(" ")
            }
        }
        transitionTo(&self, .results)
        target.write(")")
        if let patternSubs, let second = patternSubs.children.at(1) {
            printChildren(second, prefix: " for <", suffix: ">")
        }
        if let invocationSubs, let second = invocationSubs.children.at(0) {
            printChildren(second, prefix: " for <", suffix: ">")
        }
    }

    private mutating func quotedString(_ value: String) {
        target.write("\"")
        for c in value.unicodeScalars {
            switch c {
            case "\\": target.write("\\\\")
            case "\t": target.write("\\t")
            case "\n": target.write("\\n")
            case "\r": target.write("\\r")
            case "\"": target.write("\\\"")
            case "\0": target.write("\\0")
            default:
                if c < UnicodeScalar(0x20) || c == UnicodeScalar(0x7F) {
                    target.write("\\x")
                    target.write(String(describing: ((c.value >> 4) > 9) ? UnicodeScalar(c.value + UnicodeScalar("A").value) : UnicodeScalar(c.value + UnicodeScalar("0").value)))
                } else {
                    target.write(String(c))
                }
            }
        }
        target.write("\"")
    }
}

/// Prints a `Node` tree to `Target`.
///
/// A thin, source-compatible facade over `DemanglingPrinter<Target, Node>`.
/// The printing logic lives in the generic engine so it can also print
/// `NodeReference` trees straight from a `NodeStore` without materializing
/// a class tree (see `NodeReference.print(using:)`).
public enum NodePrinter<Target: NodePrinterTarget> {
    /// Mirrors ``swift::Demangle::NodePrinter::MaxDepth``; see
    /// `DemanglingPrinter.maxPrintDepth` for the calibration.
    public static var maxPrintDepth: Int { DemanglingPrinter<Target, Node>.maxPrintDepth }

    /// Prints `root` into a fresh `Target` on a stack large enough for real
    /// symbols.
    ///
    /// This is the only public way to run the walk: it routes through
    /// `StackSafeExecutor`, so the depth a tree survives does not depend on
    /// how much stack the calling thread happens to have left.
    public static func print(_ root: Node, using options: DemangleOptions = .default) -> Target {
        DemanglingPrinter<Target, Node>.print(root, options: options)
    }
}
