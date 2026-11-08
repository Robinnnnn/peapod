@preconcurrency import FirebaseAuth
@preconcurrency import FirebaseCore
import CoreFoundation
import CryptoKit
import Foundation
import MinesE2EE

@MainActor
final class ShareDeliveryService {
    private var preparedTarget: SharedConversationTarget?
    private var controller: KeyReadinessController?
    private var keyToken: KeySessionToken?

    /// Metadata is only a selection hint. Verify current auth, profile assignment, protocol floor,
    /// server membership and the atomic native capsule before provider content is accepted.
    func prepareDestination() async throws -> SharedConversationTarget {
        guard let target = try SharedConversationStore.currentTarget() else { throw ShareDeliveryError.noConversation }
        try configureFirebase()
        let auth = Auth.auth(); try auth.useUserAccessGroup(AppGroup.firebaseAuthAccessGroup)
        guard let user = auth.currentUser, user.uid.utf8.elementsEqual(target.accountID.utf8) else { throw ShareDeliveryError.notSignedIn }
        let token = try await user.getIDToken()
        try requireCurrent(target)
        let profile = try await getDocument(path: ["users", user.uid], token: token)
        try requireCurrent(target)
        guard ShareRoutingWire.activeConversationID(from: profile)?.utf8.elementsEqual(target.conversationID.utf8) == true else { throw ShareDeliveryError.noConversation }
        if try fieldBool(profile, "e2eeRequired") == true { try SharedConversationStore.markEncryptionRequired(accountID: user.uid) }
        let conversation = try await getDocument(path: ["conversations", target.conversationID], token: token)
        try requireCurrent(target)
        guard fieldString(conversation, "status") == "active", let members = try fieldMembers(conversation),
              Set(members.map { Data($0.utf8) }) == Set(target.members.map { Data($0.utf8) }), members.count == 2 else { throw ShareDeliveryError.encryptionMismatch }
        let encryption = fieldString(conversation, "encryption")
        let namespace = try BuildIdentity.keychainNamespace()
        let capsules = ConversationCapsuleStore(namespace: namespace)
        if target.mode == .legacy {
            guard (conversation["fields"] as? [String: Any])?["encryption"] == nil, (conversation["fields"] as? [String: Any])?["keyEpoch"] == nil, encryption == nil, !(try SharedConversationStore.requiresEncryption(accountID: target.accountID)) else { throw ShareDeliveryError.encryptionMismatch }
            if UUID(uuidString: target.conversationID)?.uuidString.lowercased() == target.conversationID {
                let known = try await capsules.readCapsule(scope: KeyScope(accountID: target.accountID, conversationID: target.conversationID, epoch: 1))
                try requireCurrent(target)
                guard known == nil else { throw ShareDeliveryError.encryptionMismatch }
            }
        } else {
            guard encryption == StoredConversationCapsule.contentSuite, let epoch = target.keyEpoch,
                  try fieldInteger(conversation, "keyEpoch") == UInt64(epoch) else { throw ShareDeliveryError.encryptionMismatch }
            try SharedConversationStore.markEncryptionRequired(accountID: target.accountID)
            try await prepareEncrypted(target: target, members: members)
        }
        preparedTarget = target
        return target
    }

    private func prepareEncrypted(target: SharedConversationTarget, members: [String], expectedCapsuleDigest: Data? = nil) async throws {
        guard let epoch = target.keyEpoch else { throw ShareDeliveryError.encryptionMismatch }
        let namespace = try BuildIdentity.keychainNamespace()
        let capsules = ConversationCapsuleStore(namespace: namespace)
        let scope = KeyScope(accountID: target.accountID, conversationID: target.conversationID, epoch: epoch)
        guard let capsule = try await capsules.readCapsule(scope: scope) else { throw ShareDeliveryError.keyUnavailable }
        try requireCurrent(target)
        guard Set([Data(capsule.creatorID.utf8), Data(capsule.recipientID.utf8)]) == Set(members.map { Data($0.utf8) }),
              capsule.conversationID.utf8.elementsEqual(target.conversationID.utf8), capsule.keyEpoch == epoch,
              capsule.localAccountID.utf8.elementsEqual(target.accountID.utf8) else { throw ShareDeliveryError.encryptionMismatch }
        if let expectedCapsuleDigest {
            guard Data(SHA256.hash(data: capsule.encodedForLocalStorage())) == expectedCapsuleDigest else { throw ShareDeliveryError.encryptionMismatch }
        }
        let pinned = PinnedConversationCapsuleReader(store: capsules, expectedCapsule: capsule)
        let controller = KeyReadinessController(reader: pinned)
        let keyToken = try await controller.activate(capsule.trustedDescriptor())
        try requireCurrent(target)
        let readiness = await controller.read(token: keyToken)
        try requireCurrent(target)
        guard case .ready = readiness else { throw ShareDeliveryError.keyUnavailable }
        self.controller = controller; self.keyToken = keyToken
    }

    /// true means legacy delivery completed; false means an encrypted envelope or legacy file
    /// handoff is durably queued. Encrypted submissions never write a plaintext fallback queue.
    func sendOrQueue(_ shares: [PendingShare], target: SharedConversationTarget) async throws -> Bool {
        guard !shares.isEmpty, preparedTarget == target else { throw ShareDeliveryError.noConversation }
        try requireCurrent(target)
        guard shares.allSatisfy({ $0.conversationOwnerID.map { Data($0.utf8) == Data(target.accountID.utf8) } == true
            && $0.targetConversationID.map { Data($0.utf8) == Data(target.conversationID.utf8) } == true }) else { throw PendingShareStoreError.accountMismatch }
        if target.mode == .encrypted {
            guard let root = AppGroup.containerURL, let controller, let keyToken else { throw ShareDeliveryError.keyUnavailable }
            var directory = root.appendingPathComponent("E2EE/Outbox", isDirectory: true)
            let store = try DurableCiphertextOutbox(directory: directory, limits: .production)
            defer { store.close() }
            var attachmentURLs: [UUID: URL] = [:]
            for share in shares where share.kind != .text && share.kind != .url {
                attachmentURLs[share.id] = try PendingShareStore.stagedFileURL(for: share)
            }
            let readiness = await controller.read(token: keyToken)
            try requireCurrent(target)
            guard case .ready(let lease) = readiness else { throw ShareDeliveryError.keyUnavailable }
            let sources = attachmentURLs
            try await controller.useKey(lease) { key, scope in
                guard scope.accountID.utf8.elementsEqual(target.accountID.utf8), scope.conversationID.utf8.elementsEqual(target.conversationID.utf8), scope.epoch == target.keyEpoch else { throw ShareDeliveryError.encryptionMismatch }
                _ = try EncryptedShareMessageWriter.enqueueBatch(shares, target: target, epochKey: key, outbox: store, attachmentURLs: sources)
            }
            try requireCurrent(target)
            PendingShareStore.discardStagedFiles(for: shares)
            return false
        }
        guard !(try SharedConversationStore.requiresEncryption(accountID: target.accountID)) else { throw ShareDeliveryError.encryptionMismatch }
        try PendingShareStore.enqueue(shares)
        guard shares.allSatisfy({ $0.kind == .text || $0.kind == .url }) else { return false }
        guard let user = Auth.auth().currentUser else { throw ShareDeliveryError.notSignedIn }
        var token = try await user.getIDToken(); try requireCurrent(target)
        for share in shares {
            do { try await sendLegacy(share, userID: user.uid, token: token, target: target) }
            catch ShareDeliveryError.server(statusCode: 401, _) {
                token = try await user.getIDToken(forcingRefresh: true); try requireCurrent(target)
                try await sendLegacy(share, userID: user.uid, token: token, target: target)
            }
        }
        _ = try PendingShareStore.acknowledgeProcessed(Set(shares.map(\.id)), accountID: target.accountID)
        return true
    }

    private func requireCurrent(_ target: SharedConversationTarget) throws {
        guard try SharedConversationStore.currentTarget() == target else { throw ShareDeliveryError.noConversation }
        guard Auth.auth().currentUser?.uid.utf8.elementsEqual(target.accountID.utf8) == true else { throw ShareDeliveryError.notSignedIn }
        if target.mode == .legacy, try SharedConversationStore.requiresEncryption(accountID: target.accountID) { throw ShareDeliveryError.encryptionMismatch }
    }
    private func configureFirebase() throws {
        _ = try BuildIdentity.configuration()
        if FirebaseApp.app() == nil {
            guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
                  let options = FirebaseOptions(contentsOfFile: path),
                  Self.validProjectID(options.projectID) else { throw ShareDeliveryError.firebaseUnavailable }
            FirebaseApp.configure(options: options)
        }
        _ = try firebaseProjectID()
    }
    private func firebaseProjectID() throws -> String {
        guard let projectID = FirebaseApp.app()?.options.projectID,
              Self.validProjectID(projectID) else { throw ShareDeliveryError.firebaseUnavailable }
        return projectID
    }
    private static func validProjectID(_ value: String?) -> Bool {
        guard let value, (6...30).contains(value.utf8.count),
              let first = value.utf8.first, (97...122).contains(first),
              value.utf8.last != 45 else { return false }
        return value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }
    private func sendLegacy(_ share: PendingShare, userID: String, token: String, target: SharedConversationTarget) async throws {
        try requireCurrent(target)
        let request = try ShareMessageCommitRequest.make(share: share, userID: userID, projectID: try firebaseProjectID(), token: token)
        let (data, response) = try await boundedResponse(request)
        try requireCurrent(target)
        guard !(200..<300).contains(response.statusCode) else { return }
        if response.statusCode == 409 {
            let existing = try await getDocument(path: ["conversations", target.conversationID, "messages", share.id.uuidString], token: token)
            try requireCurrent(target)
            guard LegacyShareReplayPolicy.matches(share: share, userID: userID, existing: existing) else { throw ShareDeliveryError.conflictingItem }
            return
        }
        throw ShareDeliveryError.server(statusCode: response.statusCode, detail: Self.serverDetail(data))
    }
    private func getDocument(path: [String], token: String) async throws -> [String: Any] {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
        let encoded = try path.map { part -> String in guard let value = part.addingPercentEncoding(withAllowedCharacters: allowed) else { throw ShareDeliveryError.invalidPayload }; return value }.joined(separator: "/")
        guard let url = URL(string: "https://firestore.googleapis.com/v1/projects/\(try firebaseProjectID())/databases/(default)/documents/\(encoded)") else { throw ShareDeliveryError.invalidPayload }
        var request = URLRequest(url: url); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await boundedResponse(request)
        guard (200..<300).contains(response.statusCode) else { throw ShareDeliveryError.server(statusCode: response.statusCode, detail: Self.serverDetail(data)) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ShareDeliveryError.invalidPayload }; return object
    }
    private func boundedResponse(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { bytes.task.cancel(); throw ShareDeliveryError.invalidPayload }
        guard response.expectedContentLength <= 32 * 1024 else { bytes.task.cancel(); throw ShareDeliveryError.invalidPayload }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 32 * 1024 else { bytes.task.cancel(); throw ShareDeliveryError.invalidPayload }; data.append(byte)
        }
        return (data, response)
    }
    private func fieldString(_ object: [String: Any], _ name: String) -> String? {
        ((object["fields"] as? [String: Any])?[name] as? [String: Any])?["stringValue"] as? String
    }
    private func fieldBool(_ object: [String: Any], _ name: String) throws -> Bool? {
        guard let value = (object["fields"] as? [String: Any])?[name] else { return nil }
        guard let number = (value as? [String: Any])?["booleanValue"] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw ShareDeliveryError.invalidPayload }; return number.boolValue
    }
    private func fieldInteger(_ object: [String: Any], _ name: String) throws -> UInt64 {
        guard let value = ((object["fields"] as? [String: Any])?[name] as? [String: Any])?["integerValue"] as? String,
              let number = UInt64(value), String(number) == value, number > 0, number <= UInt64(UInt32.max) else { throw ShareDeliveryError.invalidPayload }; return number
    }
    private func fieldMembers(_ object: [String: Any]) throws -> [String]? {
        guard let raw = (object["fields"] as? [String: Any])?["members"] else { return nil }
        guard let values = ((raw as? [String: Any])?["arrayValue"] as? [String: Any])?["values"] as? [[String: Any]], values.count == 2 else { throw ShareDeliveryError.invalidPayload }
        return try values.map { guard let id = $0["stringValue"] as? String, !id.isEmpty, id.utf8.count <= 256 else { throw ShareDeliveryError.invalidPayload }; return id }
    }
    private static func serverDetail(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = object["error"] as? [String: Any], let message = error["message"] as? String else { return "Unknown response" }
        return String(message.prefix(240))
    }
}
