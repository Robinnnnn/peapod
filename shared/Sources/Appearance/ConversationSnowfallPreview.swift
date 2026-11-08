import SwiftUI

/// Soft-mix snowfall for both native conversations.
struct ConversationSnowfallPreview: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isVisible && scenePhase == .active && !reduceMotion {
                    SoftMixSnowfall()
                        .ignoresSafeArea(.container)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
    }
}

private struct SoftMixSnowfall: View {
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            Canvas { context, size in
                guard size.width > 0, size.height > 0 else { return }
                let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
                // Preserve the sparse phone density as a Mac window grows.
                let count = min(Self.particles.count, max(1, Int(size.width * size.height / 8_500)))
                let columns = max(1, Int(sqrt(Double(count) * size.width / size.height).rounded()))
                let rows = Int(ceil(Double(count) / Double(columns)))
                let flakes = [
                    context.resolve(Image("SnowfallFlakeA")),
                    context.resolve(Image("SnowfallFlakeB"))
                ]
                for (index, particle) in Self.particles.prefix(count).enumerated() {
                    let margin: CGFloat = 16
                    let span = size.height + margin * 2
                    // Jittered cells prefill the whole viewport on the first frame,
                    // rather than waiting for snow to arrive from the top.
                    let initialY = (Double(index / columns) + particle.y) / Double(rows)
                    // Offset each row so the recurring flake never forms one column.
                    let column = (index % columns + index / columns) % columns
                    let initialX = (Double(column) + particle.x) / Double(columns)
                    let y = (initialY * span + elapsed * particle.speed)
                        .truncatingRemainder(dividingBy: span) - margin
                    let drift = elapsed * 3 + sin(elapsed * 0.35 + particle.phase) * particle.sway
                    let x = (initialX * (size.width + margin * 2) + drift)
                        .truncatingRemainder(dividingBy: size.width + margin * 2) - margin
                    var drawing = context
                    drawing.opacity = particle.opacity
                    drawing.translateBy(x: x, y: y)
                    let edge = particle.diameter
                    let rect = CGRect(x: -edge / 2, y: -edge / 2, width: edge, height: edge)
                    if let flake = particle.flake {
                        drawing.rotate(by: .radians(particle.phase + elapsed * 0.08))
                        drawing.draw(flakes[flake], in: rect)
                    } else {
                        drawing.fill(Path(ellipseIn: rect), with: .color(.white))
                    }
                }
            }
        }
        .clipped()
    }

    private struct Particle {
        let x: Double
        let y: Double
        let speed: Double
        let phase: Double
        let sway: Double
        let diameter: Double
        let opacity: Double
        let flake: Int?
    }

    // Stable seeds prevent snow from reshuffling when the conversation updates.
    // Mostly dots with a more legible flake every fourth particle.
    private static let particles: [Particle] = {
        var seed: UInt64 = 144
        func unit() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
        return (0..<96).map { index in
            let flake: Int? = index % 4 == 3 ? (index / 4) % 2 : nil
            return Particle(
                x: unit(), y: unit(), speed: 16 + unit() * 18,
                phase: unit() * .pi * 2, sway: 5 + unit() * 10,
                diameter: flake == nil ? 1.8 + unit() * 1.8 : 9 + unit() * 3,
                opacity: flake == nil ? 0.6 + unit() * 0.3 : 0.8 + unit() * 0.2,
                flake: flake
            )
        }
    }()
}
