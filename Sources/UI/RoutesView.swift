import SwiftUI
import ServiceManagement

struct RoutesView: View {
    @Environment(RouteSupervisor.self) private var supervisor
    @Environment(\.openWindow) private var openWindow
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @State private var showingAdd = false
    @State private var showingSync = false
    @State private var showingSavePreset = false
    @State private var presetName = ""

    var body: some View {
        VStack(spacing: 0) {
            if supervisor.bluetoothLegCount > 2 {
                WarningBanner(text: "Two Bluetooth headphones is the reliable ceiling on this Mac — make the third route wired or use the speakers.")
            }

            if supervisor.table.routes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(supervisor.table.routes) { route in
                            RouteCardView(route: route)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .toolbar {
            ToolbarItem(placement: .automatic) { presetsMenu }
            ToolbarItem(placement: .automatic) {
                Button {
                    showingSync = true
                } label: {
                    Label("Sync", systemImage: "metronome")
                }
                .help("Beat-match everyone's headphones — ~15 seconds per person")
                .disabled(supervisor.table.routes.isEmpty)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    openWindow(id: "diagnostics")
                } label: {
                    Label("Diagnostics", systemImage: "waveform.badge.magnifyingglass")
                }
                .help("Live meters and rebuild controls")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Label("Route an app…", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddRouteView()
                .environment(supervisor)
        }
        .sheet(isPresented: $showingSync) {
            SyncWizardView()
                .environment(supervisor)
        }
        .sheet(isPresented: onboardingBinding) {
            OnboardingView { hasSeenOnboarding = true }
        }
        .alert("Save Preset", isPresented: $showingSavePreset) {
            TextField("Name (e.g. Movie night)", text: $presetName)
            Button("Save") {
                if !presetName.isEmpty { supervisor.savePreset(named: presetName) }
                presetName = ""
            }
            Button("Cancel", role: .cancel) { presetName = "" }
        } message: {
            Text("Saves the current routes so you can bring them all back in one click.")
        }
        .onChange(of: launchAtLogin) { _, enable in
            try? enable ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }

    private var onboardingBinding: Binding<Bool> {
        Binding(get: { !hasSeenOnboarding }, set: { hasSeenOnboarding = !$0 })
    }

    private var presetsMenu: some View {
        Menu {
            if supervisor.presets.isEmpty {
                Text("No presets yet")
            }
            ForEach(supervisor.presets) { preset in
                Button(preset.name) { supervisor.apply(preset: preset) }
            }
            if !supervisor.presets.isEmpty {
                Menu("Delete") {
                    ForEach(supervisor.presets) { preset in
                        Button(preset.name, role: .destructive) { supervisor.deletePreset(preset.id) }
                    }
                }
            }
            Divider()
            Button("Save Current as Preset…") { showingSavePreset = true }
            Divider()
            Toggle("Launch at Login", isOn: $launchAtLogin)
        } label: {
            Label("Presets", systemImage: "square.stack")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No routes yet")
                .font(.title3.weight(.semibold))
            Text("Route an app's audio to any headphones or speakers.\nEveryone on this Mac can listen to their own thing.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Route an app…") { showingAdd = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WarningBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(text)
                .font(.callout)
            Spacer()
        }
        .padding(10)
        .background(.yellow.opacity(0.12))
    }
}
