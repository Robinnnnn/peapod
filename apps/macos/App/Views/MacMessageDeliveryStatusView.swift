import SwiftUI

struct MacMessageDeliveryStatusView: View {
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
        .help(state == .failed && retry != nil ? "Message not sent. Click to retry." : state.accessibilityLabel)
    }

    private var indicator: some View {
        MessageDeliveryIndicator(
            state: state,
            unreadColor: GiftWrapAppearance.receipt(colorScheme == .dark, isRead: false),
            readColor: GiftWrapAppearance.receipt(colorScheme == .dark, isRead: true),
            castsShadow: true
        )
    }
}
