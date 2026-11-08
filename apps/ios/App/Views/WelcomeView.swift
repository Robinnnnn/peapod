import AuthenticationServices
import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var currentNonce: String?

    var body: some View {
        OnboardingWelcomeContent {
            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = [.fullName, .email]
                do {
                    let nonce = try SignInNonce.random()
                    currentNonce = nonce
                    request.nonce = SignInNonce.hash(nonce)
                } catch {
                    model.errorMessage = error.localizedDescription
                }
            } onCompletion: { result in
                switch result {
                case .success(let authorization):
                    Task { @MainActor in
                        await model.finishSignIn(
                            authorization: authorization,
                            rawNonce: currentNonce
                        )
                    }
                case .failure(let error):
                    model.errorMessage = error.localizedDescription
                }
            }
            .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
            .frame(height: 50)
            .clipShape(.rect(cornerRadius: 13))
            .accessibilityIdentifier("sign-in-with-apple")
            .overlay(alignment: .leading) {
                if model.isWorking || model.isPreparingAccount {
                    ProgressView().controlSize(.small)
                        .tint(scheme == .dark ? .black : .white)
                        .frame(width: 18, height: 18).padding(.leading, 14)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityValue(model.isWorking || model.isPreparingAccount ? "Loading" : "")
            .disabled(model.isWorking || model.isPreparingAccount)
        }
    }
}
