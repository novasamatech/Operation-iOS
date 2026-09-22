import Foundation

/**
 *  Protocol that describes any unique identifiable instance.
 */

public protocol Identifiable {

    /// Unique identifier of the instance.

    var identifier: String { get }
}

/**
 *  Enum is designed to store changes introduced by data provider.
 */

public enum DataProviderChange<T> {
    /// New items has been added.
    /// Item is passed as associated value.
    case insert(newItem: T)

    /// Existing item has been updated
    /// Item is passed as associated value.
    case update(newItem: T)

    /// Existing item has been removed.
    /// Identifier of the item is passed as associated value.
    case delete(deletedIdentifier: String)

    /// Returns item if bounded as associated value.

    var item: T? {
        switch self {
        case .insert(let newItem):
            return newItem
        case .update(let newItem):
            return newItem
        default:
            return nil
        }
    }
}

extension DataProviderChange {
    /**
     *  Collapses changes that arrived while a single value's snapshot was being fetched: the last of them
     *  is the state at the moment the observer was registered. A value deleted inside that window is
     *  delivered as nothing at all, the way an observer registered after the delete would see it.
     *
     *  Only changes newer than the snapshot may be passed.
     */
    static func reconcile(snapshot: T?, with changes: [DataProviderChange<T>]) -> [DataProviderChange<T>] {
        guard let latest = changes.last else {
            return snapshot.map { [DataProviderChange<T>.insert(newItem: $0)] } ?? []
        }

        switch latest {
        case .insert(let item), .update(let item):
            return [DataProviderChange<T>.insert(newItem: item)]
        case .delete:
            return []
        }
    }
}

extension DataProviderChange where T: Identifiable {
    /**
     *  Folds changes that arrived while ```snapshot``` was being fetched into it, so a joining observer's
     *  first delivery is the state at the moment it was registered rather than at the moment the snapshot
     *  was read: one insert per live item, nothing for an item that came and went inside that window, and
     *  no duplicate for an item the snapshot already carried.
     *
     *  Only changes newer than the snapshot may be passed. An item the snapshot did not carry joins at the
     *  end, where it would have arrived had it been delivered as its own change.
     */
    static func reconcile(snapshot: [T], with changes: [DataProviderChange<T>]) -> [DataProviderChange<T>] {
        guard !changes.isEmpty else {
            return snapshot.map { DataProviderChange<T>.insert(newItem: $0) }
        }

        var identifiers = snapshot.map { $0.identifier }
        var itemsByIdentifier = snapshot.reduce(into: [String: T]()) { $0[$1.identifier] = $1 }

        for change in changes {
            switch change {
            case .insert(let item), .update(let item):
                if itemsByIdentifier[item.identifier] == nil {
                    identifiers.append(item.identifier)
                }

                itemsByIdentifier[item.identifier] = item
            case .delete(let identifier):
                if itemsByIdentifier.removeValue(forKey: identifier) != nil {
                    identifiers.removeAll { $0 == identifier }
                }
            }
        }

        return identifiers.compactMap { itemsByIdentifier[$0] }
            .map { DataProviderChange<T>.insert(newItem: $0) }
    }
}

/**
 *  Struct designed to store options needed to describe how an observer should be handled by data provider.
 */

public struct DataProviderObserverOptions {
    /// Asks data provider to notify observer in any case after synchronization completes.
    /// If this value is `false` (default value) then observer is only notified when
    /// there are changes after synchronization.
    public var alwaysNotifyOnRefresh: Bool

    /// Asks data provider to wait until any in progress synchronization completes before reading the
    /// snapshot a new observer is given.
    /// By default the value is `true`.
    /// - note: This is a freshness knob, not a correctness one: a synchronization that commits while an
    /// observer is being added is buffered and folded into its first delivery either way. Passing `false`
    /// may significantly improve performance, at the cost of an observer's first delivery being a state
    /// the in progress synchronization is about to supersede.
    public var waitsInProgressSyncOnAdd: Bool

    /// - parameters:
    ///    - alwaysNotifyOnRefresh: Asks data provider to notify observer in any case after synchronization completes.
    ///    Default value is `false`.
    ///
    ///    - waitsInProgressSyncOnAdd: Asks data provider to wait until any in progress synchronization
    ///    completes before reading the snapshot a new observer is given. Default value is `true`. Passing
    ///    `false` may significantly improve performance, at the cost of a first delivery that an in
    ///    progress synchronization is about to supersede; no change is lost either way.

    public init(alwaysNotifyOnRefresh: Bool = false,
                waitsInProgressSyncOnAdd: Bool = true) {
        self.alwaysNotifyOnRefresh = alwaysNotifyOnRefresh
        self.waitsInProgressSyncOnAdd = waitsInProgressSyncOnAdd
    }
}

/**
 *  Struct designed to store options needed to describe how an observer should be handled by streamable
 *  data provider.
 */

public struct StreamableProviderObserverOptions {
    /// Asks data provider to notify observer in any case after synchronization completes.
    /// If this value is `false` (default value) then observer is only notified when
    /// there are changes after synchronization.
    public var alwaysNotifyOnRefresh: Bool

    /// Asks data provider to wait until any in progress synchronization completes before reading the
    /// snapshot a new observer is given.
    /// By default the value is `true`.
    /// - note: This is a freshness knob, not a correctness one, and it never covered changes arriving from
    /// the repository observable. A change committed while an observer is being added is buffered and
    /// folded into its first delivery either way.
    public var waitsInProgressSyncOnAdd: Bool

    /// Number of items to fetch from local store and return in update block call after
    /// observer successfully added.
    /// Bu default the value is ```0```.
    /// - note: If the value is less or equal to zero than all existing objects are fetched.
    public var initialSize: Int

    /// Refreshes list using data source when one from repository is empty.
    /// By default ```true```.
    public var refreshWhenEmpty: Bool

    /// - parameters:
    ///    - alwaysNotifyOnRefresh: Asks data provider to notify observer in any case
    ///    after synchronization completes.
    ///    Default value is `false`.
    ///
    ///    - waitsInProgressSyncOnAdd: Asks data provider to wait until any in progress synchronization
    ///    completes before reading the snapshot a new observer is given. Default value is `true`. Passing
    ///    `false` may significantly improve performance, at the cost of a first delivery that an in
    ///    progress synchronization is about to supersede; no change is lost either way.
    ///
    ///    - initialSize: Number of items to fetch from local store and return in update block call after
    ///     observer successfully added. If the value is less or equal to zero than all
    ///     existing objects are fetched.
    ///
    ///    - refreshWhenEmpty: Calls refresh from data source when list fetched from repository is empty.
    ///    Default value is ```true```.

    public init(alwaysNotifyOnRefresh: Bool = false,
                waitsInProgressSyncOnAdd: Bool = true,
                initialSize: Int = 0,
                refreshWhenEmpty: Bool = true) {
        self.alwaysNotifyOnRefresh = alwaysNotifyOnRefresh
        self.waitsInProgressSyncOnAdd = waitsInProgressSyncOnAdd
        self.initialSize = initialSize
        self.refreshWhenEmpty = refreshWhenEmpty
    }
}

/**
 *  Struct is designed to store options applied for fetch request from a repository.
 */

public struct RepositoryFetchOptions {
    /**
     *  If ```false``` properties are fetched when they are directly accessed
     *  (for example, when an entity is transformed to app model), otherwise all
     *  properties are fetched and cached. By default ```true```.
     */
    let includesProperties: Bool

    /**
     *  If ```false``` subentities are fetched when they are directly accessed
     *  (for example, when an entity is transformed to app model), otherwise all
     *  subentities are fetched and cached. By default ```true```.
     */
    let includesSubentities: Bool

    public init(includesProperties: Bool = true, includesSubentities: Bool = true) {
        self.includesProperties = includesProperties
        self.includesSubentities = includesSubentities
    }
}

public extension RepositoryFetchOptions {
    /**
     *  Creates options to prevent including both properties and subentities to the fetch request.
     */
    static var none: RepositoryFetchOptions {
        RepositoryFetchOptions(includesProperties: false, includesSubentities: false)
    }

    /**
    *  Creates options to prevent including subentities to the fetch request.
    */
    static var onlyProperties: RepositoryFetchOptions {
        RepositoryFetchOptions(includesProperties: true, includesSubentities: false)
    }
}

/**
 *  Struct is designed to request part of the list of objects from repository.
 */

public struct RepositorySliceRequest {
    /**
     *  Offset of the slice the list of objects
     */
    let offset: Int

    /**
     *  Maximum number of objects to fetch
     */
    let count: Int

    /**
     *  If ```true``` the objects in the slice is in reversed order.
     */
    let reversed: Bool

    public init(offset: Int, count: Int, reversed: Bool) {
        self.offset = offset
        self.count = count
        self.reversed = reversed
    }
}
