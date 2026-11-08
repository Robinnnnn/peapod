import SwiftUI

/// Header-only drawing: the original local photo and full profile stay untouched.
struct ConversationPhotoOrnament<Photo: View>: View {
    let size: CGFloat
    let warpsPhoto: Bool
    @ViewBuilder let content: () -> Photo

    var body: some View {
        content()
            .frame(width: size, height: size)
            .layerEffect(
                ShaderLibrary.conversationPhotoSphere(.float(Float(size))),
                maxSampleOffset: CGSize(width: size * 0.06, height: size * 0.06),
                isEnabled: warpsPhoto
            )
            .colorEffect(ShaderLibrary.conversationOrnamentGloss(.float(Float(size))))
            .clipShape(Circle())
            .overlay {
                Circle()
                    .fill(.black.opacity(0.16).gradient)
                    .mask {
                        Circle().strokeBorder(
                            .linearGradient(colors: [.clear, .black], startPoint: .topLeading,
                                            endPoint: .bottomTrailing), lineWidth: size * 0.06)
                            .blur(radius: size * 0.035)
                    }
                    .overlay {
                        goldEdgeTint
                    }
                    .overlay {
                        Circle().strokeBorder(
                            .linearGradient(colors: [OrnamentMetal.light, OrnamentMetal.gold,
                                                     OrnamentMetal.shadow, OrnamentMetal.gold],
                                            startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: max(0.7, size * 0.012))
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .top) {
                OrnamentTopper()
                    // Transparent sprite margins keep the visible metal at 16%.
                    .frame(width: size * 0.185, height: size * 0.185)
                    .offset(y: -size * 0.169)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .anchorPreference(key: ConversationOrnamentAnchorKey.self, value: .bounds) { $0 }
    }

    private var goldEdgeTint: some View {
        Circle().fill(RadialGradient(
            stops: [Gradient.Stop(color: .clear, location: 0),
                    Gradient.Stop(color: OrnamentMetal.gold.opacity(0.04), location: 0.35),
                    Gradient.Stop(color: OrnamentMetal.gold.opacity(0.13), location: 0.72),
                    Gradient.Stop(color: OrnamentMetal.light.opacity(0.29), location: 1)],
            center: .center, startRadius: size * 0.32, endRadius: size * 0.5))
    }
}

enum ConversationOrnamentAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// Lives in the header container's coordinates, not the avatar's hit-test bounds.
struct ConversationOrnamentRibbon: View {
    @Environment(\.displayScale) private var displayScale
    let ornament: CGRect

    var body: some View {
        // Join the sprite's satin stub; the sprite owns the over/under fold
        // through the eyelet instead of leaving a flat strip behind the ring.
        let end = max(0, ornament.minY - ornament.width * 0.162)
        let width = max(1.8, ornament.width * 0.037)
        Rectangle()
            .fill(.white)
            .frame(width: width, height: end)
            .colorEffect(ShaderLibrary.conversationRibbonSatin(
                .float2(Float(width), Float(end)), .float(Float(displayScale))))
            .position(x: ornament.midX, y: end / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private enum OrnamentMetal {
    static let light = Color(red: 1, green: 0.89, blue: 0.57)
    static let gold = Color(red: 0.78, green: 0.53, blue: 0.18)
    static let shadow = Color(red: 0.36, green: 0.22, blue: 0.06)
}

private struct OrnamentTopper: View {
    var body: some View {
        Image("ConversationOrnamentTopper")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            // Only the first satin pixels blend at the join; metal starts lower.
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                        .init(color: .black, location: 0.025),
                                        .init(color: .black, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
    }
}
