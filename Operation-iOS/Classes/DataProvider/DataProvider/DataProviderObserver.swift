import Foundation

public struct DataProviderObserver<T, P> {
    public private(set) weak var observer: AnyObject?
    public private(set) var queue: DispatchQueue?
    public private(set) var updateBlock: ([DataProviderChange<T>]) -> Void
    public private(set) var failureBlock: (Error) -> Void
    public private(set) var options: P

    public init(observer: AnyObject,
                queue: DispatchQueue?,
                updateBlock: @escaping ([DataProviderChange<T>]) -> Void,
                failureBlock: @escaping (Error) -> Void,
                options: P) {

        self.observer = observer
        self.options = options
        self.queue = queue
        self.updateBlock = updateBlock
        self.failureBlock = failureBlock
    }
}

struct DataProviderPendingObserver<T> {
    private(set) weak var observer: AnyObject?
    private(set) var operation: BaseOperation<T>?

    init(observer: AnyObject, operation: BaseOperation<T>) {
        self.observer = observer
        self.operation = operation
    }
}

/**
 *  Changes that arrived while an observer's snapshot was being fetched. Holding them here rather than
 *  dropping them is what closes the window between reading the snapshot and registering the observer:
 *  they are folded into the snapshot when the observer is delivered.
 *
 *  One buffer per pending observer, never a shared one: a change is newer than the snapshot only of an
 *  observer that was already waiting when it arrived.
 *
 *  Data changes only. A refresh that produced nothing, and a failed synchronization, are signals about an
 *  event the joining observer did not witness and are not replayed to it.
 */
final class DataProviderPendingChanges<T> {
    private(set) weak var observer: AnyObject?
    var changes: [DataProviderChange<T>] = []

    init(observer: AnyObject) {
        self.observer = observer
    }
}
