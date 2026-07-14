import SwiftUI

struct AddRouteView: View {
    @Environment(RouteSupervisor.self) private var supervisor
    @Environment(\.dismiss) private var dismiss

    @State private var selectedBundleID: String?
    @State private var isDirect = false
    @State private var deviceUID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Route audio")
                .font(.title2.weight(.semibold))

            Text("Pick what to route. Apps show up here once they've played any audio.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List(selection: $selectedBundleID) {
                Section {
                    HStack {
                        Image(systemName: "asterisk.circle.fill").foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text("Everything else (Direct)")
                            Text("Makes a device the system output. Works with every app, including DRM video (Apple TV, Netflix in Safari).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag("__direct__")
                }
                Section("Apps playing or able to play audio") {
                    ForEach(supervisor.processMonitor.apps) { app in
                        HStack {
                            if let icon = AudioProcessMonitor.icon(forBundleID: app.bundleID) {
                                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                            } else {
                                Image(systemName: "app").frame(width: 22)
                            }
                            Text(app.name)
                            Spacer()
                            if app.isPlayingOutput {
                                Label("audible now", systemImage: "waveform")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                        .tag(app.bundleID)
                    }
                }
            }
            .frame(minHeight: 220)

            HStack {
                Text("To:")
                Picker("", selection: $deviceUID) {
                    ForEach(supervisor.deviceMonitor.outputDevices) { device in
                        HStack {
                            Text(device.name)
                            if device.isBluetooth { Image(systemName: "wave.3.right") }
                        }.tag(device.uid)
                    }
                }
                .labelsHidden()
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add Route") { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedBundleID == nil || deviceUID.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            supervisor.processMonitor.refresh()
            deviceUID = supervisor.deviceMonitor.defaultOutputUID
                ?? supervisor.deviceMonitor.outputDevices.first?.uid ?? ""
        }
    }

    private func add() {
        defer { dismiss() }
        if selectedBundleID == "__direct__" {
            supervisor.addDirectRoute(deviceUID: deviceUID)
        } else if let bundleID = selectedBundleID,
                  let app = supervisor.processMonitor.app(bundleID: bundleID) {
            supervisor.addTappedRoute(app: app, deviceUID: deviceUID)
        }
    }
}
