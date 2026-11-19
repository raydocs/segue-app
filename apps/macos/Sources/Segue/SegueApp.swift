import AppKit
import Combine
import Network
import SegueKit
import SwiftUI

/// Menu-bar accessory shell (hidden Dock icon). Connect arms the helper;
/// Disconnect and a confirmed Restore network disarm with `user_disconnect`.
/// Quitting never disarms the AI lock.
@main
struct SegueApp: App {
    @NSApplicationDelegateAdaptor(SegueAppDelegate.self) private var appDelegate
    @StateObject private var model: ConnectionModel
    @StateObject private var iconStore: MenuBarIconStore

    init() {
        let folder = SeguePaths.userConfigFolder()
        let client = ResolvingKernelControlClient(tokenFile: SeguePaths.defaultTokenFile())
        let helper = HelperClient.connectedToHelperSocket()
        let release = ReleaseClient.connectedToReleaseSocket()
        let model = ConnectionModel(
            client: client,
            configFolder: folder,
            helper: helper,
            release: release,
            clock: SystemPollClock(),
            startsPolling: true
        )
        let iconStore = MenuBarIconStore(model: model)
        _model = StateObject(wrappedValue: model)
        _iconStore = StateObject(wrappedValue: iconStore)
        RuntimeKeepAlive.hold(SystemEventBridge(model: model))
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            SeguePopoverView(model: model)
        } label: {
            Image(nsImage: iconStore.image)
                .accessibilityLabel("Segue")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Ensures macOS keeps the app as a pure top menu-bar accessory (no Dock icon)
/// even when launched from Finder or a packaged `.app` bundle.
final class SegueAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Owns the rendered 3/4 sculpted Lumina Manta template image for the top menu bar.
/// Ticks at ~12 fps only while connecting (when calm/reduce-motion is off); zero idle CPU.
@MainActor
final class MenuBarIconStore: ObservableObject {
    @Published private(set) var image: NSImage

    private var visualState: MantaVisualState = .off
    private var animationTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(model: ConnectionModel) {
        let initial = MantaVisualState.from(model: model)
        visualState = initial
        image = LuminaMantaEngine.renderMenuBarTemplateImage(state: initial, phase: 1.25)

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self, weak model] _ in
                Task { @MainActor [weak self, weak model] in
                    guard let self, let model else { return }
                    self.sync(to: MantaVisualState.from(model: model))
                }
            }
            .store(in: &cancellables)
    }

    private func sync(to next: MantaVisualState) {
        let calm = UserDefaults.standard.bool(forKey: "segue.calmMotion")
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if next != visualState {
            visualState = next
            image = LuminaMantaEngine.renderMenuBarTemplateImage(state: next, phase: 1.25)
        }
        if next == .connecting && !calm {
            startConnectingAnimation()
        } else {
            stopAnimation()
        }
    }

    private func startConnectingAnimation() {
        guard animationTask == nil else { return }
        animationTask = Task { @MainActor [weak self] in
            var phase = 1.25
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 85_000_000)
                guard !Task.isCancelled, let self, self.visualState == .connecting else {
                    break
                }
                phase += 0.095
                self.image = LuminaMantaEngine.renderMenuBarTemplateImage(state: .connecting, phase: phase)
            }
            self?.animationTask = nil
        }
    }

    private func stopAnimation() {
        animationTask?.cancel()
        animationTask = nil
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
