import Foundation

enum PairingCode {
    static let characterCount = 8
    static let lifetime: TimeInterval = 15 * 60

    /// Removes separators and unsupported characters while preserving every
    /// ASCII letter and digit. Validation remains separate so callers can
    /// distinguish incomplete and overlong input.
    static func normalized(_ input: String) -> String {
        var result = ""

        for scalar in input.uppercased().unicodeScalars {
            let value = scalar.value
            guard
                (48...57).contains(value)
                    || (65...90).contains(value)
            else {
                continue
            }
            result.unicodeScalars.append(scalar)
        }

        return result
    }

    /// A field-friendly representation capped at the backend's exact length.
    static func editableValue(_ input: String) -> String {
        String(normalized(input).prefix(characterCount))
    }

    static func canonicalValue(_ input: String) -> String? {
        let value = normalized(input)
        guard value.count == characterCount else { return nil }
        return value
    }

    static func formatted(_ input: String) -> String {
        let value = editableValue(input)
        guard value.count > 4 else { return value }

        let split = value.index(value.startIndex, offsetBy: 4)
        return "\(value[..<split]) \(value[split...])"
    }
}

enum PairingCodeInputError: LocalizedError {
    case invalid

    var errorDescription: String? {
        "Enter the 8-character code from the other person."
    }
}
