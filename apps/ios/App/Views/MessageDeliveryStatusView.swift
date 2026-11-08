import SwiftUI

struct MessageDeliveryStatusView: View {
    @Environment(\.usesGiftWrap) private var usesGiftWrap
    @Environment(\.colorScheme) private var colorScheme


    let state: DeliveryState
    var retry: (() -> Void)? = nil

    var body: some View {
        Group {
            if state == .failed, let retry {
                Button(action: retry) { indicator }
                    .buttonStyle(.plain)
            } else {
                indicator
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityHint(Text(state == .failed && retry != nil ? "Double tap to retry" : ""))
    }

    private var indicator: some View {
        MessageDeliveryIndicator(
            state: state,
            unreadColor: usesGiftWrap ? GiftWrapAppearance.receipt(colorScheme == .dark, isRead: false) : .secondary,
            readColor: readColor,
            castsShadow: usesGiftWrap
        )
    }

    private var readColor: Color {
        return usesGiftWrap ? GiftWrapAppearance.receipt(colorScheme == .dark, isRead: true) : .indigo
    }
}
