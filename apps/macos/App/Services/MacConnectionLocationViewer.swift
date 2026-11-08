import Foundation

/// Mac consumes the two primary phones' shared points. This seam exposes no publishing API.
@MainActor
protocol MacConnectionLocationViewing: AnyObject {
    func observe(accountID: String, conversationID: String,
        onChange: @escaping @MainActor (Result<ConnectionLocationSnapshot, Error>) -> Void) -> ServiceObservation
}

@MainActor
final class MacEmptyConnectionLocationViewer: MacConnectionLocationViewing {
    func observe(accountID: String, conversationID: String,
        onChange: @escaping @MainActor (Result<ConnectionLocationSnapshot, Error>) -> Void) -> ServiceObservation {
        onChange(.success(.empty))
        return ServiceObservation()
    }
}

/// Resolve the current encrypted content session before attaching its authenticated listener.
/// Missing encrypted location support stays empty; it never falls back to plaintext Firestore.
@MainActor
final class MacEncryptedConnectionLocationViewer: MacConnectionLocationViewing {
    private let services: EncryptedAppServices
    init(_ services: EncryptedAppServices) { self.services = services }
    func observe(accountID: String, conversationID: String,
        onChange: @escaping @MainActor (Result<ConnectionLocationSnapshot, Error>) -> Void) -> ServiceObservation {
        do {
            _ = try services.messaging(for: conversationID)
            guard let session = services.session else {
                onChange(.success(.empty)); return ServiceObservation()
            }
            try session.requireActive(conversationID: conversationID, accountID: accountID)
            guard let locations = services.locations else {
                onChange(.success(.empty)); return ServiceObservation()
            }
            return locations.observe(conversationID: conversationID) { [weak services, weak session] result in
                guard let services, let session, services.session === session else {
                    onChange(.failure(EncryptedLocationError.inactive)); return
                }
                do {
                    try session.requireActive(conversationID: conversationID, accountID: accountID)
                    onChange(result)
                } catch {
                    onChange(.failure(EncryptedLocationError.inactive))
                }
            }
        } catch {
            onChange(.failure(EncryptedLocationError.inactive))
            return ServiceObservation()
        }
    }
}
