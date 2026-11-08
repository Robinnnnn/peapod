import SwiftUI

/// Shared presentation for the real onboarding and the local simulator preview.
enum OnboardingStyle {
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 25 / 255, green: 25 / 255, blue: 29 / 255) : .white
    }
    static func foreground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 244 / 255, green: 243 / 255, blue: 247 / 255) : Color(red: 32 / 255, green: 32 / 255, blue: 37 / 255)
    }
    static func secondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 177 / 255, green: 176 / 255, blue: 188 / 255) : Color(red: 99 / 255, green: 99 / 255, blue: 110 / 255)
    }
    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 150 / 255, green: 144 / 255, blue: 255 / 255) : Color(red: 87 / 255, green: 83 / 255, blue: 206 / 255)
    }
    static func onAccent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 23 / 255, green: 20 / 255, blue: 47 / 255) : .white
    }
}

struct OnboardingFrame<Header: View, Hero: View, Actions: View>: View {
    var welcomeGradient = false
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let header: Header
    @ViewBuilder let hero: Hero
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: 44)
            VStack(spacing: 16) { hero }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 8) { actions }.padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(OnboardingStyle.foreground(scheme))
        .tint(OnboardingStyle.accent(scheme))
        .background {
            ZStack {
                OnboardingStyle.background(scheme)
                if welcomeGradient {
                    LinearGradient(
                        colors: [Color.indigo.opacity(0.22), Color.pink.opacity(0.16), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .ignoresSafeArea()
        }
    }
}

struct OnboardingHeading: View {
    let title: String
    let symbol: String
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .title2) private var titleSize = 23

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(OnboardingStyle.accent(scheme))
                .accessibilityHidden(true)
            Text(title).font(.system(size: titleSize, weight: .semibold))
                .tracking(-0.5)
        }
    }
}

struct OnboardingActionButton: View {
    let title: String
    var isLoading = false
    var secondary = false
    var checkmark = false
    var dimsWhenDisabled = true
    let action: @MainActor () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var fontSize = 15

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if checkmark { Image(systemName: "checkmark").accessibilityHidden(true) }
                Text(title)
            }
            .opacity(isLoading ? 0 : 1)
            .font(.system(size: fontSize, weight: secondary ? .regular : .semibold))
            .padding(.horizontal, 38)
            .frame(maxWidth: .infinity, minHeight: secondary ? 44 : 50)
            .background(secondary ? Color.clear : OnboardingStyle.accent(scheme), in: .rect(cornerRadius: 13))
            .foregroundStyle(secondary ? OnboardingStyle.accent(scheme) : OnboardingStyle.onAccent(scheme))
            .overlay {
                if isLoading {
                    ProgressView()
                        .controlSize(.regular)
                        .scaleEffect(1.2)
                        .tint(secondary ? OnboardingStyle.accent(scheme) : OnboardingStyle.onAccent(scheme))
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(OnboardingActionButtonStyle())
        .disabled(isLoading)
        .opacity(isLoading || !dimsWhenDisabled || isEnabled ? 1 : 0.62)
        .accessibilityLabel(title)
        .accessibilityValue(isLoading ? "Loading" : "")
    }
}

/// Loading stays full contrast while the button remains disabled to input.
/// PlainButtonStyle adds its own disabled fade on top of our explicit opacity.
private struct OnboardingActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.88 : 1)
    }
}

struct OnboardingWelcomeContent<Actions: View>: View {
    @ViewBuilder let actions: Actions
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 42

    var body: some View {
        OnboardingFrame(welcomeGradient: true) {
            Color.clear
        } hero: {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(OnboardingStyle.accent(scheme))
                .accessibilityHidden(true)
            Text("Peapod").font(.system(size: titleSize, weight: .bold)).tracking(-1.5)
            Text("A private place for you and boo")
                .font(.subheadline).foregroundStyle(OnboardingStyle.secondary(scheme))
        } actions: {
            actions
        }
    }
}

struct OnboardingWaitingIndicator: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PhaseAnimator([0, 1, 2]) { phase in
            HStack(spacing: 7) {
                ForEach(0..<3) { index in
                    Circle().fill(OnboardingStyle.accent(scheme))
                        .frame(width: 7, height: 7)
                        .offset(y: !reduceMotion && index == phase ? -3 : 0)
                }
            }
        } animation: { _ in .easeInOut(duration: 0.45) }
        .frame(height: 38)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waiting for your person")
    }
}
