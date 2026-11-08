import Foundation

/// Non-content-bearing failures. Never attach plaintext, keys, or private metadata to diagnostics.
public enum E2EEError: Error, Equatable, Sendable {
    case invalidContext
    case invalidKey
    case unsupportedVersion
    case unsupportedSuite
    case unsupportedRecordKind
    case unsupportedPayloadVersion
    case malformedEnvelope
    case malformedPayload
    case sizeLimitExceeded
    case contextMismatch
    case authenticationFailed
    case staleRevision
    case revisionConflict
    case invalidAttachmentMetadata
    case invalidLimit
}

public enum POCLimits {
    public static let identifierBytes = 512
    public static let recordPlaintextBytes = 64 * 1024
    public static let recordEnvelopeBytes = recordPlaintextBytes + 4096
    /// Experimental one-shot cap. Physical-phone peak memory remains unmeasured.
    public static let attachmentPlaintextBytes = 200 * 1024 * 1024
    public static let attachmentEnvelopeBytes = attachmentPlaintextBytes + 4096
    public static let messageTextBytes = 32 * 1024
    public static let attachmentsPerMessage = 8
}

struct BinaryWriter {
    var data = Data()
    mutating func uint32(_ value: UInt32) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
    mutating func uint64(_ value: UInt64) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
    mutating func bytes(_ bytes: Data) { data.append(bytes) }
    mutating func lengthPrefixed(_ bytes: Data) {
        // All call sites bound the data before this conversion.
        uint32(UInt32(bytes.count))
        data.append(bytes)
    }
    mutating func string(_ string: String) { lengthPrefixed(Data(string.utf8)) }
}

struct BinaryReader {
    private let data: Data
    private var offset = 0
    init(_ data: Data) { self.data = data }
    var isAtEnd: Bool { offset == data.count }
    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw E2EEError.malformedEnvelope }
        let start = data.startIndex + offset
        offset += count
        // Keep small fields independent of the backing envelope. Large ciphertext
        // slices share storage, avoiding another whole attachment allocation.
        let range = start..<(start + count)
        return count > 4096 ? data[range] : data.subdata(in: range)
    }
    mutating func uint32() throws -> UInt32 {
        try bytes(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    mutating func uint64() throws -> UInt64 {
        try bytes(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    mutating func lengthPrefixed(maximum: Int) throws -> Data {
        let count = try uint32()
        guard UInt64(count) <= UInt64(maximum) else { throw E2EEError.sizeLimitExceeded }
        return try bytes(Int(count))
    }
    mutating func string(maximum: Int) throws -> String {
        let bytes = try lengthPrefixed(maximum: maximum)
        guard let value = String(data: bytes, encoding: .utf8) else { throw E2EEError.malformedEnvelope }
        return value
    }
    mutating func expect(_ expected: Data) throws {
        guard try bytes(expected.count) == expected else { throw E2EEError.malformedEnvelope }
    }
}

func validateIdentifier(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= POCLimits.identifierBytes else {
        throw E2EEError.invalidContext
    }
}
