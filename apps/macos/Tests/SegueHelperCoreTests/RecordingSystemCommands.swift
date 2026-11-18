import Foundation
import SegueAILayer

@testable import SegueHelperCore

struct RecordingFault: Error, Equatable {
    var label: String
}

/// In-memory pfctl, networksetup, and files. Never touches the real system.
final class RecordingSystemCommands: SystemCommands {
    private(set) var files: [String: String] = [:]
    private(set) var anchorRules: String?
    private(set) var services: [DNSServiceRecord]
    private(set) var guardPort: UInt16?
    private(set) var guardSuffixes: [String] = []
    private(set) var invocations: [String] = []
    private(set) var injected: [String] = []
    var failCallIndex: Int?
    private var callsSoFar = 0

    init() {
        services = [
            DNSServiceRecord(serviceID: "en0", name: "Wi-Fi", servers: ["192.0.2.1"]),
            DNSServiceRecord(serviceID: "en1", name: "Ethernet", servers: []),
        ]
    }

    func resetCounter() {
        callsSoFar = 0
        injected.removeAll()
    }

    func discardLog() {
        invocations.removeAll()
    }

    func seedFile(_ path: String, contents: String) {
        files[path] = contents
    }

    func seedAnchor(_ rules: String?) {
        anchorRules = rules
    }

    func run(program: String, arguments: [String], standardInput: String?) throws -> SystemCommandOutput {
        try check("\(program) \(arguments.joined(separator: " "))")
        if program == SystemPrograms.pfctl {
            return pfctl(arguments, standardInput)
        }
        if program == SystemPrograms.networksetup {
            return networksetup(arguments)
        }
        return SystemCommandOutput(status: 127, stdout: "", stderr: "unexpected program \(program)")
    }

    func readTextFile(_ path: String) throws -> String {
        try check("read \(path)")
        guard let text = files[path] else { throw RecordingFault(label: "missing \(path)") }
        return text
    }

    func writeTextFile(_ path: String, _ contents: String) throws {
        try check("write \(path)")
        files[path] = contents
    }

    func removeFile(_ path: String) throws {
        try check("remove \(path)")
        files[path] = nil
    }

    func fileExists(_ path: String) -> Bool {
        files[path] != nil
    }

    func startGuardListener(address: String, port: UInt16, responder: GuardResponder) throws {
        try check("guard-start \(address):\(port)")
        guardPort = port
        guardSuffixes = responder.armedSuffixes
    }

    func stopGuardListener() throws {
        try check("guard-stop")
        guardPort = nil
        guardSuffixes = []
    }

    func guardIsListening() -> Bool {
        guardPort != nil
    }

    private func check(_ label: String) throws {
        let index = callsSoFar
        callsSoFar += 1
        invocations.append(label)
        if index == failCallIndex {
            injected.append(label)
            throw RecordingFault(label: label)
        }
    }

    private func pfctl(_ arguments: [String], _ stdin: String?) -> SystemCommandOutput {
        if arguments == ["-s", "Anchors"] {
            let stdout = anchorRules == nil ? "" : "  \(PFAnchorRenderer.anchorName)\n"
            return SystemCommandOutput(status: 0, stdout: stdout, stderr: "")
        }
        if arguments == ["-a", PFAnchorRenderer.anchorName, "-F", "all"] {
            anchorRules = nil
            return SystemCommandOutput(status: 0, stdout: "", stderr: "")
        }
        if arguments == ["-a", PFAnchorRenderer.anchorName, "-f", "-"] {
            anchorRules = stdin ?? ""
            return SystemCommandOutput(status: 0, stdout: "", stderr: "")
        }
        return SystemCommandOutput(status: 1, stdout: "", stderr: "unexpected pfctl \(arguments)")
    }

    private func networksetup(_ arguments: [String]) -> SystemCommandOutput {
        if arguments == ["-listnetworkserviceorder"] {
            return SystemCommandOutput(status: 0, stdout: serviceOrderText(), stderr: "")
        }
        if arguments.first == "-getdnsservers", arguments.count == 2 {
            guard let service = services.first(where: { $0.name == arguments[1] }) else {
                return SystemCommandOutput(status: 1, stdout: "", stderr: "service not found")
            }
            if service.servers.isEmpty {
                let stdout = "There aren't any DNS Servers set on \(service.name).\n"
                return SystemCommandOutput(status: 0, stdout: stdout, stderr: "")
            }
            return SystemCommandOutput(
                status: 0,
                stdout: service.servers.joined(separator: "\n") + "\n",
                stderr: ""
            )
        }
        if arguments.first == "-setdnsservers", arguments.count >= 3 {
            guard let index = services.firstIndex(where: { $0.name == arguments[1] }) else {
                return SystemCommandOutput(status: 1, stdout: "", stderr: "service not found")
            }
            let existing = services[index]
            let requested = Array(arguments.dropFirst(2))
            let servers = requested == ["Empty"] ? [] : requested
            services[index] = DNSServiceRecord(
                serviceID: existing.serviceID,
                name: existing.name,
                servers: servers
            )
            return SystemCommandOutput(status: 0, stdout: "", stderr: "")
        }
        return SystemCommandOutput(status: 1, stdout: "", stderr: "unexpected networksetup \(arguments)")
    }

    private func serviceOrderText() -> String {
        var lines = ["An asterisk (*) denotes that a network service is disabled.", ""]
        for (offset, service) in services.enumerated() {
            lines.append("(\(offset + 1)) \(service.name)")
            lines.append("(Hardware Port: \(service.name), Device: \(service.serviceID))")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
