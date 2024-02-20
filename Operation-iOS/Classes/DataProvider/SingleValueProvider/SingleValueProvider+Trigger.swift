import Foundation

extension SingleValueProvider: DataProviderTriggerDelegate {
    public func didTrigger() {
        dispatchUpdateRepository()
    }
}
