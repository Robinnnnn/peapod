import Foundation

/// Boundary between Core Location and the eventual Firestore implementation.
///
/// `publishLatest` is intentionally replace-only: an implementation should use
/// one document per active session and never build a trail of prior points.
protocol LiveLocationPublishing: Sendable {
    func publishLatest(
        _ point: LiveLocationPoint,
        for session: LiveLocationSession
    ) async throws

    func finish(
        _ session: LiveLocationSession,
        reason: LiveLocationStopReason
    ) async
}

struct NoopLiveLocationPublisher: LiveLocationPublishing {
    func publishLatest(
        _ point: LiveLocationPoint,
        for session: LiveLocationSession
    ) async throws {}

    func finish(
        _ session: LiveLocationSession,
        reason: LiveLocationStopReason
    ) async {}
}
