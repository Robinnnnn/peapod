import Foundation

@MainActor
final class ServiceObservation {
    private var cancellation: (() -> Void)?

    init(_ cancellation: @escaping () -> Void = {}) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation?()
        cancellation = nil
    }
}
