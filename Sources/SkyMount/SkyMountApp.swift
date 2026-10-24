import SwiftUI
import SkyMountCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    /// Opens the Connections window; set by the menu bar label once SwiftUI can open windows.
    var showConnections: (() -> Void)?

    /// Opening SkyMount again (Finder, Spotlight, Launchpad) shows the Connections window. Without
    /// this a menu bar app looks like it did not start, e.g. when its icon sits behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("connections") == true }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            showConnections?()
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Unmount first: a webdavfs volume whose server vanished hangs Finder until it times out.
        MainActor.assumeIsolated { model?.unmountAllBlocking() }
        return .terminateNow
    }
}

@main
struct SkyMountApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
                .onAppear { delegate.model = model }
        } label: {
            MenuBarLabel(mounted: model.anyMounted, transferring: model.isTransferring) { delegate.showConnections = $0 }
        }
        .menuBarExtraStyle(.menu)

        Window("Connections", id: "connections") {
            ConnectionsWindow()
                .environmentObject(model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 760, height: 520)
        // First run has nothing in the menu yet, so open the window where connections are added.
        .defaultLaunchBehavior(ConnectionStore.load().isEmpty ? .presented : .suppressed)
    }
}

/// Sync arrows while files move, a filled drive while anything is mounted, an outline drive
/// otherwise, so the state is visible without opening the menu.
/// Also hands the app delegate a way to open the Connections window.
private struct MenuBarLabel: View {
    let mounted: Bool
    let transferring: Bool
    let register: (@escaping () -> Void) -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: transferring ? "arrow.triangle.2.circlepath"
              : mounted ? "externaldrive.connected.to.line.below.fill" : "externaldrive.connected.to.line.below")
            .accessibilityLabel(transferring ? "SkyMount, transferring files"
                                : mounted ? "SkyMount, volumes mounted" : "SkyMount")
            .onAppear {
                register {
                    openWindow(id: "connections")
                    NSApp.activate()
                }
            }
    }
}
