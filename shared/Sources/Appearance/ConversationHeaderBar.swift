import SwiftUI

/// Shared safe-area ownership keeps identity controls out of the timeline layout.
/// iPhone uses the native soft bar. Mac reserves the same header space and styles
/// its timeline edge explicitly; the system bar currently adds a hard blur seam.
struct ConversationHeaderBar<Header: View>: ViewModifier {
    let header: Header

    @ViewBuilder
    func body(content: Content) -> some View {
        headerContent(content)
            .backgroundPreferenceValue(ConversationOrnamentAnchorKey.self) { anchor in
                GeometryReader { geometry in
                    if let anchor {
                        let ornament = geometry[anchor]
                        ConversationOrnamentRibbon(ornament: ornament)
                    }
                }
#if os(iOS)
                .ignoresSafeArea(.container, edges: .top)
#endif
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }

    @ViewBuilder
    private func headerContent(_ content: Content) -> some View {
#if os(macOS)
        content.safeAreaInset(edge: .top, spacing: 0) { foregroundHeader }
#else
        if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .top, spacing: 0) { foregroundHeader }
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) { foregroundHeader }
        }
#endif
    }

    private var foregroundHeader: some View {
        header.backgroundPreferenceValue(ConversationOrnamentAnchorKey.self) { anchor in
            // The bar sits above the scrolling timeline. Its decorative background
            // covers messages while the identity and controls stay in front.
            GeometryReader { geometry in
                let width = geometry.size.width
#if os(macOS)
                let artworkWidth = min(width, 320)
#else
                let artworkWidth = min(width, 720)
#endif
                let ornaments = anchor.map {
                    ConversationHangingOrnamentLayout.ornaments(width: width,
                        artworkWidth: artworkWidth, avatar: geometry[$0])
                } ?? []
                ZStack(alignment: .top) {
                    ConversationHangingOrnamentCords(ornaments: ornaments)
                    ConversationHangingOrnamentBodies(ornaments: ornaments, tucked: true)
                    ConversationSpruceBorder(width: width, artworkWidth: artworkWidth)
                    ConversationHangingOrnamentBodies(ornaments: ornaments, tucked: false)
                }
            }
#if os(iOS)
            .ignoresSafeArea(.container, edges: .top)
#endif
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Preserve whole branches at their original aspect ratio, above messages and
/// behind the header's photo/name/controls without cutting needles.
private struct ConversationSpruceBorder: View {
    let width: CGFloat
    let artworkWidth: CGFloat

    var body: some View {
        Image("ConversationSpruce")
            .resizable()
            .scaledToFit()
            .frame(width: artworkWidth, height: artworkWidth / 4)
            .offset(y: -3)
            // Crop only the shifted roots at the top; retain every hanging tip
            // and keep the Mac drawing below the native title bar.
            .frame(width: width, height: artworkWidth / 4, alignment: .top)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
