## Example

To run the example project, clone the repo, and run `pod install` from the Example directory first.

## Installation

```ruby
pod 'Operation-iOS', :git => 'https://github.com/novasamatech/Operation-iOS.git', :tag => '1.0.0'
```

## Core Data concurrency modes

`CoreDataServiceConfiguration` takes a `concurrencyMode` (default `.serial`):

- `.serial` — one private-queue context serves reads, writes and observation, as in 2.x. Change
  delivery follows the rules below in both modes.
- `.concurrent(readerConcurrency:)` — a dedicated writer context, an observer context that merges every
  writer save automatically (`automaticallyMergesChangesFromParent`), and short-lived reader contexts
  created per read, at most `readerConcurrency` at a time.

`CoreDataServiceProtocol` exposes one entry point per role:

| Entry point | Context | Contract |
|---|---|---|
| `performWrite(_:completion:)` | writer | One transaction: saved when the block leaves changes, rolled back when it throws. Serialized in call order. |
| `performRead(_:completion:)` | reader | One-shot read that may overlap the writer and other reads. Changes left on the context are discarded. Return plain values only: in `.concurrent` mode the reader context is gone when the completion runs, and the completion runs on the reader's queue. |
| `performObserve(block:)` | observer | Long-lived observation (fetched results controllers, change observers). Never reset while open. |
| `performAsync(block:)` | writer | Legacy entry point; the block owns `save()` / `rollback()`. |
| `performWithObserver(block:)` | writer | Delivers the writer and the observer context together, for components that register for the writer's saves and resolve them on the observer. |

`CoreDataRepository` routes fetches to `performRead` and saves to `performWrite`. `CoreDataContextObservable`
reduces the writer's did-save payload to object identifiers and maps on the observer context, so a save never
waits for mapping; persistent-history re-posts from other processes take the same path.

Because that hop is asynchronous, an observable delivers the row's committed state at delivery time rather than
a snapshot of the commit that triggered it. Every delivered state is a committed one and the last delivery always
reflects the last commit, but back-to-back saves may coalesce intermediate states. Each delivered change is
derived from the current row, not from the notification's category:

- the row exists and matches the predicate: `insert` or `update`;
- an updated row no longer matches the predicate: `delete`, so a subscriber does not keep a stale item;
- the row is gone: skipped, because the save that removed it delivers the `delete` itself.

Consumers that need every intermediate state must observe the writer directly.

Rows deleted by another process are gone by the time their history is replayed, so their identifiers come from
persistent-history tombstones. Mark the identifier attribute with **Preserve After Deletion** in the model editor
(`preserveAfterDeletion="YES"`) for remote deletes to reach observers; without it only remote inserts and updates
are delivered.

`close()` detaches the store, then drains queued reads, writes and observer work with the lock released, so a
completion or observer that calls back into the service cannot deadlock it. Work arriving during or after
`close()` opens the store again on demand.

Conformers of `CoreDataServiceProtocol` that only implement `performAsync`, `close` and `drop` get
`performWrite`, `performRead`, `performObserve` and `performWithObserver` from protocol defaults with `.serial`
semantics.

## Author

ERussel, emkil.russel@gmail.com

## License

Operation-iOS is available under the Apache 2.0 license. See the LICENSE file for more info.
