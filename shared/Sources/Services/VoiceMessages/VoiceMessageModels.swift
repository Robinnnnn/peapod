import Foundation
import UniformTypeIdentifiers

struct VoiceMessageDraft: Identifiable, Hashable, Sendable {
    static let contentTypeIdentifier = "public.mpeg-4-audio"
    static let preferredFilenameExtension = "m4a"

    let id: UUID
    let fileURL: URL
    let duration: TimeInterval
    let byteSize: Int64
    let createdAt: Date

    init(
        id: UUID = UUID(),
        fileURL: URL,
        duration: TimeInterval,
        byteSize: Int64,
        createdAt: Date = .now
    ) {
        self.id = id
        self.fileURL = fileURL
        self.duration = max(0, duration)
        self.byteSize = max(0, byteSize)
        self.createdAt = createdAt
    }

    var suggestedFileName: String {
        "Voice Message \(Self.filenameDateFormatter.string(from: createdAt)).m4a"
    }

    var durationMilliseconds: Int {
        Int((duration * 1_000).rounded())
    }

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()
}

struct StagedVoiceMessage: Sendable {
    let pendingShare: PendingShare
    let duration: TimeInterval
    let byteSize: Int64

    var durationMilliseconds: Int {
        Int((duration * 1_000).rounded())
    }
}

extension PendingShare {
    /// Voice messages intentionally use `.file` so they remain compatible with
    /// older outbox decoders. A small text marker distinguishes an in-app
    /// recording from an arbitrary audio file shared into the app.
    var isVoiceMessage: Bool {
        guard
            let contentTypeIdentifier,
            contentTypeIdentifier == VoiceMessageDraft.contentTypeIdentifier
                || UTType(contentTypeIdentifier)?.conforms(to: .audio) == true
        else {
            return false
        }
        return voiceMessageDuration != nil
    }

    var voiceMessageDuration: TimeInterval? {
        guard
            let text,
            text.hasPrefix(Self.voiceDurationMetadataPrefix),
            let milliseconds = Int(
                text.dropFirst(Self.voiceDurationMetadataPrefix.count)
            ),
            milliseconds >= 0
        else {
            return nil
        }
        return TimeInterval(milliseconds) / 1_000
    }

    func markingAsVoiceMessage(
        duration: TimeInterval
    ) -> PendingShare {
        let milliseconds = max(0, Int((duration * 1_000).rounded()))
        return PendingShare(
            id: id,
            kind: kind,
            text: "\(Self.voiceDurationMetadataPrefix)\(milliseconds)",
            conversationID: conversationID,
            conversationOwnerID: conversationOwnerID,
            localFileName: localFileName,
            originalFileName: originalFileName,
            contentTypeIdentifier: contentTypeIdentifier,
            deliveryMode: nil,
            createdAt: createdAt
        )
    }

    private static let voiceDurationMetadataPrefix =
        "mines-voice-duration-ms:"
}

enum VoiceMessagePolicy {
    static let minimumDuration: TimeInterval = 0.25
    static let maximumDuration: TimeInterval = 10 * 60
    static let maximumDownloadByteSize: Int64 = 100 * 1_024 * 1_024
    static let meterSamplingInterval: TimeInterval = 0.05
    static let maximumMeterSampleCount =
        Int(maximumDuration / meterSamplingInterval) + 1

    static func normalizedMeterLevel(decibels: Float) -> Double {
        guard decibels.isFinite else { return 0 }

        let floor: Float = -55
        let clamped = min(0, max(floor, decibels))
        let linear = pow(10, clamped / 20)
        return min(1, max(0, Double(linear)))
    }

    static func appendMeterLevel(
        _ level: Double,
        to samples: inout [Double]
    ) {
        samples.append(min(1, max(0, level)))
        if samples.count > maximumMeterSampleCount {
            samples.removeFirst(samples.count - maximumMeterSampleCount)
        }
    }

    static func liveWaveformSamples(
        from samples: [Double],
        count: Int
    ) -> [Double] {
        guard count > 0 else { return [] }
        let visible = Array(samples.suffix(count))
        return Array(repeating: 0, count: max(0, count - visible.count))
            + visible
    }

    static func overviewWaveformSamples(
        from samples: [Double],
        count: Int
    ) -> [Double] {
        guard count > 0 else { return [] }
        guard !samples.isEmpty else {
            return Array(repeating: 0, count: count)
        }
        guard samples.count > count else {
            guard samples.count > 1, count > 1 else {
                return Array(repeating: samples[0], count: count)
            }
            return (0..<count).map { index in
                let position = Double(index) / Double(count - 1)
                let sourceIndex = Int(
                    (position * Double(samples.count - 1)).rounded()
                )
                return samples[sourceIndex]
            }
        }

        return (0..<count).map { index in
            let lowerBound = index * samples.count / count
            let upperBound = max(
                lowerBound + 1,
                (index + 1) * samples.count / count
            )
            return samples[lowerBound..<min(upperBound, samples.count)]
                .max() ?? 0
        }
    }
}

enum VoiceMessageDurationText {
    static func string(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

enum VoiceMessageError: LocalizedError, Equatable {
    case microphonePermissionDenied
    case couldNotStartRecording
    case recordingTooShort
    case missingRecording
    case emptyRecording
    case downloadTooLarge
    case invalidDownloadResponse

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone access is off. Allow it in Settings to record a voice message."
        case .couldNotStartRecording:
            "The voice message could not start recording."
        case .recordingTooShort:
            "Hold on a moment longer before sending the voice message."
        case .missingRecording:
            "The voice recording is no longer available."
        case .emptyRecording:
            "The voice recording is empty."
        case .downloadTooLarge:
            "This voice message is too large to play."
        case .invalidDownloadResponse:
            "The voice message could not be downloaded."
        }
    }
}
