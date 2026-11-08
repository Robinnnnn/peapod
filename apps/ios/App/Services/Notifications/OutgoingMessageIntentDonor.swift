@preconcurrency import Intents
import Foundation

@MainActor
protocol OutgoingMessageIntentDonating: AnyObject {
    func donate(
        message: ChatMessage,
        conversationID: String,
        recipient: Person
    )
}

/// Donates confirmed outgoing messages so the system can learn that the
/// conversation is a real person-to-person communication channel.
///
/// Message IDs are remembered in the shared app-group defaults. This keeps
/// retries and durable outbox recovery from donating the same message twice.
@MainActor
final class OutgoingMessageIntentDonor: OutgoingMessageIntentDonating {
    typealias DonationCompletion = @Sendable (Error?) -> Void
    typealias DonateInteraction = @MainActor (
        INInteraction,
        @escaping DonationCompletion
    ) -> Void

    private static let donatedMessageIDsKey =
        "OutgoingMessageIntentDonor.donatedMessageIDs.v1"
    private static let maximumRememberedMessageCount = 512

    private let defaults: UserDefaults
    private let donateInteraction: DonateInteraction
    private var donatedMessageIDs: [String]
    private var donatedMessageIDSet: Set<String>
    private var inFlightMessageIDs: Set<String> = []

    init(
        defaults: UserDefaults = UserDefaults(
            suiteName: AppGroup.identifier
        ) ?? .standard,
        donateInteraction: @escaping DonateInteraction = {
            interaction,
            completion in
            interaction.donate(completion: completion)
        }
    ) {
        self.defaults = defaults
        self.donateInteraction = donateInteraction

        let storedIDs = defaults.stringArray(
            forKey: Self.donatedMessageIDsKey
        ) ?? []
        donatedMessageIDs = Array(
            storedIDs.suffix(Self.maximumRememberedMessageCount)
        )
        donatedMessageIDSet = Set(donatedMessageIDs)
    }

    func donate(
        message: ChatMessage,
        conversationID: String,
        recipient: Person
    ) {
        let donationID = "\(conversationID):\(message.id.uuidString)"
        guard
            !donatedMessageIDSet.contains(donationID),
            inFlightMessageIDs.insert(donationID).inserted
        else {
            return
        }

        let recipientHandle = INPersonHandle(
            value: recipient.id,
            type: .unknown
        )
        let intentRecipient = INPerson(
            personHandle: recipientHandle,
            nameComponents: nil,
            displayName: recipient.displayName,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: recipient.id
        )
        let intent = INSendMessageIntent(
            recipients: [intentRecipient],
            outgoingMessageType: message.kind == .voice
                ? .outgoingMessageAudio
                : .outgoingMessageText,
            content: message.replyPreviewText,
            speakableGroupName: nil,
            conversationIdentifier: conversationID,
            serviceName: "Peapod",
            sender: nil,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing

        donateInteraction(interaction) { [weak self] error in
            Task { @MainActor [weak self] in
                self?.finishDonation(
                    donationID: donationID,
                    succeeded: error == nil
                )
            }
        }
    }

    private func finishDonation(
        donationID: String,
        succeeded: Bool
    ) {
        inFlightMessageIDs.remove(donationID)
        guard
            succeeded,
            donatedMessageIDSet.insert(donationID).inserted
        else {
            return
        }

        donatedMessageIDs.append(donationID)
        if donatedMessageIDs.count > Self.maximumRememberedMessageCount {
            donatedMessageIDs.removeFirst(
                donatedMessageIDs.count
                    - Self.maximumRememberedMessageCount
            )
            donatedMessageIDSet = Set(donatedMessageIDs)
        }
        defaults.set(
            donatedMessageIDs,
            forKey: Self.donatedMessageIDsKey
        )
    }
}
