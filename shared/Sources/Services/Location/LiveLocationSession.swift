import Foundation

enum LiveLocationDuration: String, CaseIterable, Codable, Sendable {
    case fifteenMinutes
    case oneHour
    case eightHours
    case untilStopped

    var timeInterval: TimeInterval? {
        switch self {
        case .fifteenMinutes:
            return 900
        case .oneHour:
            return 3_600
        case .eightHours:
            return 28_800
        case .untilStopped:
            return nil
        }
    }
}

struct LiveLocationSession: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let messageID: UUID?
    let startedAt: Date
    let expiresAt: Date?

    init(
        id: UUID = UUID(),
        messageID: UUID? = nil,
        startedAt: Date,
        duration: LiveLocationDuration
    ) {
        self.id = id
        self.messageID = messageID
        self.startedAt = startedAt
        expiresAt = duration.timeInterval.map(startedAt.addingTimeInterval)
    }

    func isActive(at date: Date) -> Bool {
        guard date >= startedAt else { return false }
        return expiresAt.map { date < $0 } ?? true
    }
}

enum LiveLocationStopReason: String, Codable, Hashable, Sendable {
    case stoppedByUser
    case expired
    case authorizationDenied
    case locationUnavailable
}
