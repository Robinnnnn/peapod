@preconcurrency import FirebaseAuth
import Foundation

enum FirebaseAuthStateSharing {
    static func configureForContainingApp() throws {
        // Resolve the signed build's explicit group before selecting an auth store.
        let accessGroup = try AppGroup.firebaseAuthAccessGroup
        try Auth.auth().useUserAccessGroup(accessGroup)
    }
}
