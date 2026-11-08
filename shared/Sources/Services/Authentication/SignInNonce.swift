import CryptoKit
import Foundation
import Security

enum SignInNonce {
    enum Error: Swift.Error {
        case randomGenerationFailed(OSStatus)
    }

    static func random(length: Int = 32) throws -> String {
        precondition(length > 0)
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length

        while remaining > 0 {
            var bytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else {
                throw Error.randomGenerationFailed(status)
            }

            for byte in bytes where remaining > 0 {
                if byte < alphabet.count {
                    result.append(alphabet[Int(byte)])
                    remaining -= 1
                }
            }
        }
        return result
    }

    static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
