import AppKit
import Foundation
import Testing
@testable import PeapodMac

@MainActor
struct MacStagedPhotoPreviewTests {
    private let target = SecureConversationResetTarget(
        accountID: "owner", conversationID: "chat", sessionID: UUID()
    )

    @Test func resolvesTheUnchangedOriginalForTheCurrentConversation() throws {
        let share = PendingShare(
            kind: .image, conversationID: "chat", conversationOwnerID: "owner",
            localFileName: "original.heic"
        )
        let original = URL(fileURLWithPath: "/tmp/original.heic")
        var resolvedID: UUID?
        let url = try MacStagedPhotoPreviewSource.url(for: share, target: target) {
            resolvedID = $0.id
            return original
        }
        #expect(url == original)
        #expect(resolvedID == share.id)
    }

    @Test func rejectsAnotherAccountConversationAndMissingTargetBeforeResolving() {
        let shares = [
            PendingShare(kind: .image, conversationID: "chat", conversationOwnerID: "another"),
            PendingShare(kind: .image, conversationID: "another", conversationOwnerID: "owner"),
            PendingShare(kind: .image),
            PendingShare(kind: .file, conversationID: "chat", conversationOwnerID: "owner"),
        ]
        var resolutions = 0
        for share in shares {
            #expect(throws: PendingShareStoreError.self) {
                try MacStagedPhotoPreviewSource.url(for: share, target: target) { _ in
                    resolutions += 1
                    return URL(fileURLWithPath: "/tmp/unexpected")
                }
            }
        }
        #expect(throws: PendingShareStoreError.self) {
            try MacStagedPhotoPreviewSource.url(for: shares[0], target: nil) { _ in
                resolutions += 1
                return URL(fileURLWithPath: "/tmp/unexpected")
            }
        }
        #expect(resolutions == 0)
    }

    @Test func localOriginalDecodeLeavesItsBytesUntouched() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("original.png")
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 800,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        try #require(bitmap.bitmapData).initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        try bytes.write(to: url)
        let preview = try #require(await MacAttachmentImageCache.decodeFile(url, maximumPixelSize: 512))
        #expect(max(preview.size.width, preview.size.height) <= 512)
        #expect(abs(preview.size.width / preview.size.height - 2) < 0.01)
        #expect(try Data(contentsOf: url) == bytes)
    }
}
