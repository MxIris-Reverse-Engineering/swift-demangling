enum SpecializationPass: CaseIterable, Sendable {
    case allocBoxToStack
    case closureSpecializer
    case capturePromotion
    case capturePropagation
    case functionSignatureOpts
    case genericSpecializer
    case moveDiagnosticInOutToOut
    case asyncDemotion
    case packSpecialization
    case embeddedWitnessCallSpecialization
}
