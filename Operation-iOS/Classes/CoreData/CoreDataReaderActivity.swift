import Foundation

/**
 *  Tracks the reads that are currently holding the store, so ```CoreDataService.close()``` can wait for the
 *  store to fall idle rather than for the reader queue to empty.
 *
 *  The two are not the same. A reader operation outlives the read: its completion runs after the reading
 *  context is finished with, and that completion is expected to call back into the service — to close it, or
 *  to issue another read. Waiting on the queue would wait for those completions too, so a completion that
 *  closes the service would wait for itself. Waiting on this counter waits only for the part that actually
 *  touches the store.
 *
 *  A read is counted from the moment it is enqueued, under the service lock, so a ```close()``` that reaches
 *  the lock next still waits for reads whose operation has not started yet.
 */

final class CoreDataReaderActivity {
    private let condition = NSCondition()
    private var inFlight = 0

    private static let threadKey = "io.novasama.coredata.reader.depth"

    /// ```true``` while the calling thread is executing a read block. A blocking ```close()``` on such a
    /// thread could only wait for the read it is running on, so it is reported instead.
    static var isReadingOnCurrentThread: Bool {
        ((Thread.current.threadDictionary[threadKey] as? Int) ?? 0) > 0
    }

    /// Marks the executing thread as reading for the duration of ```body```.
    static func markingCurrentThread<T>(_ body: () -> T) -> T {
        let dictionary = Thread.current.threadDictionary
        let depth = (dictionary[threadKey] as? Int) ?? 0

        dictionary[threadKey] = depth + 1

        defer {
            if depth > 0 {
                dictionary[threadKey] = depth
            } else {
                dictionary.removeObject(forKey: threadKey)
            }
        }

        return body()
    }

    /// Counts a read that is about to take the store. Must be balanced by ```leave()```.
    func enter() {
        condition.lock()
        inFlight += 1
        condition.unlock()
    }

    /// Reports that a read is finished with the store. Its completion may still be pending.
    func leave() {
        condition.lock()

        inFlight -= 1

        if inFlight == 0 {
            condition.broadcast()
        }

        condition.unlock()
    }

    /// Blocks until no read is holding the store. Never call from a thread that is itself reading.
    func waitUntilIdle() {
        condition.lock()

        while inFlight > 0 {
            condition.wait()
        }

        condition.unlock()
    }
}
