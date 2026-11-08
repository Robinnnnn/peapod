import SwiftUI

/// A drawing-only activity indicator. Native ProgressView controls cannot be
/// sampled by the conversation's layer shader and appear as a prohibited symbol.
/// Timeline-driven drawing also survives recycled cells that disable animations.
struct ActivitySpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var size: CGFloat = 20
    var color: Color = .secondary

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: reduceMotion || scenePhase != .active)) { context in
            let phase = reduceMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 12)
            Canvas { context, bounds in
                let width = size * 0.085
                let spoke = Path(roundedRect: CGRect(x: -width / 2, y: -size / 2,
                                                     width: width, height: size * 0.25),
                                 cornerRadius: width / 2)
                for index in 0..<12 {
                    var rotated = context
                    rotated.translateBy(x: bounds.width / 2, y: bounds.height / 2)
                    rotated.rotate(by: .degrees(Double(index) * 30))
                    let opacity = Double((index - phase + 12) % 12 + 1) / 12
                    rotated.fill(spoke, with: .color(color.opacity(opacity)))
                }
            }
            // The whole wheel must be inside the drawing layer. Offset/rotated
            // capsules in an intrinsically tiny ZStack are overdraw and can be
            // clipped by the timeline's layer effect even when layout fits.
            .frame(width: size, height: size)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}
