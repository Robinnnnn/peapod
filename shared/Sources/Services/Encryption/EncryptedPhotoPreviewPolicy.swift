import Foundation

/// Outgoing encrypted descriptors exist before blob upload. A cloud preview waits for the
/// message acknowledgement; delivered/read receipts do not create additional retry attempts.
enum EncryptedPhotoPreviewPolicy {
    static func isReady(_ attachment: AttachmentContent?, deliveryState: DeliveryState) -> Bool {
        guard attachment?.storagePath?.hasPrefix("e2ee:") == true else { return true }
        switch deliveryState {
        case .sending, .failed: return false
        case .sent, .delivered, .read: return true
        }
    }
    struct LoadKey: Hashable {
        let resource: String
        let cloudReady: Bool
        let manualAttempt: Int
        init(attachment: AttachmentContent?, fallbackID: String, deliveryState: DeliveryState, manualAttempt: Int = 0) {
            resource = attachment?.storagePath ?? attachment?.id ?? fallbackID
            cloudReady = EncryptedPhotoPreviewPolicy.isReady(attachment, deliveryState: deliveryState)
            self.manualAttempt = manualAttempt
        }
    }
}
