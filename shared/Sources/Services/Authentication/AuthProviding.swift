import AuthenticationServices
@preconcurrency import FirebaseAuth
import Foundation

@MainActor
protocol AuthProviding: AnyObject {
    var currentUser: Person? { get }

    /// Resolves after the authentication provider has finished restoring its
    /// persisted session. A synchronous `currentUser` read can be temporarily
    /// nil while Firebase initializes.
    func restoreCurrentUser() async -> Person?

    func signIn(
        credential: ASAuthorizationAppleIDCredential,
        rawNonce: String
    ) async throws -> Person

    func signOut() throws
}

@MainActor
final class LocalAuthService: AuthProviding {
    private(set) var currentUser: Person?

    func restoreCurrentUser() async -> Person? {
        currentUser
    }

    func signIn(
        credential: ASAuthorizationAppleIDCredential,
        rawNonce: String
    ) async throws -> Person {
        let name = credential.fullName?.givenName ?? "You"
        let person = Person(
            id: credential.user,
            displayName: name,
            initials: Person.initials(for: name)
        )
        currentUser = person
        return person
    }

    func signOut() throws {
        currentUser = nil
    }

}

@MainActor
final class FirebaseAuthService: AuthProviding {
    var currentUser: Person? {
        Self.person(from: Auth.auth().currentUser)
    }

    func restoreCurrentUser() async -> Person? {
        let auth = Auth.auth()
        return await withCheckedContinuation { continuation in
            let waiter = FirebaseAuthStateWaiter(continuation: continuation)
            let handle = auth.addStateDidChangeListener { auth, user in
                Task { @MainActor in
                    waiter.receive(auth: auth, user: user)
                }
            }
            waiter.install(handle: handle, auth: auth)
        }
    }

    private static func person(from user: User?) -> Person? {
        guard let user else { return nil }
        let name = user.displayName ?? "You"
        return Person(
            id: user.uid,
            displayName: name,
            initials: Person.initials(for: name)
        )
    }

    func signIn(
        credential appleCredential: ASAuthorizationAppleIDCredential,
        rawNonce: String
    ) async throws -> Person {
        guard
            let tokenData = appleCredential.identityToken,
            let token = String(data: tokenData, encoding: .utf8)
        else {
            throw AuthenticationError.missingIdentityToken
        }

        let credential = OAuthProvider.appleCredential(
            withIDToken: token,
            rawNonce: rawNonce,
            fullName: appleCredential.fullName
        )
        let result = try await Auth.auth().signIn(with: credential)
        let fallbackName = appleCredential.fullName?.givenName ?? "You"
        let name = result.user.displayName ?? fallbackName

        return Person(
            id: result.user.uid,
            displayName: name,
            initials: Person.initials(for: name)
        )
    }

    func signOut() throws {
        try Auth.auth().signOut()
    }
}

extension AuthProviding {
    func signOut() throws {}
}

@MainActor
private final class FirebaseAuthStateWaiter {
    private var continuation: CheckedContinuation<Person?, Never>?
    private var handle: AuthStateDidChangeListenerHandle?
    private var auth: Auth?
    private var pendingUser: User?
    private var receivedInitialState = false

    init(continuation: CheckedContinuation<Person?, Never>) {
        self.continuation = continuation
    }

    func install(
        handle: AuthStateDidChangeListenerHandle,
        auth: Auth
    ) {
        self.handle = handle
        self.auth = auth
        finishIfReady()
    }

    func receive(auth: Auth, user: User?) {
        self.auth = auth
        pendingUser = user
        receivedInitialState = true
        finishIfReady()
    }

    private func finishIfReady() {
        guard
            receivedInitialState,
            let handle,
            let auth,
            let continuation
        else {
            return
        }

        self.continuation = nil
        self.handle = nil
        self.auth = nil
        auth.removeStateDidChangeListener(handle)

        let name = pendingUser?.displayName ?? "You"
        let person = pendingUser.map {
            Person(
                id: $0.uid,
                displayName: name,
                initials: Person.initials(for: name)
            )
        }
        continuation.resume(returning: person)
    }
}

enum AuthenticationError: LocalizedError {
    case missingIdentityToken
    case invalidAuthorization
    case missingNonce

    var errorDescription: String? {
        switch self {
        case .missingIdentityToken:
            "Apple did not return a usable identity token."
        case .invalidAuthorization:
            "The Apple sign-in response could not be read."
        case .missingNonce:
            "The sign-in session expired. Please try again."
        }
    }
}

extension Person {
    static func initials(for name: String) -> String {
        let parts = name
            .split(whereSeparator: \.isWhitespace)
            .prefix(2)
        let value = parts.compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "?" : value.uppercased()
    }
}
