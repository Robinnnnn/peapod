import SwiftUI

/// One stationary strand per attachment. The canvas overdraws its bounds so
/// bulbs can turn outwards without expanding the row or absorbing touches.
struct AttachmentLights: View {
    @Environment(\.usesGiftWrap) private var usesGiftWrap
    let messageID: UUID
    var perimeter: (CGRect) -> CGPath = {
        Path(roundedRect: $0, cornerRadius: 18, style: .continuous).cgPath
    }

    private let margin: CGFloat = 14
    private static let colors: [Color] = [
        Color(red: 0.90, green: 0.38, blue: 0.33),
        Color(red: 0.95, green: 0.71, blue: 0.31),
        Color(red: 0.42, green: 0.68, blue: 0.48),
        Color(red: 0.47, green: 0.64, blue: 0.87),
        Color(red: 0.91, green: 0.56, blue: 0.33)
    ]
    private static let twists: [Double] = [
        -42, 31, -77, 8, 67, -122, -32, 49, 108, 22, -16, 71, 137, -48, 13, -90, 46, 34
    ]

    var body: some View {
        if usesGiftWrap { strand }
    }

    private var strand: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
            guard !bounds.isEmpty else { return }
            let outline = StrandOutline(perimeter(bounds))
            guard outline.length > 1 else { return }
            // Swift's hashValue changes between launches.
            let seed = messageID.uuidString.utf8.reduce(UInt32(2166136261)) {
                ($0 ^ UInt32($1)) &* 16777619
            }
            let phase = CGFloat(seed % 4096) / 4096 * 2 * .pi
            let waves = max(2, (outline.length / 94).rounded())
            func wirePoint(_ fraction: CGFloat) -> CGPoint {
                let sample = outline.sample(at: fraction)
                let angle = fraction * 2 * .pi
                let drift = 1.7 * sin(angle * waves + phase) + 0.55 * sin(angle * (waves + 2) - phase)
                return CGPoint(x: sample.point.x - drift * sample.tangent.dy,
                               y: sample.point.y + drift * sample.tangent.dx)
            }

            var wire = Path()
            wire.move(to: wirePoint(0))
            let samples = Int(ceil(outline.length / 2))
            for index in 1..<samples {
                wire.addLine(to: wirePoint(CGFloat(index) / CGFloat(samples)))
            }
            wire.closeSubpath()
            context.stroke(wire, with: .color(Color(red: 0.22, green: 0.28, blue: 0.24)), lineWidth: 1.35)
            var glint = context
            glint.translateBy(x: 0, y: -0.37)
            glint.stroke(wire, with: .color(Color(red: 0.64, green: 0.67, blue: 0.56).opacity(0.8)), lineWidth: 0.45)

            let bulbs = max(3, Int((outline.length / 23).rounded()))
            for index in 0..<bulbs {
                let jitter = sin(CGFloat(index) * 3.7 + phase)
                let fraction = (CGFloat(index) + 0.4 + 0.12 * jitter) / CGFloat(bulbs)
                let position = wirePoint(fraction)
                var bulb = context
                bulb.translateBy(x: position.x, y: position.y)
                let twist = Self.twists[(index + Int(seed % UInt32(Self.twists.count))) % Self.twists.count]
                bulb.rotate(by: .degrees(twist + 11 * jitter))
                let color = Self.colors[(index + Int(seed % UInt32(Self.colors.count))) % Self.colors.count]
                Self.drawBulb(in: bulb, color: color)
            }
        }
        .padding(-margin)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func drawBulb(in context: GraphicsContext, color: Color) {
        context.fill(Path(ellipseIn: CGRect(x: -3.3, y: 0.6, width: 6.6, height: 8.2)), with: .color(color.opacity(0.12)))
        let socket = Path(roundedRect: CGRect(x: -1.45, y: -0.5, width: 2.9, height: 2.4), cornerRadius: 0.45)
        context.fill(socket, with: .color(Color(red: 0.29, green: 0.33, blue: 0.27)))
        var glass = Path()
        glass.move(to: CGPoint(x: -1.3, y: 1.5))
        glass.addQuadCurve(to: CGPoint(x: 1.35, y: 1.5), control: CGPoint(x: 0, y: 1.1))
        glass.addQuadCurve(to: CGPoint(x: 0.15, y: 9), control: CGPoint(x: 3.65, y: 5.3))
        glass.addQuadCurve(to: CGPoint(x: -1.3, y: 1.5), control: CGPoint(x: -3.5, y: 5.7))
        glass.closeSubpath()
        context.fill(glass, with: .linearGradient(Gradient(colors: [color, color, color.mix(with: .black, by: 0.25)]),
                                                   startPoint: CGPoint(x: -2, y: 4), endPoint: CGPoint(x: 2, y: 5)))
        var reflection = Path()
        reflection.move(to: CGPoint(x: -0.65, y: 2.7))
        reflection.addQuadCurve(to: CGPoint(x: -1.0, y: 4.85), control: CGPoint(x: -1.3, y: 3.7))
        context.stroke(reflection, with: .color(.white.opacity(0.76)), style: StrokeStyle(lineWidth: 0.65, lineCap: .round))
    }
}

/// Arc-length positions keep bulb spacing consistent on different card sizes
/// and around the combined silhouette of overlapping, rotated photos.
private struct StrandOutline {
    private struct Edge {
        let start: CGPoint
        let tangent: CGVector
        let offset: CGFloat
    }
    private var edges: [Edge] = []
    private(set) var length: CGFloat = 0

    init(_ path: CGPath) {
        var points: [CGPoint] = []
        path.flattened(threshold: 0.25).applyWithBlock { element in
            if element.pointee.type == .moveToPoint || element.pointee.type == .addLineToPoint {
                points.append(element.pointee.points[0])
            }
        }
        guard let first = points.first else { return }
        for (start, end) in zip(points, points.dropFirst() + [first]) {
            let dx = end.x - start.x, dy = end.y - start.y
            let distance = hypot(dx, dy)
            guard distance > 0 else { continue }
            edges.append(Edge(start: start, tangent: CGVector(dx: dx / distance, dy: dy / distance), offset: length))
            length += distance
        }
    }

    func sample(at fraction: CGFloat) -> (point: CGPoint, tangent: CGVector) {
        let distance = fraction * length
        var low = 0, high = edges.count
        while high - low > 1 {
            let middle = (low + high) / 2
            if edges[middle].offset <= distance { low = middle } else { high = middle }
        }
        let edge = edges[low]
        let delta = distance - edge.offset
        return (CGPoint(x: edge.start.x + delta * edge.tangent.dx, y: edge.start.y + delta * edge.tangent.dy), edge.tangent)
    }
}
