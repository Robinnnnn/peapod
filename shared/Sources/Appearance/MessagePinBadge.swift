import SwiftUI

/// A small, noninteractive marker inside the message surface.
struct MessagePinBadge: View {
    var isOutgoing: Bool
    var overMedia = false

    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(overMedia || isOutgoing ? Color.white.opacity(0.85) : Color.secondary)
            .padding(overMedia ? 4 : 0)
            .background {
                if overMedia { Circle().fill(.black.opacity(0.55)) }
            }
            .padding(.trailing, 8)
            .padding(.bottom, 7)
            .accessibilityLabel("Pinned")
            .allowsHitTesting(false)
    }
}
