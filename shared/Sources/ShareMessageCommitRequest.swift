import Foundation

enum ShareMessageCommitRequestError: LocalizedError {
    case invalidPayload

    var errorDescription: String? {
        "The shared item is empty or is missing its original conversation."
    }
}

struct ShareMessageCommitRequest {
    static func make(
        share: PendingShare,
        userID: String,
        projectID: String,
        token: String
    ) throws -> URLRequest {
        guard
            share.kind == .text || share.kind == .url,
            let text = share.text?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !text.isEmpty,
            text.count <= 10_000,
            let conversationID = share.targetConversationID,
            !userID.isEmpty
        else {
            throw ShareMessageCommitRequestError.invalidPayload
        }

        let documentName = [
            "projects",
            projectID,
            "databases",
            "(default)",
            "documents",
            "conversations",
            conversationID,
            "messages",
            share.id.uuidString,
        ].joined(separator: "/")
        let messageType = share.kind == .url ? "link" : "text"
        let payload: [String: Any] = [
            "writes": [
                [
                    "update": [
                        "name": documentName,
                        "fields": [
                            "senderId": ["stringValue": userID],
                            "clientId": [
                                "stringValue": share.id.uuidString,
                            ],
                            "type": ["stringValue": messageType],
                            "text": ["stringValue": text],
                        ],
                    ],
                    "updateTransforms": [
                        [
                            "fieldPath": "createdAt",
                            "setToServerValue": "REQUEST_TIME",
                        ],
                    ],
                    "currentDocument": ["exists": false],
                ],
            ],
        ]
        let url = URL(
            string: """
            https://firestore.googleapis.com/v1/projects/\(projectID)/\
            databases/(default)/documents:commit
            """
        )!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = try JSONSerialization.data(
            withJSONObject: payload
        )
        return request
    }
}
