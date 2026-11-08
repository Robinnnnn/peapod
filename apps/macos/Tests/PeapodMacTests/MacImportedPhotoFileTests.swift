import AppKit
import Foundation
import Testing
@testable import PeapodMac

struct MacImportedPhotoFileTests {
    @Test func copiesOriginalBytesAndCleansOnlyTheTemporaryCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.png")
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        try #require(bitmap.bitmapData).initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        try bytes.write(to: source)

        let imported = try MacImportedPhotoFile.copy(from: source, temporaryRoot: root.appendingPathComponent("picked"))
        #expect(imported.url != source)
        #expect(imported.originalFileName == "original.png")
        #expect(try Data(contentsOf: imported.url) == bytes)
        imported.cleanUp()
        #expect(!FileManager.default.fileExists(atPath: imported.url.path))
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test func rejectsSymlinksAndOversizedPhotoFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large.png")
        #expect(FileManager.default.createFile(atPath: source.path, contents: nil))
        let file = try FileHandle(forWritingTo: source)
        try file.truncate(atOffset: UInt64(PendingShareAttachmentPolicy.maximumSendingPhotoBytes + 1))
        try file.close()
        #expect(throws: PendingShareStoreError.self) {
            _ = try MacImportedPhotoFile.copy(from: source, temporaryRoot: root.appendingPathComponent("picked"))
        }
        let symlink = root.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        #expect(throws: CocoaError.self) {
            _ = try MacImportedPhotoFile.copy(from: symlink, temporaryRoot: root.appendingPathComponent("picked"))
        }
    }
}
