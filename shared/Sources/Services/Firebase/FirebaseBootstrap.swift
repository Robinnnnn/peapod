@preconcurrency import FirebaseAppCheck
@preconcurrency import FirebaseCore
import Foundation

enum FirebaseBootstrap {
    /// Configures Firebase when the downloaded project configuration is present.
    ///
    /// Missing configuration returns false so the app can show setup guidance.
    @discardableResult
    static func configureIfPossible(bundle: Bundle = .main) -> Bool {
        if FirebaseApp.app() == nil {
            guard
                let path = bundle.path(forResource: "GoogleService-Info", ofType: "plist"),
                let options = FirebaseOptions(contentsOfFile: path)
            else {
                return false
            }

            configureAppCheck()
            FirebaseApp.configure(options: options)
        }
        do {
            try FirebaseAuthStateSharing.configureForContainingApp()
        } catch {
#if DEBUG
            print(
                "Firebase authentication sharing is unavailable in this "
                    + "process: \(error.localizedDescription)"
            )
#endif
            return false
        }
        return true
    }

    private static func configureAppCheck() {
#if os(iOS) && targetEnvironment(simulator)
        AppCheck.setAppCheckProviderFactory(
            AppCheckDebugProviderFactory()
        )
#elseif os(iOS)
        AppCheck.setAppCheckProviderFactory(
            AppAttestProviderFactory()
        )
#else
        // Firebase's built-in App Attest and DeviceCheck providers do not
        // support a native macOS process. Leave the SDK's default provider in
        // place until the backend adopts a custom provider for the Mac app.
#endif
    }
}
