import Foundation

/// Whether the AI lock is armed. The renderer is pure: it produces the text
/// for the anchor, and the helper decides when to load it.
public enum AILockIntent: Equatable, Sendable {
    case disarmed
    case armed
}

public enum PFAnchorError: Error, Equatable {
    /// The utun name is not a kernel interface name. It goes into a pf rule
    /// verbatim, so anything but `utun<digits>` is refused here.
    case invalidInterface(String)
}

/// Renders the body of PF anchor `segue.ailock` (design
/// `docs/design/macos.md` §2). Rule order is fixed:
///
/// 1. `pass quick on lo0`
/// 2. `pass quick on <utun>` — only while a tunnel interface exists
/// 3. one `block drop out quick <family> to <cidr> label "segue-ai-<n>"` per
///    armed CIDR, in list order, each with its own label so pfctl cannot
///    collapse them
///
/// and nothing else: no `user` clause (the kernel reaches the AI exit by IP,
/// never by dialling an AI address), no `block drop all`. An empty CIDR list
/// arms the name guard only, and the anchor passes everything.
public enum PFAnchorRenderer {
    public static let anchorName = "segue.ailock"
    static let headerComment = "# segue.ailock — managed by Segue; do not edit"

    public static func render(intent: AILockIntent, utun: String?, list: AILockList) throws
        -> String
    {
        if let utun {
            guard Self.isUtunName(utun) else { throw PFAnchorError.invalidInterface(utun) }
        }
        guard intent == .armed else {
            return headerComment + "\n"
        }

        var lines = [headerComment, "pass quick on lo0"]
        if let utun {
            lines.append("pass quick on \(utun)")
        }
        for (index, cidr) in list.cidrs.enumerated() {
            let family = cidr.version == .ipv4 ? "inet" : "inet6"
            lines.append(
                "block drop out quick \(family) to \(cidr.text) label \"segue-ai-\(index)\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `utun<digits>`, nothing else; also capped at IFNAMSIZ (16, minus the
    /// terminating NUL).
    static func isUtunName(_ name: String) -> Bool {
        guard name.hasPrefix("utun"), name.count <= 15 else { return false }
        let digits = name.dropFirst("utun".count)
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else {
            return false
        }
        return true
    }
}

public enum PFConfHookError: Error, Equatable {
    /// More than one `anchor "segue.ailock"` declaration is present.
    case duplicatedHook
    /// An anchor-family line names something else in Segue's namespace; this
    /// helper did not write it and must not paper over it.
    case foreignAnchor(name: String)
    /// A `load anchor "…" from` line names this anchor. Apple's pfctl loads
    /// pf.conf at boot (including Safe Mode, where the helper does not run),
    /// so the hook is the declaration only (decision 034).
    case bootLoadDirective(name: String)
}

public struct PFConfHookResult: Equatable, Sendable {
    /// The pf.conf text with the hook in place.
    public let text: String
    /// false when the hook was already present: nothing to write.
    public let inserted: Bool
}

/// Owns the one line Segue adds to `/etc/pf.conf`: the `segue.ailock` anchor
/// declaration. Everything already in the file survives byte-for-byte; the
/// child rules are loaded into the anchor by the helper's own `pfctl -f`
/// transaction, never from this file.
public enum PFConfHook {
    public static let anchorName = PFAnchorRenderer.anchorName
    public static let hookLine = "anchor \"segue.ailock\""

    private static let declarationDirectives: Set<String> = [
        "anchor", "scrub-anchor", "nat-anchor", "rdr-anchor", "dummynet-anchor",
    ]

    /// Returns the text with the hook in place, or the input unchanged when
    /// the hook is already there. Throws on anything in Segue's anchor
    /// namespace this code would not have written.
    public static func ensure(_ text: String) throws -> PFConfHookResult {
        let declarations = try scan(text)
        switch declarations {
        case 0:
            return PFConfHookResult(text: insertHookLine(into: text), inserted: true)
        case 1:
            return PFConfHookResult(text: text, inserted: false)
        default:
            throw PFConfHookError.duplicatedHook
        }
    }

    /// true when the hook is present exactly once and nothing foreign holds
    /// Segue's anchor namespace.
    public static func verify(_ text: String) throws -> Bool {
        try ensure(text).inserted == false
    }

    /// Counts this hook's declarations and rejects anything else in the
    /// `segue.` anchor namespace: other anchor names, scrub/nat/rdr/dummynet
    /// anchors (this helper writes none), and every `load anchor … from`.
    private static func scan(_ text: String) throws -> Int {
        var declarations = 0
        var violation: PFConfHookError?
        text.enumerateLines { rawLine, _ in
            guard violation == nil else { return }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return }
            var tokens = line.split(
                whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard !tokens.isEmpty else { return }

            var isLoadAnchor = false
            if tokens[0] == "load" {
                guard tokens.count > 1, tokens[1] == "anchor" else { return }
                isLoadAnchor = true
                tokens.removeFirst()
            }
            let directive = tokens[0]
            let isAnchorFamily = isLoadAnchor
                || Self.declarationDirectives.contains(directive)
            guard isAnchorFamily else { return }

            guard let name = Self.firstQuotedToken(in: line) else { return }
            guard name.hasPrefix("segue.") else { return }

            if isLoadAnchor {
                violation = name == Self.anchorName
                    ? PFConfHookError.bootLoadDirective(name: name)
                    : PFConfHookError.foreignAnchor(name: name)
                return
            }
            if directive == "anchor" && name == Self.anchorName {
                declarations += 1
                return
            }
            violation = PFConfHookError.foreignAnchor(name: name)
        }
        if let violation { throw violation }
        return declarations
    }

    private static func firstQuotedToken(in line: String) -> String? {
        guard let start = line.firstIndex(of: "\"") else { return nil }
        let afterStart = line.index(after: start)
        guard let end = line[afterStart...].firstIndex(of: "\"") else { return nil }
        return String(line[afterStart..<end])
    }

    /// Appends the hook line, adding a line terminator only when the file did
    /// not end with one. Existing bytes are never rewritten.
    static func insertHookLine(into text: String) -> String {
        if text.isEmpty { return hookLine + "\n" }
        if text.hasSuffix("\n") { return text + hookLine + "\n" }
        return text + "\n" + hookLine + "\n"
    }
}
