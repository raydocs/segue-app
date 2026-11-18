import AppKit
import SegueKit
import SwiftUI

/// Menu-bar shell. It does not install a helper, take root, or open a
/// connection until Connect or Disconnect is pressed. Those calls go to
/// 127.0.0.1 only, through whatever `ControlClient` the model holds.
@main
struct SegueApp: App {
    @StateObject private var model: ConnectionModel

    init() {
        let folder = SeguePaths.userConfigFolder()
        let client = ResolvingKernelControlClient(tokenFile: SeguePaths.defaultTokenFile())
        _model = StateObject(
            wrappedValue: ConnectionModel(client: client, configFolder: folder)
        )
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

private struct MenuContent: View {
    @ObservedObject var model: ConnectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Segue")
                .font(.headline)
            Text(model.statusLine)
                .fixedSize(horizontal: false, vertical: true)
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
            HStack {
                Button("Connect") {
                    Task { await model.connect() }
                }
                Button("Disconnect") {
                    Task { await model.disconnect() }
                }
            }
            .disabled(model.isBusy)
            Divider()
            Button("Open config folder") {
                openConfigFolder()
            }
            Button("Export diagnostics") {
                exportDiagnostics()
            }
        }
        .padding(12)
        .frame(width: 280)
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
        panel.message = "Choose a folder for the redacted diagnostics file."
        activateApp()
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            _ = try model.exportDiagnostics(to: url)
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
