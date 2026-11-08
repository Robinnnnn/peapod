import AuthenticationServices
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import FirebaseMessaging
import FirebaseStorage
import UserNotifications

enum MacFirebaseCapabilityProbe {
    static func verifyImportSurface() {
        _ = ASAuthorizationController.self
        _ = AppCheck.self
        _ = Auth.self
        _ = FirebaseApp.self
        _ = Firestore.self
        _ = Functions.self
        _ = Messaging.self
        _ = Storage.self
        _ = UNUserNotificationCenter.self
    }
}
