import Foundation

public protocol Longrunable {
    associatedtype ResultType

    func start(with completionClosure: @escaping (Result<ResultType, Error>) -> Void)
    func cancel()
}

public final class AnyLongrun<T>: Longrunable {
    public typealias ResultType = T

    private let privateStart: (@escaping (Result<ResultType, Error>) -> Void) -> Void
    private let privateCancel: () -> Void

    public init<U: Longrunable>(longrun: U) where U.ResultType == ResultType {
        privateStart = longrun.start
        privateCancel = longrun.cancel
    }

    public func start(with completionClosure: @escaping (Result<T, Error>) -> Void) {
        privateStart(completionClosure)
    }

    public func cancel() {
        privateCancel()
    }
}
