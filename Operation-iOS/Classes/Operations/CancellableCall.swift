import Foundation

/**
 *  Abstract protocol designed to provide identity and cancellation support
 *  for asynchronious work.
 *
 *  Use the protocol to return from methods that schedules cancellable work.
 */

public protocol CancellableCall: AnyObject {
    /**
     *  Cancels all operations related to call
     */

    func cancel()
}
