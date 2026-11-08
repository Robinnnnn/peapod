import SwiftUI

/// Coordinates belong to the spruce artwork, never the wallpaper underneath it.
/// Asset rectangles include the eyelet but omit the photographed hanging cord.
struct ConversationHangingOrnament: Identifiable {
    enum Cord { case gold, ribbon }

    let id: String
    let frame: CGRect
    let branch: CGPoint
    let eyelet: CGPoint
    /// Tucked ornaments draw beneath the spruce so needle tips overlap them.
    let tucked: Bool
    let cord: Cord
}

enum ConversationHangingOrnamentLayout {
    private struct Design {
        let name: String
        let x: CGFloat
        let branchY: CGFloat
        let top: CGFloat
        let width: CGFloat
        let aspect: CGFloat
        let eyeletX: CGFloat
        var tucked = false
        var cord: ConversationHangingOrnament.Cord = .gold
    }

    // Branch positions were picked on the woody stems in ConversationSpruce.
    // top/width are points at the 402pt iPhone composition; aspect is the
    // alpha-trimmed resource size, so transparent source margins cannot crowd it.
    // Deliberately asymmetric: the large Mouse King in front beside a tucked
    // Cranberry on the left; on the right a small Ivory set apart from a close
    // Nutcracker/Blue pair. Heights are staggered; short cords keep the bodies
    // clear of the Dynamic Island.
    private static let designs: [Design] = [
        .init(name: "Cranberry", x: 0.155, branchY: 0.42, top: 58, width: 28, aspect: 240 / 320, eyeletX: 0.50,
              tucked: true, cord: .ribbon),
        .init(name: "MouseKing", x: 0.27, branchY: 0.22, top: 41, width: 34, aspect: 238 / 320, eyeletX: 0.50),
        .init(name: "Ivory", x: 0.665, branchY: 0.25, top: 50, width: 20, aspect: 238 / 320, eyeletX: 0.50),
        .init(name: "Nutcracker", x: 0.775, branchY: 0.20, top: 40, width: 22, aspect: 116 / 320, eyeletX: 0.52),
        .init(name: "Blue", x: 0.86, branchY: 0.30, top: 60, width: 25, aspect: 240 / 309, eyeletX: 0.50,
              tucked: true),
    ]

    static func ornaments(width: CGFloat, artworkWidth: CGFloat, avatar: CGRect) -> [ConversationHangingOrnament] {
        guard width.isFinite, artworkWidth.isFinite, width > 0, artworkWidth > 0,
              avatar.width > 0 else { return [] }
        let artWidth = min(width, artworkWidth)
        let originX = (width - artWidth) / 2
        // Do not enlarge cutouts on tablets/wide windows. On compact layouts,
        // scale down instead of allowing adjacent silhouettes to collide.
        let scale = min(1, artWidth / 402)
        let artHeight = artWidth / 4
        let clearance: CGFloat = 12

        return designs.compactMap { design in
            let naturalX = originX + artWidth * design.x
            let ornamentWidth = design.width * scale
            let x = naturalX < avatar.midX
                ? min(naturalX, avatar.minX - clearance - ornamentWidth * (1 - design.eyeletX))
                : max(naturalX, avatar.maxX + clearance + ornamentWidth * design.eyeletX)
            let height = ornamentWidth / design.aspect
            // The phone includes its top safe area; Mac's smaller avatar/header
            // pulls the side ornaments upward, below the native title bar.
            let branch = CGPoint(x: x, y: artHeight * design.branchY - 3)
            let top = max(branch.y + 6 * scale,
                          design.top * scale - max(0, 80 - avatar.width) * 0.85)
            let frame = CGRect(x: x - ornamentWidth * design.eyeletX, y: top,
                               width: ornamentWidth, height: height)
            return ConversationHangingOrnament(id: "ConversationDecoration\(design.name)",
                frame: frame, branch: branch, eyelet: CGPoint(x: x, y: top + 0.5),
                tucked: design.tucked, cord: design.cord)
        }
    }
}

/// Four drawing planes: cords, tucked bodies, spruce, front bodies. Needles
/// cover every cord attachment and overlap the tucked bodies for depth.
struct ConversationHangingOrnamentCords: View {
    let ornaments: [ConversationHangingOrnament]

    var body: some View {
        Canvas { context, _ in
            for ornament in ornaments {
                var cord = Path()
                cord.move(to: ornament.branch)
                cord.addLine(to: ornament.eyelet)
                let colors: [Color] = switch ornament.cord {
                case .gold: [Color(red: 0.55, green: 0.39, blue: 0.17),
                             Color(red: 0.84, green: 0.70, blue: 0.42),
                             Color(red: 0.60, green: 0.43, blue: 0.19)]
                case .ribbon: [Color(red: 0.42, green: 0.07, blue: 0.09),
                               Color(red: 0.66, green: 0.15, blue: 0.17),
                               Color(red: 0.45, green: 0.08, blue: 0.10)]
                }
                let lineWidth: CGFloat = ornament.cord == .ribbon ? 1.6 : 1.0
                context.stroke(cord, with: .linearGradient(Gradient(colors: colors),
                    startPoint: CGPoint(x: ornament.eyelet.x - lineWidth / 2, y: 0),
                    endPoint: CGPoint(x: ornament.eyelet.x + lineWidth / 2, y: 0)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
    }
}

/// The cutouts were generated separately, so one shared warm grade and a faint
/// contact shadow put them under the same light as the spruce and wallpaper.
struct ConversationHangingOrnamentBodies: View {
    let ornaments: [ConversationHangingOrnament]
    let tucked: Bool

    var body: some View {
        ForEach(ornaments.filter { $0.tucked == tucked }) { ornament in
            Image(ornament.id)
                .resizable()
                .interpolation(.high)
                .colorMultiply(Color(red: 1, green: 0.97, blue: 0.91))
                .saturation(tucked ? 0.82 : 0.94)
                .brightness(tucked ? -0.04 : 0)
                .shadow(color: Color(red: 0.22, green: 0.13, blue: 0.05).opacity(0.24), radius: 2, y: 1.5)
                .frame(width: ornament.frame.width, height: ornament.frame.height)
                .position(x: ornament.frame.midX, y: ornament.frame.midY)
        }
    }
}
