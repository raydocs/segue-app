import Foundation
import XCTest

@testable import SegueAILayer

enum AIFixtureError: Error, CustomStringConvertible {
    case missing(String, String)

    var description: String {
        switch self {
        case let .missing(name, path):
            return "missing fixture \(name) in \(path)"
        }
    }
}

enum AIFixtures {
    /// Loads a fixture from `Tests/SegueAILayerTests/Fixtures`. `ai-lock.txt`
    /// is a byte-identical copy of the kernel's built-in list,
    /// `segue-core/crates/segue-kernel/data/ai-lock.txt` at the commit this
    /// test was written; it is refreshed from there, never hand-edited, so
    /// the parser is pinned to the real shipped format.
    static func text(named name: String) throws -> String {
        let bundle = Bundle.module
        let candidates = [
            bundle.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"),
            bundle.url(forResource: "Fixtures/\(name)", withExtension: "txt"),
            bundle.url(forResource: name, withExtension: "txt"),
        ]
        guard let url = candidates.compactMap({ $0 }).first else {
            throw AIFixtureError.missing(name, bundle.bundlePath)
        }
        guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            throw AIFixtureError.missing(name, url.path)
        }
        return text
    }
}
