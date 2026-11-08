import Foundation
import SwiftUI

struct ReactionBurstEvent: Equatable, Identifiable, Sendable {
    let id: UUID
    let messageID: UUID
    let reactorID: String
    let emoji: String

    init(
        id: UUID = UUID(),
        messageID: UUID,
        reactorID: String,
        emoji: String
    ) {
        self.id = id
        self.messageID = messageID
        self.reactorID = reactorID
        self.emoji = emoji
    }
}

struct ReactionBurstCandidate: Equatable, Sendable {
    let messageID: UUID
    let reactorID: String
    let emoji: String
}

struct ReactionBurstReplayState: Equatable, Sendable {
    var snapshot: ReactionBurstDetection.Snapshot
    var pendingCandidates: [ReactionBurstCandidate]
}

@MainActor
protocol ReactionBurstReplayStoring: AnyObject {
    func load(
        conversationID: String,
        userID: String
    ) -> ReactionBurstReplayState?

    func save(
        _ state: ReactionBurstReplayState,
        conversationID: String,
        userID: String
    )

    func remove(conversationID: String, userID: String)
}

@MainActor
final class UserDefaultsReactionBurstReplayStore:
    ReactionBurstReplayStoring
{
    private struct Payload: Codable {
        struct PendingCandidate: Codable {
            let messageID: String
            let reactorID: String
            let emoji: String
        }

        let snapshot: [String: [String: String]]
        let pendingCandidates: [PendingCandidate]
    }

    private static let keyPrefix = "reaction-burst-replay.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(
        conversationID: String,
        userID: String
    ) -> ReactionBurstReplayState? {
        guard
            let data = defaults.data(
                forKey: key(conversationID: conversationID, userID: userID)
            ),
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return nil
        }

        let snapshot = payload.snapshot.reduce(
            into: ReactionBurstDetection.Snapshot()
        ) { result, entry in
            guard let messageID = UUID(uuidString: entry.key) else { return }
            result[messageID] = entry.value
        }
        let pendingCandidates = payload.pendingCandidates.compactMap {
            candidate -> ReactionBurstCandidate? in
            guard
                let messageID = UUID(uuidString: candidate.messageID),
                !candidate.emoji.isEmpty
            else {
                return nil
            }
            return ReactionBurstCandidate(
                messageID: messageID,
                reactorID: candidate.reactorID,
                emoji: candidate.emoji
            )
        }
        return ReactionBurstReplayState(
            snapshot: snapshot,
            pendingCandidates: pendingCandidates
        )
    }

    func save(
        _ state: ReactionBurstReplayState,
        conversationID: String,
        userID: String
    ) {
        let payload = Payload(
            snapshot: Dictionary(
                uniqueKeysWithValues: state.snapshot.map {
                    ($0.key.uuidString, $0.value)
                }
            ),
            pendingCandidates: state.pendingCandidates.map {
                Payload.PendingCandidate(
                    messageID: $0.messageID.uuidString,
                    reactorID: $0.reactorID,
                    emoji: $0.emoji
                )
            }
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(
            data,
            forKey: key(conversationID: conversationID, userID: userID)
        )
    }

    func remove(conversationID: String, userID: String) {
        defaults.removeObject(
            forKey: key(conversationID: conversationID, userID: userID)
        )
    }

    private func key(conversationID: String, userID: String) -> String {
        let scope = Data("\(conversationID)\u{0}\(userID)".utf8)
            .base64EncodedString()
        return "\(Self.keyPrefix).\(scope)"
    }
}

enum ReactionBurstDetection {
    typealias Snapshot = [UUID: [String: String]]

    static func snapshot(for messages: [ChatMessage]) -> Snapshot {
        Dictionary(
            uniqueKeysWithValues: messages.compactMap { message in
                guard !message.reactions.isEmpty else { return nil }
                return (message.id, message.reactions)
            }
        )
    }

}

enum ReactionBurstReplayPolicy {
    static let maximumMappedPendingCandidates = ConversationHistoryPolicy.pageSize * 2
    private struct ReactionKey: Hashable {
        let messageID: UUID
        let reactorID: String
    }

    static func reconciledPendingCandidates(
        _ pendingCandidates: [ReactionBurstCandidate],
        from previous: ReactionBurstDetection.Snapshot,
        to current: ReactionBurstDetection.Snapshot,
        currentUserID: String
    ) -> [ReactionBurstCandidate] {
        let previousKeys = reactionKeys(in: previous)
        let currentKeys = reactionKeys(in: current)
        let changedKeys = previousKeys.union(currentKeys)
            .filter {
                previous[$0.messageID]?[$0.reactorID]
                    != current[$0.messageID]?[$0.reactorID]
            }
            .sorted {
                if $0.messageID != $1.messageID {
                    return $0.messageID.uuidString
                        < $1.messageID.uuidString
                }
                return $0.reactorID < $1.reactorID
            }

        var reconciled = pendingCandidates
        for key in changedKeys {
            reconciled.removeAll {
                $0.messageID == key.messageID
                    && $0.reactorID == key.reactorID
            }
            guard
                key.reactorID != currentUserID,
                let emoji = current[key.messageID]?[key.reactorID],
                !emoji.isEmpty
            else {
                continue
            }
            reconciled.append(
                ReactionBurstCandidate(
                    messageID: key.messageID,
                    reactorID: key.reactorID,
                    emoji: emoji
                )
            )
        }
        return reconciled
    }

    /// New rows in a history window establish their baseline; only changes to
    /// mapped rows can become live cues. Keep pending cues tied to mapped IDs.
    static func reconciledMappedCandidates(
        _ pending: [ReactionBurstCandidate],
        from previous: ReactionBurstDetection.Snapshot,
        to current: ReactionBurstDetection.Snapshot,
        currentUserID: String
    ) -> [ReactionBurstCandidate] {
        Array(reconciledPendingCandidates(pending.filter { current[$0.messageID] != nil },
            from: previous.filter { current[$0.key] != nil },
            to: current.filter { previous[$0.key] != nil }, currentUserID: currentUserID)
            .suffix(maximumMappedPendingCandidates))
    }

    private static func reactionKeys(
        in snapshot: ReactionBurstDetection.Snapshot
    ) -> Set<ReactionKey> {
        Set(
            snapshot.flatMap { messageID, reactions in
                reactions.keys.map {
                    ReactionKey(messageID: messageID, reactorID: $0)
                }
            }
        )
    }
}

enum ReactionBurstAnimationPolicy {
    struct Particle: Equatable, Identifiable {
        let id: Int
        let startX: CGFloat
        let endX: CGFloat
        let startYOffset: CGFloat
        let endYOffset: CGFloat
        let rotation: Angle
        let size: CGFloat
        let opacity: Double
        let delay: TimeInterval
    }

    static let duration: TimeInterval = 1.7
    static let fadeDuration: TimeInterval = 0.55
    static let ignoresReduceMotion = true
    static let particles: [Particle] = [
        Particle(
            id: 0,
            startX: 0.08,
            endX: 0.20,
            startYOffset: 28,
            endYOffset: 34,
            rotation: .degrees(-22),
            size: 56,
            opacity: 0.34,
            delay: 0.00
        ),
        Particle(
            id: 1,
            startX: 0.24,
            endX: 0.12,
            startYOffset: 82,
            endYOffset: 74,
            rotation: .degrees(18),
            size: 72,
            opacity: 0.24,
            delay: 0.12
        ),
        Particle(
            id: 2,
            startX: 0.41,
            endX: 0.52,
            startYOffset: 44,
            endYOffset: 24,
            rotation: .degrees(-14),
            size: 62,
            opacity: 0.40,
            delay: 0.04
        ),
        Particle(
            id: 3,
            startX: 0.60,
            endX: 0.72,
            startYOffset: 102,
            endYOffset: 82,
            rotation: .degrees(24),
            size: 80,
            opacity: 0.22,
            delay: 0.18
        ),
        Particle(
            id: 4,
            startX: 0.77,
            endX: 0.66,
            startYOffset: 36,
            endYOffset: 48,
            rotation: .degrees(-20),
            size: 60,
            opacity: 0.36,
            delay: 0.08
        ),
        Particle(
            id: 5,
            startX: 0.92,
            endX: 0.84,
            startYOffset: 72,
            endYOffset: 20,
            rotation: .degrees(16),
            size: 70,
            opacity: 0.28,
            delay: 0.22
        ),
        Particle(
            id: 6,
            startX: 0.16,
            endX: 0.34,
            startYOffset: 118,
            endYOffset: 54,
            rotation: .degrees(-26),
            size: 66,
            opacity: 0.31,
            delay: 0.28
        ),
        Particle(
            id: 7,
            startX: 0.34,
            endX: 0.24,
            startYOffset: 58,
            endYOffset: 96,
            rotation: .degrees(20),
            size: 84,
            opacity: 0.20,
            delay: 0.34
        ),
        Particle(
            id: 8,
            startX: 0.52,
            endX: 0.42,
            startYOffset: 26,
            endYOffset: 38,
            rotation: .degrees(-16),
            size: 54,
            opacity: 0.42,
            delay: 0.26
        ),
        Particle(
            id: 9,
            startX: 0.70,
            endX: 0.82,
            startYOffset: 94,
            endYOffset: 70,
            rotation: .degrees(26),
            size: 76,
            opacity: 0.25,
            delay: 0.38
        ),
        Particle(
            id: 10,
            startX: 0.86,
            endX: 0.96,
            startYOffset: 48,
            endYOffset: 44,
            rotation: .degrees(-18),
            size: 64,
            opacity: 0.33,
            delay: 0.30
        ),
        Particle(
            id: 11,
            startX: 0.48,
            endX: 0.60,
            startYOffset: 132,
            endYOffset: 112,
            rotation: .degrees(22),
            size: 88,
            opacity: 0.18,
            delay: 0.44
        ),
    ]

    static var completionDelay: TimeInterval {
        duration + (particles.map(\.delay).max() ?? 0) + 0.15
    }
}

struct ReactionEmojiBurstView: View {
    let event: ReactionBurstEvent
    let onFinished: () -> Void

    @State private var isRising = false
    @State private var isFading = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(ReactionBurstAnimationPolicy.particles) { particle in
                    Text(event.emoji)
                        .font(.system(size: particle.size))
                        .scaleEffect(isRising ? 1.08 : 0.82)
                        .rotationEffect(
                            isRising ? particle.rotation : .zero
                        )
                        .position(
                            x:
                                (isRising
                                    ? particle.endX
                                    : particle.startX)
                                * geometry.size.width,
                            y:
                                isRising
                                ? -particle.size - particle.endYOffset
                                : geometry.size.height
                                    + particle.size
                                    + particle.startYOffset
                        )
                        .opacity(isFading ? 0 : particle.opacity)
                        .animation(
                            .easeOut(
                                duration:
                                    ReactionBurstAnimationPolicy.duration
                            )
                            .delay(particle.delay),
                            value: isRising
                        )
                        .animation(
                            .easeIn(
                                duration:
                                    ReactionBurstAnimationPolicy.fadeDuration
                            )
                            .delay(particle.delay),
                            value: isFading
                        )
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: event.id) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            isRising = true
            try? await Task.sleep(
                for: .seconds(
                    ReactionBurstAnimationPolicy.duration * 0.6
                )
            )
            guard !Task.isCancelled else { return }
            isFading = true
            try? await Task.sleep(
                for: .seconds(
                    ReactionBurstAnimationPolicy.completionDelay
                        - ReactionBurstAnimationPolicy.duration * 0.6
                )
            )
            guard !Task.isCancelled else { return }
            onFinished()
        }
    }
}
