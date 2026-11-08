import Foundation

enum ConversationTeardownErrorPolicy {
    private static let firestoreDomains: Set<String> = [
        "FIRFirestoreErrorDomain",
        "FirebaseFirestore",
        "com.firebase.firestore",
    ]

    private static let expectedCodes: Set<Int> = [
        5, // not found
        7, // permission denied
    ]

    static func isExpectedLateFailure(_ error: any Error) -> Bool {
        var currentError = error as NSError
        var visited = Set<ObjectIdentifier>()

        while true {
            let identifier = ObjectIdentifier(currentError)
            guard visited.insert(identifier).inserted else {
                return false
            }

            if
                firestoreDomains.contains(currentError.domain),
                expectedCodes.contains(currentError.code)
            {
                return true
            }

            guard
                let underlying = currentError.userInfo[
                    NSUnderlyingErrorKey
                ] as? NSError
            else {
                return false
            }
            currentError = underlying
        }
    }
}
