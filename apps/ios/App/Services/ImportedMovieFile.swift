import CoreTransferable
import Foundation
import MinesE2EE
import UniformTypeIdentifiers

/// Owns a bounded, untouched endpoint copy while Photos' provider URL is still valid.
/// Reference ownership ensures a late/cancelled Transferable result also removes its copy.
final class ImportedMediaFile: Sendable {
    static let maximumByteSize = Int64(POCLimits.attachmentPlaintextBytes)
    let url: URL
    let originalFileName: String
    let contentTypeIdentifier: String
    private let directory: URL

    private init(url: URL, originalFileName: String, contentTypeIdentifier: String, directory: URL) {
        self.url = url; self.originalFileName = originalFileName
        self.contentTypeIdentifier = contentTypeIdentifier; self.directory = directory
    }
    static func copy(from source: URL, maximumBytes: Int64 = maximumByteSize,
                     temporaryRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("mines-picked-movies", isDirectory: true),
                     kind: PendingShare.Kind = .movie) throws -> ImportedMediaFile {
        try Task.checkCancellation()
        guard source.isFileURL, maximumBytes > 0, maximumBytes <= maximumByteSize,
              kind == .movie || kind == .image,
              let type = UTType(filenameExtension: source.pathExtension),
              type.conforms(to: kind == .movie ? .movie : .image),
              let suffix = type.preferredFilenameExtension else { throw CocoaError(.fileReadUnsupportedScheme) }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
            throw CocoaError(.fileReadUnknown)
        }
        try PendingShareAttachmentPolicy.validate(byteSize: Int64(size), maximumBytes: maximumBytes)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try SharedProtectedFiles.prepareDirectory(temporaryRoot)
        let directory = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: directory) } }
        try SharedProtectedFiles.prepareDirectory(directory)
        let destination = directory.appendingPathComponent(kind == .movie ? "movie" : "photo").appendingPathExtension(suffix)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
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
        return ImportedMediaFile(url: destination, originalFileName: source.lastPathComponent,
            contentTypeIdentifier: type.identifier, directory: directory)
    }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

typealias ImportedMovieFile = ImportedMediaFile

/// CoreTransferable discards errors thrown by importers and replaces them with “Cannot import”.
/// Carry the outcome across that boundary so size, file and cancellation errors reach the caller.
struct ImportedMovieTransfer: Transferable {
    let result: Result<ImportedMovieFile, any Error>

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            do { return Self(result: .success(try ImportedMovieFile.copy(from: received.file))) }
            catch { return Self(result: .failure(error)) }
        }
    }
}

/// Photos supplies a file representation so the original is bounded before loading bytes
/// or decoding a thumbnail. Import failures retain their useful admission error.
struct ImportedPhotoTransfer: Transferable {
    let result: Result<ImportedMediaFile, any Error>

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            do {
                return Self(result: .success(try ImportedMediaFile.copy(from: received.file,
                    maximumBytes: PendingShareAttachmentPolicy.maximumSendingPhotoBytes,
                    temporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent("mines-picked-photos", isDirectory: true),
                    kind: .image)))
            } catch { return Self(result: .failure(error)) }
        }
    }
}
