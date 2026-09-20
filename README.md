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
| `performRead(_:completion:)` | reader | One-shot read that may overlap the writer and other reads. Return plain values only: in `.concurrent` mode the reader context is gone when the completion runs. A read must not mutate: a change left on the context is rolled back and the read fails with `readLeftChanges`, in every mode. |
| `performObserve(block:)` | observer | Long-lived observation (fetched results controllers, change observers). Never reset while open. |
| `performAsync(block:)` | writer | Legacy entry point; the block owns `save()` / `rollback()`. |
| `performWithObserver(block:)` | writer | Delivers the writer and the observer context together, for components that register for the writer's saves and resolve them on the observer. |

`CoreDataRepository` routes fetches to `performRead` and saves to `performWrite`. `CoreDataContextObservable`
reduces the writer's did-save payload to object identifiers; persistent-history re-posts from other processes
take the same path. In `.concurrent` mode it then maps on the separate observer context, so a save never waits
for mapping. In `.serial` mode the observer is the writer, so mapping runs inline inside the save — deferring
it there would only expose changes the writer commits later.

Because that hop is asynchronous, an observable delivers the row's committed state at delivery time rather than
a snapshot of the commit that triggered it. Every delivered state is a committed one and the last delivery always
reflects the last commit, but back-to-back saves may coalesce intermediate states. Each delivered change is
derived from the current row, not from the notification's category:

A row the mapper cannot read is dropped from the batch rather than failing it, and reported through the
configured `logger` — a silent drop looks exactly like "nothing relevant changed".

- the row exists and matches the predicate: `insert` or `update`;
- the row does not match the predicate: skipped;
- the row is gone: skipped, because the save that removed it delivers the `delete` itself.

A row that does not match is skipped rather than reported as a `delete`, as in 2.x. The payload is filtered by
entity alone and the predicate only sees the post-change row, so an observable cannot tell a row that *left* its
set from one that was never in it — reporting a `delete` for both would wake every observable sharing the entity
on every save. The consequence is that a subscriber holding a predicate-filtered collection keeps an item that
has since stopped matching until it refetches. If you need to be told when a row leaves the set, observe without
a predicate and filter on your side.

The one exception is a delete from **another process**: a tombstone cannot be evaluated against the predicate, so
those are delivered for any row of the entity.

Consumers that need every intermediate state must observe the writer directly.

An observable follows the store across a `close()` and the reopen that follows: the service hands its new
contexts to every running observable as it opens, before the work that triggered the open is enqueued, so no
change is missed in the handover. Three details that are not obvious:

- only an observable that is **currently started** follows the store. One that was never started, or was
  stopped, stays out — reopening the store does not silently bring it back to life;
- `stop()` is final until an explicit `start()`, and it no longer goes through the service, so it neither
  opens a closed store to unregister from nor fails while a `close()` is draining. Its completion runs on the
  caller's thread rather than on a context queue;
- a `start()` that **failed** — during a close drain, for instance — is not armed for the next open. Retry it.

Unsubscribing does not fence deliveries already in flight. In `.serial` mode a change is queued for delivery
inside the save that produced it, before any write completion runs, so a completion that calls `removeObserver`
still receives the change it is reacting to. In `.concurrent` mode resolution hops to the observer context
first, so a change committed just before the removal may land on either side of it — the last delivery before
an unsubscribe is not guaranteed. Re-subscribing recovers it: `StreamableProvider` refetches on `addObserver`
and delivers current state as inserts.

Rows deleted by another process are gone by the time their history is replayed, so their identifiers come from
persistent-history tombstones. Mark the identifier attribute with **Preserve After Deletion** in the model editor
(`preserveAfterDeletion="YES"`) for remote deletes to reach observers; without it only remote inserts and updates
are delivered.

Set `logger` on the configuration to be told when that is missing, rather than discovering it from absent deletes:
`CoreDataContextObservable.start()` warns once if the observed entity's identifier attribute is not preserved, and
the history observer warns when a replayed transaction contains deletes it cannot identify. Both are warnings, not
errors — a store that never sees cross-process deletes works fine without the flag. The start-time check addresses
entities by class name like the rest of the library, so it cannot run on a model whose entity names differ from its
class names; the history-observer warning still covers that case.

`close()` detaches the store, then drains queued reads, writes and observer work with the lock released, so a
completion or observer that calls back into the service cannot deadlock it. A read's *completion* may close the
service — it is already finished with the reading context. A read's *block* may not: it still holds the store
that the close would wait for, so such a call is rejected with `closeFromReadBlock`. The flip side is that
`close()` waits for reads to release the store rather than for their completions to run, so a read completion
may still be pending when it returns. That completion no longer touches the store, so a following `drop()` is
still safe.

While a `close()` is draining the service is neither open nor closed. Work arriving in that window is rejected
with `closeInProgress` rather than opening a second store on the same file, a second `close()` is rejected the
same way rather than reporting success over a drain that is still running, and `drop()` is rejected because the
file is still in use. Work arriving after `close()` returns opens the store again on demand.

Conformers of `CoreDataServiceProtocol` that only implement `performAsync`, `close` and `drop` get
`performWrite`, `performRead`, `performObserve` and `performWithObserver` from protocol defaults with `.serial`
semantics.

## Author

ERussel, emkil.russel@gmail.com

## License

Operation-iOS is available under the Apache 2.0 license. See the LICENSE file for more info.
