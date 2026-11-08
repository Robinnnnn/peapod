import Foundation
import UniformTypeIdentifiers

/// URL metadata from an item provider is distinct from the referenced file's bytes.
/// Generic data providers must never be decoded as URL metadata.
enum ShareURLRepresentation {
    static let maximumDataBytes = 8192
    static func webURLText(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.contains(where: { $0.isWhitespace }),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), url.host != nil else { return nil }
        return text
    }

    static func articleBody(url: String, note: String) -> String {
        guard note.contains(url),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return url + "\n" + note }

        let source = note as NSString
        let links = detector.matches(in: note, range: NSRange(location: 0, length: source.length))
        guard let shared = links.first(where: { source.substring(with: $0.range) == url }) else {
            return url + "\n" + note
        }
        if shared.range == links.first?.range { return note }
        let remainder = source.replacingCharacters(in: shared.range, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return url + "\n" + remainder
    }

    static func decode(_ value: Any?, typeIdentifier: String) -> URL? {
        let url: URL?
        if let supplied = value as? URL {
            url = supplied
        } else if let supplied = value as? NSURL {
            url = supplied as URL
        } else if let supplied = value as? String {
            url = URL(string: supplied)
        } else if let data = value as? Data {
            guard UTType(typeIdentifier)?.conforms(to: .url) == true,
                  !data.isEmpty, data.count <= maximumDataBytes,
                  String(data: data, encoding: .utf8) != nil,
                  data.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }),
                  let parsed = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true),
                  parsed.scheme != nil else { return nil }
            url = parsed
        } else { return nil }
        guard let url else { return nil }
        if UTType(typeIdentifier)?.conforms(to: .fileURL) == true, !url.isFileURL { return nil }
        return url
    }
}
