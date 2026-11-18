import Foundation

/// Scrubs a diagnostics blob before it is written or published.
///
/// Shared by the app (diagnostics export) and the privileged helper (the
/// kernel stderr tail in `status_read`), so both sides scrub the same way.
/// Home directory prefixes become `<home>`. Bearer tokens and `"token"` /
/// `"authorization"` JSON strings become `<redacted>`. Utun peer addresses
/// (a listed address, a `peer <addr>` phrase, or the right-hand side of
/// ifconfig's `-->`) become `<peer>`. Interface names such as `utun4` stay.
public enum DiagnosticsRedactor {
    public static func redact(
        _ text: String,
        home: String,
        secrets: [String] = [],
        peerAddresses: [String] = []
    ) -> String {
        var out = text
        let secretsLongest = secrets.sorted { $0.count > $1.count }
        for secret in secretsLongest where secret.count >= 8 {
            out = out.replacingOccurrences(of: secret, with: "<redacted>")
        }
        out = redactKeyedSecrets(out)
        out = redactBearer(out)
        out = redactHome(out, home: home)
        let peers = peerAddresses.sorted { $0.count > $1.count }
        for peer in peers where peer.count >= 3 && (peer.contains(".") || peer.contains(":")) {
            out = out.replacingOccurrences(of: peer, with: "<peer>")
        }
        out = redactContextualPeers(out)
        return out
    }

    private static func redactHome(_ text: String, home: String) -> String {
        var prefix = home
        while prefix.count > 1 && prefix.hasSuffix("/") {
            prefix.removeLast()
        }
        guard prefix.count >= 2, prefix != "/" else {
            return text
        }
        var out = text
        let escaped = prefix.replacingOccurrences(of: "/", with: "\\/")
        out = replacePathPrefix(out, prefix: escaped, with: "<home>")
        if let encoded = prefix.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            out = replacePathPrefix(out, prefix: encoded, with: "<home>", caseInsensitive: true)
        }
        out = replacePathPrefix(out, prefix: prefix, with: "<home>")
        return out
    }

    private static func replacePathPrefix(
        _ text: String,
        prefix: String,
        with replacement: String,
        caseInsensitive: Bool = false
    ) -> String {
        guard !prefix.isEmpty else {
            return text
        }
        let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
        var result = ""
        var index = text.startIndex
        while index < text.endIndex,
              let range = text.range(of: prefix, options: options, range: index ..< text.endIndex)
        {
            result.append(contentsOf: text[index ..< range.lowerBound])
            let after = range.upperBound
            let boundary = after == text.endIndex || isBoundary(text[after])
            if boundary {
                result.append(replacement)
            } else {
                result.append(contentsOf: text[range])
            }
            index = after
        }
        result.append(contentsOf: text[index...])
        return result
    }

    private static func isBoundary(_ character: Character) -> Bool {
        switch character {
        case "/", "\\", "\"", "'", " ", "\n", "\r", "\t", ",", "}", "]":
            return true
        default:
            return false
        }
    }

    private static func redactKeyedSecrets(_ text: String) -> String {
        let pattern = #"(?i)"(token|authorization|proxy_authorization)"\s*:\s*"(?:\\.|[^"\\])*""#
        return replace(text, pattern: pattern) { match, source in
            let key = source.substring(with: match.range(at: 1))
            return "\"\(key)\":\"<redacted>\""
        }
    }

    private static func redactBearer(_ text: String) -> String {
        let pattern = #"(?i)Bearer\s+[A-Za-z0-9._~+/=-]{8,}"#
        return replace(text, pattern: pattern) { _, _ in
            "Bearer <redacted>"
        }
    }

    private static func redactContextualPeers(_ text: String) -> String {
        let patterns = [
            #"(?i)(\bpeer\b\s+)([0-9A-Fa-f:.]+)"#,
            #"(-->\s*)([0-9A-Fa-f:.]+)"#,
        ]
        var out = text
        for pattern in patterns {
            out = replace(out, pattern: pattern) { match, source in
                let whole = source.substring(with: match.range)
                let address = source.substring(with: match.range(at: 2))
                guard address.contains(".") || address.contains(":") else {
                    return whole
                }
                let prefix = source.substring(with: match.range(at: 1))
                return prefix + "<peer>"
            }
        }
        return out
    }

    private static func replace(
        _ text: String,
        pattern: String,
        replacement: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let source = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: source.length))
        var out = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: out) else {
                continue
            }
            out.replaceSubrange(range, with: replacement(match, source))
        }
        return out
    }
}
