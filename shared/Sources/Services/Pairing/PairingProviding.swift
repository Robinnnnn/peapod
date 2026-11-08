@preconcurrency import FirebaseFunctions
import Foundation

struct PairingResult: Sendable, Equatable {
    let conversationID: String?
    let code: String?
}

@MainActor
protocol PairingProviding: AnyObject {
    func createConversation() async throws -> PairingResult
    func joinConversation(code: String) async throws -> PairingResult
    func cancelPairingCode(code: String) async throws -> PairingResult
    func deleteConversation() async throws
    func deleteConversation(expectedConversationID: String) async throws
}

@MainActor
final class LocalPairingService: PairingProviding {
    func createConversation() async throws -> PairingResult {
        PairingResult(conversationID: "local-conversation", code: "ABCD-2345")
    }

    func joinConversation(code: String) async throws -> PairingResult {
        PairingResult(conversationID: "local-conversation", code: nil)
    }

    func cancelPairingCode(code: String) async throws -> PairingResult {
        PairingResult(conversationID: nil, code: nil)
    }

    func deleteConversation() async throws {}
}

@MainActor
final class FirebasePairingService: PairingProviding {
    private let functions: Functions

    init(functions: Functions = Functions.functions(region: "us-west1")) {
        self.functions = functions
    }

    func createConversation() async throws -> PairingResult {
        let result = try await functions.httpsCallable("createPairingCode").call()
        guard
            let payload = result.data as? [String: Any],
            let code = payload["code"] as? String
        else {
            throw PairingError.invalidResponse
        }
        return PairingResult(conversationID: nil, code: code)
    }

    func joinConversation(code: String) async throws -> PairingResult {
        let result = try await functions
            .httpsCallable("redeemPairingCode")
            .call(["code": code.uppercased()])
        guard
            let payload = result.data as? [String: Any],
            let conversationID = payload["conversationId"] as? String
        else {
            throw PairingError.invalidResponse
        }
        return PairingResult(conversationID: conversationID, code: nil)
    }

    func cancelPairingCode(code: String) async throws -> PairingResult {
        let result = try await functions
            .httpsCallable("cancelPairingCode")
            .call(["code": code.uppercased()])
        guard let payload = result.data as? [String: Any] else {
            throw PairingError.invalidResponse
        }

        if let conversationID = payload["conversationId"] as? String {
            return PairingResult(
                conversationID: conversationID,
                code: nil
            )
        }
        guard payload["cancelled"] as? Bool == true else {
            throw PairingError.invalidResponse
        }
        return PairingResult(conversationID: nil, code: nil)
    }

    func deleteConversation() async throws {
        throw PairingError.conversationDeletionUnavailable
    }

    func deleteConversation(expectedConversationID: String) async throws {
        throw PairingError.conversationDeletionUnavailable
    }

}

extension PairingProviding {
    func deleteConversation(expectedConversationID: String) async throws {
        try await deleteConversation()
    }
    func cancelPairingCode(code: String) async throws -> PairingResult {
        throw PairingError.invalidResponse
    }

    func deleteConversation() async throws {}
}

enum PairingError: LocalizedError {
    case invalidResponse
    case conversationDeletionUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The pairing service returned an invalid response."
        case .conversationDeletionUnavailable: "Conversation deletion is unavailable."
        }
    }
}
