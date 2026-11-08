import Foundation

/// Share-process admission only. Main-app photos and videos have a separate 200 MiB limit.
enum ShareExtensionLimits {
    static let maximumAttachmentBytes = 8 * 1024 * 1024
    static let maximumAttachmentAggregateBytes = 8 * 1024 * 1024
    static let reservedCiphertextOverheadBytes = 64 * 1024
    static let maximumCiphertextBytes = maximumAttachmentAggregateBytes + reservedCiphertextOverheadBytes
    enum Failure: LocalizedError {
        case attachmentTooLarge, aggregateTooLarge
        var errorDescription: String? { "Share attachments totaling up to 8 MiB at a time. Open Peapod to send larger files." }
    }
    static func isAdmissionFailure(_ error: any Error) -> Bool {
        if error is Failure { return true }
        if case let PendingShareStoreError.attachmentTooLarge(maximumBytes) = error {
            return maximumBytes > 0 && maximumBytes <= maximumAttachmentBytes
        }
        return false
    }
    static func validateAttachment(_ size: Int) throws {
        guard size > 0, size <= maximumAttachmentBytes else { throw Failure.attachmentTooLarge }
    }
    static func admitAttachment(_ size: Int, used: Int) throws -> Int {
        try validateAttachment(size)
        guard used >= 0, used <= maximumAttachmentAggregateBytes,
              size <= maximumAttachmentAggregateBytes - used else { throw Failure.aggregateTooLarge }
        return used + size
    }
    static func remaining(used: Int) throws -> Int64 {
        guard (0...maximumAttachmentAggregateBytes).contains(used) else { throw Failure.aggregateTooLarge }
        return Int64(min(maximumAttachmentBytes, maximumAttachmentAggregateBytes - used))
    }
    static func requireRemaining(_ maximum: Int64?) throws {
        if let maximum, maximum <= 0 { throw Failure.aggregateTooLarge }
    }
}
