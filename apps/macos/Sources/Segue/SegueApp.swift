import AppKit
import Network
import SegueKit
import SwiftUI

/// Menu-bar shell. Connect arms the helper; Disconnect and a confirmed
/// Restore network disarm with `user_disconnect`. Quitting does not disarm.
@main
struct SegueApp: App {
    @StateObject private var model: ConnectionModel

    init() {
        let folder = SeguePaths.userConfigFolder()
        let client = ResolvingKernelControlClient(tokenFile: SeguePaths.defaultTokenFile())
        let helper = HelperClient.connectedToHelperSocket()
        let model = ConnectionModel(
            client: client,
            configFolder: folder,
            helper: helper,
            clock: SystemPollClock(),
            startsPolling: true
        )
        _model = StateObject(wrappedValue: model)
        RuntimeKeepAlive.hold(SystemEventBridge(model: model))
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.showsConnected ? "lock.shield.fill" : "lock.shield")
                .accessibilityLabel("Segue")
        }
        .menuBarExtraStyle(.window)
    }
}

private enum RuntimeKeepAlive {
    static var objects: [AnyObject] = []

    static func hold(_ object: AnyObject) {
        objects.append(object)
    }
}

/// Wake, network changes, and quit. The bridge never disarms.
private final class SystemEventBridge {
    private let model: ConnectionModel
    private var monitor: NWPathMonitor?
    private var observers: [NSObjectProtocol] = []

    init(model: ConnectionModel) {
        self.model = model
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [model] _ in
            Task { @MainActor in
                model.noteWake()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [model] _ in
            Task { @MainActor in
                model.applicationWillQuit()
            }
        })
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [model] _ in
            Task { @MainActor in
                model.noteNetworkChange()
            }
        }
        monitor.start(queue: DispatchQueue(label: "segue.network-path"))
        self.monitor = monitor
    }
}

private struct MenuContent: View {
    @ObservedObject var model: ConnectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Segue")
                .font(.headline)
            Text(model.statusLine)
                .fixedSize(horizontal: false, vertical: true)
            if !model.reasonText.isEmpty {
                Text(model.reasonText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let lastError = model.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.restoreNeedsConfirmation {
                Text("Restore network drops the AI lock and disconnects. Nothing changes until you confirm.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Confirm restore") {
                        Task { await model.confirmRestoreNetwork() }
                    }
                    Button("Cancel") {
                        model.cancelRestoreNetwork()
                    }
                }
                .disabled(model.isBusy)
            } else {
                HStack {
                    Button("Connect") {
                        Task { await model.connect() }
                    }
                    Button("Disconnect") {
                        Task { await model.disconnect() }
                    }
                }
                .disabled(model.isBusy)
                Button("Restore network") {
                    model.requestRestoreNetwork()
                }
                .disabled(model.isBusy)
            }
            Divider()
            Button("Open config folder") {
                openConfigFolder()
            }
            Text("Kernel JSON and the signed bundle go here. No accounts.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Export diagnostics") {
                exportDiagnostics()
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { model.setMenuOpen(true) }
        .onDisappear { model.setMenuOpen(false) }
    }

    private func openConfigFolder() {
        do {
            try model.ensureConfigFolder()
            activateApp()
            guard NSWorkspace.shared.open(model.configFolder) else {
                model.present(error: "Couldn't open the config folder.")
                return
            }
        } catch {
            model.present(error: "Couldn't open the config folder.")
        }
    }

    private func exportDiagnostics() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder for the redacted diagnostics zip."
        activateApp()
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            _ = try model.exportDiagnosticsZip(to: url)
            model.present(notice: "Diagnostics exported.")
        } catch {
            model.present(error: "Couldn't write the diagnostics file.")
        }
    }

    private func activateApp() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
