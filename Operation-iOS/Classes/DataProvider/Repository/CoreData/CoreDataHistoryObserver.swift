import Foundation
import CoreData
import UIKit

public protocol CoreDataHistoryObserverDelegate: AnyObject {
    func persistentHistoryObserver(
        _ observer: CoreDataHistoryObserver,
        didReceiveNotifications notifications: [Notification]
    )
}

public final class CoreDataHistoryObserver {
    private let service: CoreDataServiceProtocol
    private let target: CoreDataHistoryTarget
    private let userDefaults: UserDefaults

    private let fetcher: CoreDataHistoryFetching
    private let merger: CoreDataHistoryMerging
    private let cleaner: CoreDataHistoryCleaning
    
    private lazy var timestampManager = CoreDataHistoryTimestampManager(
        target: target,
        userDefaults: userDefaults
    )
    
    public weak var delegate: CoreDataHistoryObserverDelegate?
    
    public init(
        service: CoreDataServiceProtocol,
        target: CoreDataHistoryTarget,
        userDefaults: UserDefaults = .standard,
        fetcher: CoreDataHistoryFetching = CoreDataHistoryFetcher(),
        merger: CoreDataHistoryMerging = CoreDataHistoryMerger(),
        cleaner: CoreDataHistoryCleaning? = nil
    ) {
        self.service = service
        self.target = target
        self.userDefaults = userDefaults
        self.fetcher = fetcher
        self.merger = merger
        self.cleaner = cleaner ?? CoreDataHistoryCleaner(userDefaults: userDefaults)
    }
    
    public func startObserving() {
        service.performAsync { [weak self] context, _ in
            guard let self, let context else { return }

            if let coordinator = context.persistentStoreCoordinator {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(self.didReceiveRemoteChange(notification:)),
                    name: .NSPersistentStoreRemoteChange,
                    object: coordinator
                )
            }

            self.processPendingHistory()
        }
        
        startObservingAppState()
    }

    public func stopObserving() {
        service.performAsync { [weak self] context, _ in
            guard let self, let context else { return }
            
            if let coordinator = context.persistentStoreCoordinator {
                NotificationCenter.default.removeObserver(
                    self,
                    name: .NSPersistentStoreRemoteChange,
                    object: coordinator
                )
            }
        }
        
        stopObservingAppState()
    }
}

private extension CoreDataHistoryObserver {
    @objc func didReceiveRemoteChange(notification: Notification) {
        processPendingHistory()
    }
    
    @objc func didBecomeActive() {
        processPendingHistory()
    }

    func startObservingAppState() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    func stopObservingAppState() {
        NotificationCenter.default.removeObserver(
            self,
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    func processPendingHistory() {
        service.performAsync { [weak self] context, _ in
            guard let self, let context else { return }
            
            let fromDate = self.timestampManager.lastTimestamp ?? .distantPast
            
            guard
                let transactions = try? self.fetcher.fetch(context: context, fromDate: fromDate),
                !transactions.isEmpty
            else { return }
            
            let notifications = self.merger.merge(context: context, transactions: transactions)
            
            if let lastTimestamp = transactions.last?.timestamp {
                self.timestampManager.update(to: lastTimestamp)
            }
            
            if !notifications.isEmpty {
                self.delegate?.persistentHistoryObserver(self, didReceiveNotifications: notifications)
            }
            
            try? self.cleaner.clean(context: context)
        }
    }
}
