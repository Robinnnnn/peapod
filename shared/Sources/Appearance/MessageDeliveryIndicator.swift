import SwiftUI

/// Every delivery state occupies the same footprint. Keep the checks alive
/// between receipts so SwiftUI changes opacity/color instead of morphing text.
struct MessageDeliveryIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let state: DeliveryState
    let unreadColor: Color
    let readColor: Color
    var castsShadow = false

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: -6) {
                checkmark.opacity(state == .sent ? 0 : 1)
                checkmark
            }
            .foregroundStyle(state == .read ? readColor : unreadColor)
            .shadow(color: castsShadow ? .black.opacity(0.18) : .clear, radius: 0.5, y: 0.5)
            .opacity(showsChecks ? 1 : 0)

            if state == .sending {
                ActivitySpinner(size: 12)
                    .transition(.opacity)
            }

            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.red)
                .opacity(state == .failed ? 1 : 0)
        }
        .frame(width: 26, height: 20, alignment: .trailing)
        .fixedSize()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: state)
        .transaction { transaction in
            // The native timeline suppresses row-layout animations. Only this
            // fixed-size indicator may crossfade; its parent never resizes.
            transaction.disablesAnimations = reduceMotion
        }
    }

    private var checkmark: some View {
        Image(systemName: "checkmark")
            // A scalable caption font can outgrow a fixed receipt slot and be
            // clipped at large Dynamic Type sizes. Status remains a small icon.
            .font(.system(size: 12, weight: .bold))
            .fixedSize()
    }

    private var showsChecks: Bool {
        state == .sent || state == .delivered || state == .read
    }
}

extension DeliveryState {
    var accessibilityLabel: String {
        switch self {
        case .sending: "Sending"
        case .sent: "Sent"
        case .delivered: "Delivered"
        case .read: "Read"
        case .failed: "Message not sent"
        }
    }
}
