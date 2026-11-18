import Foundation
import XCTest

@testable import SegueKit

enum FixtureError: Error, CustomStringConvertible {
    case missing(String, String)

    var description: String {
        switch self {
        case let .missing(name, path):
            return "missing fixture \(name) in \(path)"
        }
    }
}

enum Fixtures {
    static func data(named name: String) throws -> Data {
        let bundle = Bundle.module
        let candidates = [
            bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            bundle.url(forResource: name, withExtension: "json"),
            bundle.url(forResource: "Fixtures/\(name)", withExtension: "json"),
        ]
        guard let url = candidates.compactMap({ $0 }).first else {
            throw FixtureError.missing(name, bundle.bundlePath)
        }
        return try Data(contentsOf: url)
    }

    static func status(_ name: String) throws -> KernelStatus {
        try JSONDecoder().decode(KernelStatus.self, from: data(named: name))
    }

    static func envelope(_ name: String) throws -> HelperEnvelope {
        try JSONDecoder().decode(HelperEnvelope.self, from: data(named: name))
    }
}

func temporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func writeTokenFile(addr: String, token: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("control.json")
    let body = #"{"addr":"\#(addr)","token":"\#(token)"}"#
    try Data(body.utf8).write(to: url)
    return url
}
