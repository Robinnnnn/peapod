import Foundation
import CoreGraphics

enum ConversationViewportRowID: Hashable {
    case controls
    case message(UUID)
    case empty
    case typing
    case footer
}

struct ConversationViewportCommand: Equatable {
    enum Destination: Equatable {
        case latest
        case preserve
        case message(UUID)
    }

    let serial: Int
    let destination: Destination
}

/// Positions belong to the conversation screen. A remounted collection must inherit
/// the reader's place rather than interpreting its own initial offset as a user choice.
@MainActor
final class ConversationViewport {
    struct Landmark {
        let message: UUID
        let members: [UUID]
        let offsetInRow: CGFloat
        let offsetInViewport: CGFloat
    }

    enum Position {
        case latest
        case reading([Landmark])
        case top
    }

    private(set) var position: Position = .latest
    private(set) var pendingDestination: ConversationViewportCommand.Destination?
    private var normalPosition: Position?
    private var searchQuery: String?
    private var lastCommand: Int?

    /// Query transitions happen before explicit navigation so an accepted send
    /// or reply jump can supersede the automatic restoration on search dismissal.
    func update(
        query: String?, command: ConversationViewportCommand?,
        visibleLandmarks: () -> [Landmark]
    ) {
        if query != searchQuery {
            if query != nil {
                if searchQuery == nil { normalPosition = position }
                position = .top
            } else {
                position = normalPosition ?? .latest
                normalPosition = nil
            }
            searchQuery = query
            pendingDestination = nil
        }
        guard let command, command.serial != lastCommand else { return }
        lastCommand = command.serial
        switch command.destination {
        case .latest, .message:
            pendingDestination = command.destination
        case .preserve:
            beginReading(visibleLandmarks())
        }
    }

    func cancelNavigation(through serial: Int?) {
        if let serial { lastCommand = serial }
        pendingDestination = nil
    }

    func beginReading(_ landmarks: [Landmark]) {
        pendingDestination = nil
        position = .reading(landmarks)
    }

    func followLatest() {
        pendingDestination = nil
        position = .latest
    }

    func finishJump(_ landmarks: [Landmark]) {
        beginReading(landmarks)
    }
}
