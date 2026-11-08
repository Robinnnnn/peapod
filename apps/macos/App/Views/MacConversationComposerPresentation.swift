import AppKit
import SwiftUI

/// One surface for the editor, attachments, reply and recording controls.
struct MacConversationGlassSurface: ViewModifier {
    let reduceTransparency: Bool
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let panel = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: panel)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: panel)
        } else {
            content.background(.regularMaterial, in: panel)
                .overlay { panel.strokeBorder(.primary.opacity(0.12)).allowsHitTesting(false) }
        }
    }
}

/// Repositions the same field instead of switching view branches, preserving
/// AppKit selection, marked text, focus and an in-flight paste as text wraps.
struct MacComposerInputLayout: Layout {
    let controlSize: CGFloat
    private let singleLineHeight: CGFloat = 40

    private func fieldSize(width: CGFloat, subviews: Subviews) -> (CGSize, expanded: Bool) {
        let compactWidth = max(1, width - 2 * controlSize)
        let compact = subviews[1].sizeThatFits(.init(width: compactWidth, height: nil))
        if compact.height <= singleLineHeight + 1 {
            return (CGSize(width: compactWidth, height: compact.height), false)
        }
        let expandedWidth = max(1, width - 24)
        let expanded = subviews[1].sizeThatFits(.init(width: expandedWidth, height: nil))
        return (CGSize(width: expandedWidth, height: expanded.height), true)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 320
        let (field, expanded) = fieldSize(width: width, subviews: subviews)
        return CGSize(width: width,
                      height: expanded ? field.height + controlSize : max(field.height, controlSize))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (field, expanded) = fieldSize(width: bounds.width, subviews: subviews)
        let controlsY = expanded ? bounds.maxY - controlSize : bounds.midY - controlSize / 2
        let control = ProposedViewSize(width: controlSize, height: controlSize)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: controlsY), anchor: .topLeading, proposal: control)
        subviews[1].place(
            at: CGPoint(x: bounds.minX + (expanded ? 12 : controlSize),
                        y: expanded ? bounds.minY : bounds.midY - field.height / 2),
            anchor: .topLeading, proposal: .init(field)
        )
        subviews[2].place(at: CGPoint(x: bounds.maxX - controlSize, y: controlsY),
                          anchor: .topLeading, proposal: control)
    }
}

struct MacRecordingWaveform: View {
    let samples: [Double]

    var body: some View {
        Canvas { context, size in
            let count = 48
            let step = size.width / CGFloat(count)
            let displayed = Array(repeating: 0.0, count: max(0, count - samples.count)) + Array(samples.suffix(count))
            for (index, level) in displayed.enumerated() {
                let height = max(3, size.height * min(max(level, 0), 1))
                let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2,
                                  width: max(1, step - 2), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.accentColor))
            }
        }
        .accessibilityHidden(true)
    }
}
