import Observation
import SwiftUI

/// Coordinates contain no message/media data and do not participate in row sizing.
/// All positions are points in the full-screen timeline viewport: y = 0 is the
/// physical top of the screen and `viewportHeight` its physical bottom.
///
/// Profile: each band runs from a clear line (sigma 0) to the edge of the visible
/// drawing. With normalized depth u in [0, 1], sigma = bandSigma * u^2 and the
/// Gaussian support is 3 * sigma. Strength eases in across several text lines and
/// peaks only at the edge itself, so no full-strength plateau precedes it.
struct ConversationEdgeBlurParameters: Equatable {
    var originY: CGFloat = 0
    var viewportHeight: CGFloat = 0
    /// Measured header-bar boundary: the top of the readable viewport.
    var topInset: CGFloat = 0
    /// Measured distance from the composer bar's top to the physical bottom,
    /// including a docked keyboard.
    var bottomInset: CGFloat = 0
    /// The docked keyboard's top or, without one, the physical bottom. Zero means unmeasured.
    var visibleBottom: CGFloat = 0
    var isEnabled = false

    static let inactive = ConversationEdgeBlurParameters()
    static let maximumSigma: CGFloat = 4
    /// Gaussian support (3 sigma) at maximum strength; also the shader's sample bound.
    static let maximumRadius: CGFloat = 12
    /// Short bands get proportionally weaker peaks, bounding how fast sigma changes.
    static let sigmaPerRampPoint: CGFloat = 0.04
    static let minimumRamp: CGFloat = 12
    /// Keeps the newest line crisp just above the composer glass.
    static let bottomLead: CGFloat = 16
    static let cellCoordinateSpace = "conversation-timeline-cell"

    var topEdge: CGFloat { 0 }
    var topClear: CGFloat { topInset.isFinite ? max(0, topInset) : 0 }
    var topSigma: CGFloat { Self.sigma(forRamp: topClear - topEdge) }

    var bottomClear: CGFloat {
        let clear = viewportHeight - bottomInset - Self.bottomLead
        return clear.isFinite ? max(0, clear) : 0
    }
    var bottomEdge: CGFloat {
        visibleBottom > 0 && visibleBottom.isFinite ? min(visibleBottom, viewportHeight) : viewportHeight
    }
    var bottomSigma: CGFloat {
        guard bottomInset > 0, viewportHeight > 0 else { return 0 }
        return Self.sigma(forRamp: bottomEdge - bottomClear)
    }

    static func sigma(forRamp length: CGFloat) -> CGFloat {
        guard length.isFinite, length >= minimumRamp else { return 0 }
        return min(maximumSigma, length * sigmaPerRampPoint)
    }

    /// A measured keyboard top is accepted only between the composer bar's top and
    /// the physical bottom; anything else falls back to the physical bottom.
    static func visibleBottom(keyboardTop: CGFloat?, viewportHeight: CGFloat, bottomInset: CGFloat) -> CGFloat {
        let bottom = viewportHeight.isFinite ? max(0, viewportHeight) : 0
        guard let keyboardTop, keyboardTop.isFinite, bottom > 0, bottomInset.isFinite else { return bottom }
        let composerTop = bottom - bottomInset
        guard keyboardTop >= composerTop, keyboardTop < bottom else { return bottom }
        return keyboardTop
    }

    func intersectsBlur(rowHeight: CGFloat) -> Bool {
        (topSigma > 0 && originY < topClear && originY + rowHeight > topEdge)
            || (bottomSigma > 0 && originY + rowHeight > bottomClear && originY < viewportHeight)
    }
}

@MainActor
@Observable
final class ConversationEdgeBlurState {
    var parameters = ConversationEdgeBlurParameters.inactive
}

extension EnvironmentValues {
    @Entry var conversationEdgeBlur: ConversationEdgeBlurState? = nil
}

/// Filter only SwiftUI drawing, leaving native geometry/interaction markers outside
/// the shader. Two Gaussian passes vary their sampling radius by screen position;
/// no material, tint, snapshots, or sharp/blur opacity blend is involved.
struct ConversationEdgeBlurModifier: ViewModifier {
    @Environment(\.conversationEdgeBlur) private var state
    @Environment(\.displayScale) private var displayScale

    @ViewBuilder
    func body(content: Content) -> some View {
        if let parameters = state?.parameters {
            content.visualEffect { drawing, geometry in
                let origin = parameters.originY
                    + geometry.frame(in: .named(ConversationEdgeBlurParameters.cellCoordinateSpace)).minY
                return drawing
                    .layerEffect(shader(parameters, origin: origin, axis: CGSize(width: 1, height: 0)),
                        maxSampleOffset: CGSize(width: ConversationEdgeBlurParameters.maximumRadius, height: 0),
                        isEnabled: parameters.isEnabled)
                    .layerEffect(shader(parameters, origin: origin, axis: CGSize(width: 0, height: 1)),
                        maxSampleOffset: CGSize(width: 0, height: ConversationEdgeBlurParameters.maximumRadius),
                        isEnabled: parameters.isEnabled)
            }
        } else {
            content
        }
    }

    private func shader(_ parameters: ConversationEdgeBlurParameters, origin: CGFloat, axis: CGSize) -> Shader {
        ShaderLibrary.conversationEdgeBlur(
            .float(Float(origin)),
            .float4(Float(parameters.topEdge), Float(parameters.topClear),
                    Float(parameters.bottomClear), Float(parameters.bottomEdge)),
            .float2(Float(parameters.topSigma), Float(parameters.bottomSigma)),
            .float2(axis), .float(Float(ConversationEdgeBlurParameters.maximumRadius)),
            .float(Float(1 / max(displayScale, 1)))
        )
    }
}
