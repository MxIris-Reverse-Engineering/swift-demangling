import Foundation

public enum RequiredError: Error {
    case requiredNonOptional
    case requiredConditionTrue
}

public func required<T>(_ optional: T?, error: Error? = nil) throws -> T {
    guard let optional else { throw error ?? RequiredError.requiredNonOptional }
    return optional
}

public func required(_ condition: Bool) throws {
    guard condition else { throw RequiredError.requiredConditionTrue }
}
