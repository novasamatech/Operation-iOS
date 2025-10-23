import Foundation

public func dispatchInQueueWhenPossible(
    _ queue: DispatchQueue?,
    locking mutex: NSLock? = nil,
    block: @escaping () -> Void
) {
    if let queue {
        queue.async {
            mutex?.lock()
            block()
            mutex?.unlock()
        }
    } else {
        mutex?.lock()
        block()
        mutex?.unlock()
    }
}

public func callbackClosureIfProvided<T>(
    _ closure: ((Result<T, Error>) -> Void)?,
    queue: DispatchQueue?,
    result: Result<T, Error>
) {
    guard let closure else {
        return
    }

    dispatchInQueueWhenPossible(queue) {
        closure(result)
    }
}
