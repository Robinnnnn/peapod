import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Owns a bounded copy of Photos' temporary file while its provider URL is valid.
/// The file is copied byte for byte and removed after draft staging, including on late cancellation.
final class MacImportedPhotoFile: Sendable {
    let url: URL
    let originalFileName: String
    let contentTypeIdentifier: String
    private let directory: URL

    private init(url: URL, originalFileName: String, contentTypeIdentifier: String, directory: URL) {
        self.url = url
        self.originalFileName = originalFileName
        self.contentTypeIdentifier = contentTypeIdentifier
        self.directory = directory
    }

    static func copy(from source: URL,
                     temporaryRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "peapod-mac-picked-photos", isDirectory: true
                     )) throws -> MacImportedPhotoFile {
        try Task.checkCancellation()
        guard source.isFileURL,
              let type = UTType(filenameExtension: source.pathExtension), type.conforms(to: .image),
              let suffix = type.preferredFilenameExtension else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
            throw CocoaError(.fileReadUnknown)
        }
        let maximumBytes = PendingShareAttachmentPolicy.maximumSendingPhotoBytes
        try PendingShareAttachmentPolicy.validate(byteSize: Int64(size), maximumBytes: maximumBytes)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try SharedProtectedFiles.prepareDirectory(temporaryRoot)
        let directory = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: directory) } }
        try SharedProtectedFiles.prepareDirectory(directory)
        let destination = directory.appendingPathComponent("photo").appendingPathExtension(suffix)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try SharedProtectedFiles.protectFile(destination)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var copied: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try input.read(upToCount: Int(min(64 * 1024, maximumBytes - copied + 1))) ?? Data()
            if chunk.isEmpty { break }
            copied += Int64(chunk.count)
            try PendingShareAttachmentPolicy.validate(byteSize: copied, maximumBytes: maximumBytes)
            try output.write(contentsOf: chunk)
        }
        guard copied == Int64(size) else { throw CocoaError(.fileReadCorruptFile) }
        try Task.checkCancellation()
        completed = true
        return MacImportedPhotoFile(url: destination, originalFileName: source.lastPathComponent,
                                    contentTypeIdentifier: type.identifier, directory: directory)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

/// PhotosPicker grants access to the explicitly chosen items without requiring broad library access.
struct MacImportedPhotoTransfer: Transferable {
    let result: Result<MacImportedPhotoFile, any Error>

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            do { return Self(result: .success(try MacImportedPhotoFile.copy(from: received.file))) }
            catch { return Self(result: .failure(error)) }
        }
    }
}
