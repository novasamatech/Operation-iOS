import Foundation

public final class LongrunOperation<T>: BaseOperation<T> {
    let longrun: AnyLongrun<T>

    public init(longrun: AnyLongrun<T>) {
        self.longrun = longrun
    }

    public override func performAsync(
        _ callback: @escaping (Result<T, Error>) -> Void
    ) throws {
        longrun.start(with: callback)
    }

    public override func cancel() {
        longrun.cancel()

        super.cancel()
    }
}
