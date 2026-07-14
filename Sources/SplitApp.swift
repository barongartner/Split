import SwiftUI
import ServiceManagement

@MainActor
final class AppState {
    static let shared = AppState()

    let processMonitor: AudioProcessMonitor
    let deviceMonitor: AudioDeviceMonitor
    let supervisor: RouteSupervisor

    private init() {
        let processMonitor = AudioProcessMonitor()
        let deviceMonitor = AudioDeviceMonitor()
        self.processMonitor = processMonitor
        self.deviceMonitor = deviceMonitor
        self.supervisor = RouteSupervisor(processMonitor: processMonitor,
                                          deviceMonitor: deviceMonitor,
                                          store: RouteStore())
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Taps auto-unmute their apps when destroyed, and the system default
        // output goes back to whatever it was before the Direct route took it.
        AppState.shared.supervisor.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // keep routing while the window is closed; quit via menu bar
    }
}

@main
struct SplitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Split", id: "main") {
            RoutesView()
                .environment(AppState.shared.supervisor)
        }
        .defaultSize(width: 620, height: 480)

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView()
                .environment(AppState.shared.supervisor)
        }
        .defaultSize(width: 640, height: 520)

        MenuBarExtra("Split", systemImage: "arrow.triangle.branch") {
            MenuBarView()
                .environment(AppState.shared.supervisor)
        }
        .menuBarExtraStyle(.window)
    }
}
