import Foundation
import ImageIO

struct LinkPreviewMetadata: Equatable, Sendable {
    let originalURL: URL
    let resolvedURL: URL
    let title: String?
    let description: String?
    let imageURLs: [URL]

    var imageURL: URL? {
        imageURLs.first
    }

    init(
        originalURL: URL,
        resolvedURL: URL,
        title: String?,
        description: String?,
        imageURL: URL?
    ) {
        self.init(
            originalURL: originalURL,
            resolvedURL: resolvedURL,
            title: title,
            description: description,
            imageURLs: imageURL.map { [$0] } ?? []
        )
    }

    init(
        originalURL: URL,
        resolvedURL: URL,
        title: String?,
        description: String?,
        imageURLs: [URL]
    ) {
        self.originalURL = originalURL
        self.resolvedURL = resolvedURL
        self.title = title
        self.description = description
        self.imageURLs = imageURLs
    }

    func preferringImageURL(_ selectedURL: URL) -> LinkPreviewMetadata {
        LinkPreviewMetadata(
            originalURL: originalURL,
            resolvedURL: resolvedURL,
            title: title,
            description: description,
            imageURLs: [selectedURL]
                + imageURLs.filter { $0 != selectedURL }
        )
    }
}

struct LinkPreviewContent: Equatable, Sendable {
    let metadata: LinkPreviewMetadata
    let imageData: Data?
}

struct LinkPreviewResourceRequest: Sendable {
    let url: URL
    let maximumByteCount: Int
    let acceptedContentTypes: Set<String>
    let acceptedContentTypePrefixes: Set<String>
    let bodyCompletion: LinkPreviewResourceBodyCompletion
    let maximumRedirectCount: Int

    init(
        url: URL,
        maximumByteCount: Int,
        acceptedContentTypes: Set<String>,
        acceptedContentTypePrefixes: Set<String>,
        bodyCompletion: LinkPreviewResourceBodyCompletion = .completeResource,
        maximumRedirectCount: Int = 5
    ) {
        self.url = url
        self.maximumByteCount = maximumByteCount
        self.acceptedContentTypes = acceptedContentTypes
        self.acceptedContentTypePrefixes = acceptedContentTypePrefixes
        self.bodyCompletion = bodyCompletion
        self.maximumRedirectCount = maximumRedirectCount
    }
}

enum LinkPreviewResourceBodyCompletion: Equatable, Sendable {
    case completeResource
    case htmlHead
}

struct LinkPreviewResourceResponse: Sendable {
    let data: Data
    let responseURL: URL
    let contentType: String
}

protocol LinkPreviewTransport: Sendable {
    func fetch(
        _ request: LinkPreviewResourceRequest
    ) async throws -> LinkPreviewResourceResponse
}

enum LinkPreviewFetchError: Error, Equatable {
    case unsafeURL
    case invalidResponse
    case unsupportedContentType
    case responseTooLarge
}

struct LinkPreviewResourceAccumulator {
    private static let closingHTMLHead = Array("</head>".utf8)

    private let maximumByteCount: Int
    private let bodyCompletion: LinkPreviewResourceBodyCompletion
    private var closingHTMLHeadMatchCount = 0

    private(set) var data: Data

    init(
        request: LinkPreviewResourceRequest,
        expectedContentLength: Int64
    ) throws {
        if expectedContentLength > Int64(request.maximumByteCount),
           request.bodyCompletion == .completeResource
        {
            throw LinkPreviewFetchError.responseTooLarge
        }

        maximumByteCount = request.maximumByteCount
        bodyCompletion = request.bodyCompletion
        data = Data()
        if expectedContentLength > 0 {
            data.reserveCapacity(
                Int(
                    min(
                        expectedContentLength,
                        Int64(request.maximumByteCount)
                    )
                )
            )
        }
    }

    mutating func append(_ byte: UInt8) throws -> Bool {
        guard data.count < maximumByteCount else {
            throw LinkPreviewFetchError.responseTooLarge
        }
        data.append(byte)

        guard bodyCompletion == .htmlHead else { return false }

        let normalizedByte = Self.lowercasedASCII(byte)
        let expectedByte = Self.closingHTMLHead[
            closingHTMLHeadMatchCount
        ]
        if normalizedByte == expectedByte {
            closingHTMLHeadMatchCount += 1
        } else {
            closingHTMLHeadMatchCount =
                normalizedByte == Self.closingHTMLHead[0] ? 1 : 0
        }
        return closingHTMLHeadMatchCount == Self.closingHTMLHead.count
    }

    private static func lowercasedASCII(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }
}

enum LinkPreviewURLPolicy {
    static func isAllowed(_ url: URL) -> Bool {
        guard
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.user == nil,
            url.password == nil,
            let host = url.host(percentEncoded: false)?.lowercased(),
            !host.isEmpty
        else {
            return false
        }

        if host == "localhost"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host == "::1"
            || host.hasPrefix("fc")
            || host.hasPrefix("fd")
            || host.hasPrefix("fe80:")
        {
            return false
        }

        guard let octets = ipv4Octets(host) else {
            return true
        }

        switch (octets[0], octets[1]) {
        case (10, _),
             (127, _),
             (169, 254),
             (172, 16...31),
             (192, 168),
             (0, _):
            return false
        default:
            return true
        }
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }

        let octets = parts.compactMap { part -> Int? in
            guard
                !part.isEmpty,
                part.allSatisfy(\.isNumber),
                let value = Int(part),
                (0...255).contains(value)
            else {
                return nil
            }
            return value
        }
        return octets.count == 4 ? octets : nil
    }
}

struct LinkPreviewSelection: Equatable, Sendable {
    let messageText: String
    let url: URL
    let originalURLText: String
    let isURLOnly: Bool

    var embeddedMessageText: String? {
        isURLOnly ? nil : messageText
    }

    static func first(in messageText: String) -> LinkPreviewSelection? {
        guard let match = LinkPreviewURLMatch.safeMatches(
            in: messageText
        ).first else {
            return nil
        }

        return LinkPreviewSelection(
            messageText: messageText,
            url: match.url,
            originalURLText: match.text,
            isURLOnly: messageText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) == match.text
        )
    }
}

struct LinkPreviewMessagePresentation: Sendable {
    let messageText: String
    let previewURL: URL
    let isURLOnly: Bool
    let linkTargets: [LinkTarget]

    struct LinkTarget: Equatable, Sendable {
        let text: String
        let url: URL
        fileprivate let utf16Location: Int
        fileprivate let utf16Length: Int
    }

    init?(messageText: String) {
        let matches = LinkPreviewURLMatch.safeMatches(in: messageText)
        guard let firstMatch = matches.first else {
            return nil
        }

        self.messageText = messageText
        previewURL = firstMatch.url
        isURLOnly = messageText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) == firstMatch.text
        linkTargets = matches.map {
            LinkTarget(
                text: $0.text,
                url: $0.url,
                utf16Location: $0.utf16Location,
                utf16Length: $0.utf16Length
            )
        }
    }

    /// The card represents the first URL. Leave all other links active in its caption.
    var previewCaption: AttributedString? {
        guard let first = linkTargets.first, !isURLOnly,
              let range = Range(NSRange(location: first.utf16Location, length: first.utf16Length), in: messageText)
        else { return nil }

        let before = messageText[..<range.lowerBound]
        let after = messageText[range.upperBound...]
        let left = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = after.trimmingCharacters(in: .whitespacesAndNewlines)
        var caption = left
        if !left.isEmpty && !right.isEmpty {
            let trailingSpace = before.reversed().prefix { $0.isWhitespace }
            let leadingSpace = after.prefix { $0.isWhitespace }
            if trailingSpace.contains(where: { $0.isNewline }) || leadingSpace.contains(where: { $0.isNewline }) {
                caption += "\n"
            } else if (!trailingSpace.isEmpty || !leadingSpace.isEmpty),
                      let first = right.first, !",.;:!?)]}".contains(first) {
                caption += " "
            }
        }
        caption += right
        guard !caption.isEmpty else { return nil }
        return LinkPreviewMessagePresentation(messageText: caption)?.attributedBody ?? AttributedString(caption)
    }

    var attributedMessageText: AttributedString? {
        guard !isURLOnly else { return nil }

        return attributedBody
    }

    /// Keep every original link usable while the final card is being prepared,
    /// including a message that consists only of a URL.
    var attributedOriginalMessage: AttributedString { attributedBody }

    private var attributedBody: AttributedString {
        var attributed = AttributedString(messageText)
        for target in linkTargets {
            let nsRange = NSRange(
                location: target.utf16Location,
                length: target.utf16Length
            )
            guard
                let stringRange = Range(nsRange, in: messageText),
                let lowerBound = AttributedString.Index(
                    stringRange.lowerBound,
                    within: attributed
                ),
                let upperBound = AttributedString.Index(
                    stringRange.upperBound,
                    within: attributed
                )
            else {
                continue
            }
            attributed[lowerBound..<upperBound].link = target.url
        }
        return attributed
    }
}

private struct LinkPreviewURLMatch: Sendable {
    let text: String
    let url: URL
    let utf16Location: Int
    let utf16Length: Int

    static func safeMatches(in messageText: String) -> [Self] {
        LinkPreviewURLMatchCache.shared.matches(in: messageText)
    }
}

private final class LinkPreviewURLMatchCache: @unchecked Sendable {
    private final class MatchBox {
        let matches: [LinkPreviewURLMatch]

        init(_ matches: [LinkPreviewURLMatch]) {
            self.matches = matches
        }
    }

    static let shared = LinkPreviewURLMatchCache()

    private let detector: NSDataDetector?
    private let lock = NSLock()
    private let values = NSCache<NSString, MatchBox>()

    private init() {
        detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        )
        values.countLimit = 1_000
    }

    func matches(in messageText: String) -> [LinkPreviewURLMatch] {
        let cacheKey = messageText as NSString
        if let cached = values.object(forKey: cacheKey) {
            return cached.matches
        }

        return lock.withLock {
            if let cached = values.object(forKey: cacheKey) {
                return cached.matches
            }
            guard let detector else { return [] }

            let source = messageText as NSString
            let matches: [LinkPreviewURLMatch] = detector.matches(
                in: messageText,
                options: [],
                range: NSRange(location: 0, length: source.length)
            ).compactMap { match -> LinkPreviewURLMatch? in
                let detectedText = source.substring(with: match.range)
                let normalizedDetectedText = detectedText.lowercased()
                guard
                    normalizedDetectedText.hasPrefix("https://")
                        || normalizedDetectedText.hasPrefix("http://"),
                    let url = match.url,
                    LinkPreviewURLPolicy.isAllowed(url)
                else {
                    return nil
                }

                return LinkPreviewURLMatch(
                    text: detectedText,
                    url: url,
                    utf16Location: match.range.location,
                    utf16Length: match.range.length
                )
            }
            values.setObject(MatchBox(matches), forKey: cacheKey)
            return matches
        }
    }
}

extension MessageKind {
    static func forText(_ text: String) -> MessageKind {
        guard let selection = LinkPreviewSelection.first(in: text) else {
            return .text
        }
        return selection.isURLOnly ? .link : .text
    }
}

enum LinkPreviewRedirectPolicy {
    static func safeRequest(
        from request: URLRequest,
        redirectCount: Int,
        maximumRedirectCount: Int
    ) -> URLRequest? {
        guard
            redirectCount <= maximumRedirectCount,
            let targetURL = request.url,
            LinkPreviewURLPolicy.isAllowed(targetURL)
        else {
            return nil
        }

        var safeRequest = request
        safeRequest.setValue(nil, forHTTPHeaderField: "Authorization")
        safeRequest.setValue(nil, forHTTPHeaderField: "Cookie")
        return safeRequest
    }
}

enum LinkPreviewURLRequestFactory {
    // A fixed desktop Safari User-Agent asks universal/deep-link services for
    // their public web landing page instead of an app-opening redirect. It
    // does not disclose device details; the session remains ephemeral and
    // cookie-free.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 "
        + "Safari/605.1.15 peapod-link-preview/1"

    static func makeRequest(
        for resource: LinkPreviewResourceRequest
    ) -> URLRequest {
        var request = URLRequest(url: resource.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            resource.acceptedContentTypes.contains("application/json")
                ? "application/json"
                : "text/html,application/xhtml+xml,image/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }
}

final class LinkPreviewRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let maximumRedirectCount: Int
    private let lock = NSLock()
    private var redirectCounts: [Int: Int] = [:]

    init(maximumRedirectCount: Int) {
        self.maximumRedirectCount = maximumRedirectCount
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let redirectCount = lock.withLock {
            let nextCount = redirectCounts[task.taskIdentifier, default: 0] + 1
            redirectCounts[task.taskIdentifier] = nextCount
            return nextCount
        }

        completionHandler(
            LinkPreviewRedirectPolicy.safeRequest(
                from: request,
                redirectCount: redirectCount,
                maximumRedirectCount: maximumRedirectCount
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.withLock {
            redirectCounts[task.taskIdentifier] = nil
        }
    }
}

actor URLSessionLinkPreviewTransport: LinkPreviewTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false

        session = URLSession(configuration: configuration)
    }

    func fetch(
        _ request: LinkPreviewResourceRequest
    ) async throws -> LinkPreviewResourceResponse {
        guard LinkPreviewURLPolicy.isAllowed(request.url) else {
            throw LinkPreviewFetchError.unsafeURL
        }

        let urlRequest = LinkPreviewURLRequestFactory.makeRequest(for: request)

        let (bytes, response) = try await session.bytes(
            for: urlRequest,
            delegate: LinkPreviewRedirectDelegate(
                maximumRedirectCount: request.maximumRedirectCount
            )
        )
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            let responseURL = httpResponse.url,
            LinkPreviewURLPolicy.isAllowed(responseURL)
        else {
            throw LinkPreviewFetchError.invalidResponse
        }

        let contentType = normalizedContentType(httpResponse.mimeType)
        let isAccepted = request.acceptedContentTypes.contains(contentType)
            || request.acceptedContentTypePrefixes.contains {
                contentType.hasPrefix($0)
            }
        guard isAccepted else {
            throw LinkPreviewFetchError.unsupportedContentType
        }

        var accumulator = try LinkPreviewResourceAccumulator(
            request: request,
            expectedContentLength: httpResponse.expectedContentLength
        )

        for try await byte in bytes {
            if try accumulator.append(byte) {
                bytes.task.cancel()
                break
            }
        }

        return LinkPreviewResourceResponse(
            data: accumulator.data,
            responseURL: responseURL,
            contentType: contentType
        )
    }

    private func normalizedContentType(_ contentType: String?) -> String {
        contentType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            ?? ""
    }
}

struct LinkPreviewHTMLParser: Sendable {
    private static let imageKeys = [
        "og:image:secure_url",
        "og:image:url",
        "og:image",
        "twitter:image",
        "twitter:image:src",
    ]
    private static let textKeys: Set<String> = [
        "og:title",
        "twitter:title",
        "og:description",
        "twitter:description",
        "description",
    ]
    private static let maximumImageCandidateCount = 8
    private static let maximumImageURLByteCount = 4_096

    func parse(
        data: Data,
        originalURL: URL,
        responseURL: URL
    ) -> LinkPreviewMetadata {
        let html = String(decoding: data, as: UTF8.self)
        let metaTags = tags(named: "meta", in: html)

        var textValues: [String: String] = [:]
        var imageValues: [String: [String]] = [:]
        for tag in metaTags {
            let attributes = attributes(in: tag)
            guard
                let key = (
                    attributes["property"]
                    ?? attributes["name"]
                )?.lowercased(),
                let content = attributes["content"]
            else {
                continue
            }
            if Self.textKeys.contains(key) {
                if textValues[key] == nil,
                   let cleanedContent = cleanText(content, maximumLength: 512)
                {
                    textValues[key] = cleanedContent
                }
            } else if Self.imageKeys.contains(key) {
                // Attribute entities are already decoded. Image URLs are not
                // display text: truncating or cleaning them can break signed
                // artwork URLs. Reject oversized values rather than fetching
                // an altered URL.
                let imageValue = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard
                    !imageValue.isEmpty,
                    imageValue.utf8.count <= Self.maximumImageURLByteCount,
                    !imageValue.unicodeScalars.contains(where: {
                        CharacterSet.whitespacesAndNewlines.contains($0)
                            || CharacterSet.controlCharacters.contains($0)
                    }),
                    imageValues[key, default: []].count
                        < Self.maximumImageCandidateCount
                else {
                    continue
                }
                imageValues[key, default: []].append(imageValue)
            }
        }

        let htmlTitle = firstCapture(
            pattern: #"<title\b[^>]*>([\s\S]*?)</title>"#,
            in: html,
            options: [.caseInsensitive]
        )

        let title = firstNonempty(
            textValues["og:title"],
            textValues["twitter:title"],
            cleanText(htmlTitle, maximumLength: 160)
        ).flatMap {
            cleanText($0, maximumLength: 160)
        }.flatMap {
            LinkPreviewText.looksOpaqueIdentifier($0) ? nil : $0
        }
        let description = firstNonempty(
            textValues["og:description"],
            textValues["twitter:description"],
            textValues["description"]
        ).flatMap {
            cleanText($0, maximumLength: 320)
        }

        var imageURLs: [URL] = []
        var seenImageURLs: Set<URL> = []
        imageCandidateLoop: for key in Self.imageKeys {
            for value in imageValues[key] ?? [] {
                guard
                    let candidate = URL(
                        string: value,
                        relativeTo: responseURL
                    )?.absoluteURL,
                    candidate.absoluteString.utf8.count <= Self.maximumImageURLByteCount,
                    LinkPreviewURLPolicy.isAllowed(candidate),
                    seenImageURLs.insert(candidate).inserted
                else {
                    continue
                }
                imageURLs.append(candidate)
                if imageURLs.count == Self.maximumImageCandidateCount {
                    break imageCandidateLoop
                }
            }
        }

        return LinkPreviewMetadata(
            originalURL: originalURL,
            resolvedURL: responseURL,
            title: title,
            description: description,
            imageURLs: imageURLs
        )
    }

    private func attributes(in tag: String) -> [String: String] {
        let pattern =
            #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: []
        ) else {
            return [:]
        }

        let range = NSRange(tag.startIndex..., in: tag)
        var result: [String: String] = [:]
        for match in expression.matches(in: tag, range: range) {
            guard
                let nameRange = Range(match.range(at: 1), in: tag)
            else {
                continue
            }
            let valueRange = (2...4)
                .lazy
                .compactMap { index -> Range<String.Index>? in
                    let range = match.range(at: index)
                    guard range.location != NSNotFound else { return nil }
                    return Range(range, in: tag)
                }
                .first
            guard let valueRange else { continue }
            result[String(tag[nameRange]).lowercased()] =
                decodeHTMLEntities(String(tag[valueRange]))
        }
        return result
    }

    private func matches(
        pattern: String,
        in text: String,
        options: NSRegularExpression.Options
    ) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: options
        ) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private func tags(named name: String, in html: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: "<\(NSRegularExpression.escapedPattern(for: name))\\b",
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let searchRange = NSRange(html.startIndex..., in: html)
        return expression.matches(in: html, range: searchRange).compactMap {
            guard
                let start = Range($0.range, in: html)?.lowerBound
            else {
                return nil
            }

            var index = start
            var quote: Character?
            while index < html.endIndex {
                let character = html[index]
                if let currentQuote = quote {
                    if character == currentQuote {
                        quote = nil
                    }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    return String(html[start...index])
                }
                index = html.index(after: index)
            }
            return nil
        }
    }

    private func firstCapture(
        pattern: String,
        in text: String,
        options: NSRegularExpression.Options
    ) -> String? {
        guard
            let expression = try? NSRegularExpression(
                pattern: pattern,
                options: options
            ),
            let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            ),
            let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return decodeHTMLEntities(String(text[range]))
    }

    private func firstNonempty(_ values: String?...) -> String? {
        for value in values {
            guard let value else { continue }
            if !value.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {
                return value
            }
        }
        return nil
    }

    fileprivate func cleanText(
        _ value: String?,
        maximumLength: Int
    ) -> String? {
        guard let value else { return nil }
        let withoutTags = value.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        let collapsed = decodeHTMLEntities(withoutTags)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumLength))
    }

    private func decodeHTMLEntities(_ value: String) -> String {
        var result = value
        let namedEntities = [
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&lt;": "<",
            "&gt;": ">",
            "&nbsp;": " ",
        ]
        // Match the original attribute once. Sequential replacements could
        // turn &amp;#38; into & instead of preserving the literal &#38; in a URL.
        let pattern = #"&(?:amp|quot|apos|lt|gt|nbsp|#(?:x[0-9a-f]+|[0-9]+));"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        )
        else {
            return result
        }

        let matches = expression.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        )
        for match in matches.reversed() {
            guard
                let fullRange = Range(match.range(at: 0), in: result)
            else {
                continue
            }
            let entity = String(result[fullRange]).lowercased()
            if let replacement = namedEntities[entity] {
                result.replaceSubrange(fullRange, with: replacement)
                continue
            }
            let encoded = String(entity.dropFirst(2).dropLast())
            let radix = encoded.hasPrefix("x") ? 16 : 10
            let digits = radix == 16 ? String(encoded.dropFirst()) : encoded
            guard
                let scalarValue = UInt32(digits, radix: radix),
                let scalar = UnicodeScalar(scalarValue)
            else {
                continue
            }
            result.replaceSubrange(fullRange, with: String(Character(scalar)))
        }
        return result
    }
}

private enum RedditLinkPreviewFallback {
    static let maximumResponseByteCount = 65_536

    private struct Payload: Decodable {
        let title: String
        let type: String
        let providerName: String

        enum CodingKeys: String, CodingKey {
            case title, type
            case providerName = "provider_name"
        }
    }

    static func postURL(originalURL: URL, observedURL: URL?) -> URL? {
        if let postURL = canonicalPostURL(for: originalURL) {
            return postURL
        }
        guard isRecognizedShareURL(originalURL), let observedURL else {
            return nil
        }
        // The ordinary HTML request already followed this redirect. Never
        // interpret an opaque share token as a post ID or resolve it separately.
        return canonicalPostURL(for: observedURL)
    }

    static func canonicalPostURL(for url: URL) -> URL? {
        guard
            LinkPreviewURLPolicy.isAllowed(url),
            let host = url.host(percentEncoded: false)?.lowercased(),
            ["reddit.com", "www.reddit.com", "old.reddit.com"].contains(host),
            url.port == nil
                || (url.scheme == "https" && url.port == 443)
                || (url.scheme == "http" && url.port == 80),
            url.absoluteString.utf8.count <= 4_096
        else { return nil }

        let path = url.path(percentEncoded: false)
        guard !path.contains("//") else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        // oEmbed needs the subreddit permalink. A comments-only redirect does
        // not supply it, and an opaque short link must not invent a subreddit.
        guard
            parts.count == 4 || parts.count == 5,
            parts[0] == "r", parts[2] == "comments",
            isIdentifier(parts[1], maximumLength: 21, allowsUnderscore: true),
            isIdentifier(parts[3], maximumLength: 13, allowsUnderscore: false)
        else { return nil }

        // Drop the slug, tracking query and fragment, without changing the
        // message's original tap target. Only a public post permalink is sent.
        return URL(string:
            "https://www.reddit.com/r/\(parts[1].lowercased())/comments/\(parts[3].lowercased())/"
        )
    }

    static func endpointURL(for postURL: URL) -> URL? {
        var components = URLComponents(string: "https://www.reddit.com/oembed")
        components?.queryItems = [
            URLQueryItem(name: "url", value: postURL.absoluteString),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components?.url
    }

    static func isNeeded(for metadata: LinkPreviewMetadata?) -> Bool {
        guard let metadata else { return true }
        guard metadata.imageURLs.isEmpty, metadata.description == nil else {
            return false
        }
        guard let title = metadata.title?.lowercased() else { return true }
        return ["reddit", "reddit - dive into anything", "dive into anything"]
            .contains(title)
    }

    static func title(
        from response: LinkPreviewResourceResponse,
        endpointURL: URL
    ) -> String? {
        guard
            response.responseURL == endpointURL,
            response.contentType == "application/json",
            response.data.count <= maximumResponseByteCount,
            let payload = try? JSONDecoder().decode(Payload.self, from: response.data),
            payload.type == "rich", payload.providerName.lowercased() == "reddit",
            payload.title.utf8.count <= 4_096,
            let title = LinkPreviewHTMLParser().cleanText(
                payload.title, maximumLength: 160
            ),
            !title.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
            !LinkPreviewText.looksOpaqueIdentifier(title)
        else { return nil }
        // Only the bounded plain-text title is used. In particular, never
        // render oEmbed HTML or follow its iframe, script or artwork URLs.
        return title
    }

    private static func isIdentifier(
        _ value: String, maximumLength: Int, allowsUnderscore: Bool
    ) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumLength
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || (allowsUnderscore && $0 == 95)
            }
    }

    private static func isRecognizedShareURL(_ url: URL) -> Bool {
        guard
            LinkPreviewURLPolicy.isAllowed(url),
            let host = url.host(percentEncoded: false)?.lowercased(),
            url.port == nil
                || (url.scheme == "https" && url.port == 443)
                || (url.scheme == "http" && url.port == 80),
            url.absoluteString.utf8.count <= 4_096
        else { return false }
        let path = url.path(percentEncoded: false)
        guard !path.contains("//") else { return false }
        let parts = path.split(separator: "/").map(String.init)
        if host == "redd.it" {
            return parts.count == 1
                && isIdentifier(parts[0], maximumLength: 13, allowsUnderscore: false)
        }
        return ["reddit.com", "www.reddit.com", "old.reddit.com"].contains(host)
            && parts.count == 4 && parts[0] == "r" && parts[2] == "s"
            && isIdentifier(parts[1], maximumLength: 21, allowsUnderscore: true)
            && parts[3].utf8.count <= 128
    }
}

actor LinkPreviewProvider {
    static let shared = LinkPreviewProvider(
        transport: URLSessionLinkPreviewTransport()
    )

    private struct CacheEntry: Sendable {
        let content: LinkPreviewContent
        let createdAt: Date
    }

    private let transport: any LinkPreviewTransport
    private let now: @Sendable () -> Date
    private let maximumCacheEntries: Int
    private let cacheLifetime: TimeInterval
    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<LinkPreviewContent?, Never>] = [:]

    init(
        transport: any LinkPreviewTransport,
        now: @escaping @Sendable () -> Date = Date.init,
        maximumCacheEntries: Int = 64,
        cacheLifetime: TimeInterval = 24 * 60 * 60
    ) {
        self.transport = transport
        self.now = now
        self.maximumCacheEntries = maximumCacheEntries
        self.cacheLifetime = cacheLifetime
    }

    func preview(for urlText: String) async -> LinkPreviewContent? {
        guard
            !Task.isCancelled,
            let originalURL = URL(string: urlText),
            LinkPreviewURLPolicy.isAllowed(originalURL)
        else {
            return nil
        }


        let cacheKey = originalURL.absoluteString
        let currentDate = now()
        if let cached = cache[cacheKey],
           currentDate.timeIntervalSince(cached.createdAt) < cacheLifetime
        {
            return cached.content
        }
        cache[cacheKey] = nil

        if let inFlight = inFlight[cacheKey] {
            return await inFlight.value
        }

        let request = Task {
            await fetchPreview(for: originalURL)
        }
        inFlight[cacheKey] = request
        let content = await request.value
        inFlight[cacheKey] = nil
        if let content {
            insert(
                content,
                for: cacheKey,
                createdAt: currentDate
            )
        }
        return content
    }

    private func fetchPreview(
        for originalURL: URL
    ) async -> LinkPreviewContent? {
        do {
            var metadata: LinkPreviewMetadata?
            var observedResponseURL: URL?
            do {
                let htmlResponse = try await transport.fetch(
                    LinkPreviewResourceRequest(
                        url: originalURL,
                        maximumByteCount: 1_048_576,
                        acceptedContentTypes: ["text/html", "application/xhtml+xml"],
                        acceptedContentTypePrefixes: [],
                        bodyCompletion: .htmlHead
                    )
                )
                try Task.checkCancellation()
                observedResponseURL = htmlResponse.responseURL
                metadata = LinkPreviewHTMLParser().parse(
                    data: htmlResponse.data,
                    originalURL: originalURL,
                    responseURL: htmlResponse.responseURL
                )
            } catch is CancellationError {
                return nil
            } catch {
                try Task.checkCancellation()
            }

            if RedditLinkPreviewFallback.isNeeded(for: metadata),
               let postURL = RedditLinkPreviewFallback.postURL(
                    originalURL: originalURL,
                    observedURL: observedResponseURL
               ),
               let endpointURL = RedditLinkPreviewFallback.endpointURL(for: postURL)
            {
                do {
                    try Task.checkCancellation()
                    let response = try await transport.fetch(
                        LinkPreviewResourceRequest(
                            url: endpointURL,
                            maximumByteCount: RedditLinkPreviewFallback.maximumResponseByteCount,
                            acceptedContentTypes: ["application/json"],
                            acceptedContentTypePrefixes: [],
                            maximumRedirectCount: 0
                        )
                    )
                    try Task.checkCancellation()
                    if let title = RedditLinkPreviewFallback.title(
                        from: response, endpointURL: endpointURL
                    ) {
                        metadata = LinkPreviewMetadata(
                            originalURL: originalURL, resolvedURL: postURL,
                            title: title, description: nil, imageURL: nil
                        )
                    }
                } catch is CancellationError {
                    return nil
                } catch {
                    try Task.checkCancellation()
                }
            }
            guard let metadata else { return nil }

            var resolvedMetadata = metadata
            var imageData: Data?
            for imageURL in metadata.imageURLs {
                do {
                    try Task.checkCancellation()
                    let candidateData = try await transport.fetch(
                        LinkPreviewResourceRequest(
                            url: imageURL,
                            maximumByteCount: 2_097_152,
                            acceptedContentTypes: [],
                            acceptedContentTypePrefixes: ["image/"]
                        )
                    ).data
                    try Task.checkCancellation()
                    guard LinkPreviewImageData.isDisplayable(candidateData)
                    else {
                        continue
                    }
                    imageData = candidateData
                    resolvedMetadata = metadata.preferringImageURL(imageURL)
                    break
                } catch is CancellationError {
                    return nil
                } catch {
                    guard !Task.isCancelled else { return nil }
                    continue
                }
            }

            return LinkPreviewContent(
                metadata: resolvedMetadata,
                imageData: imageData
            )
        } catch {
            return nil
        }
    }

    private func insert(
        _ content: LinkPreviewContent,
        for key: String,
        createdAt: Date
    ) {
        cache[key] = CacheEntry(content: content, createdAt: createdAt)
        guard cache.count > maximumCacheEntries else { return }

        let overflow = cache.count - maximumCacheEntries
        for key in cache
            .sorted(by: { $0.value.createdAt < $1.value.createdAt })
            .prefix(overflow)
            .map(\.key)
        {
            cache[key] = nil
        }
    }
}

enum LinkPreviewImageData {
    static func isDisplayable(_ data: Data) -> Bool {
        guard
            !data.isEmpty,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else {
            return false
        }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options
        ) != nil
    }
}
