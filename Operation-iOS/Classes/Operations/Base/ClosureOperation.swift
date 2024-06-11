import Foundation

/**
 *  Subclass of the ```BaseOperation``` designed to execute external closure
 *  to produce operation result.
 *
 *  Operation does nothing if result is set when operation starts.
 */

public final class ClosureOperation<ResultType>: BaseOperation<ResultType> {

    /// Closure to execute to produce operation result.
    public let closure: () throws -> ResultType

    /**
     *  Create closure operation.
     *
     *  - parameters:
     *    - closure: Closure to execute to produce operation result.
     */

    public init(closure: @escaping () throws -> ResultType) {
        self.closure = closure
    }

    override public func performAsync(_ callback: @escaping (Result<ResultType, Error>) -> Void) throws {
        let result = try closure()
        callback(.success(result))
    }
}
