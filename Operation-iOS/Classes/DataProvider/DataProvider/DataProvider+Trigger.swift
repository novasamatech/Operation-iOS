import Foundation

extension DataProvider: DataProviderTriggerDelegate {
    public func didTrigger() {
        dispatchUpdateRepository()
    }
}
