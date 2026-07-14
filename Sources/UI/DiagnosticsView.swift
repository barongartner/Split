import SwiftUI
import CoreAudio

/// Everything that fails in this domain fails as silence, so this window is
/// the difference between debugging and guessing: live meters, the raw
/// process/device view, and a big rebuild button.
struct DiagnosticsView: View {
    @Environment(RouteSupervisor.self) private var supervisor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Routes") {
                    if supervisor.table.routes.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(supervisor.table.routes) { route in
                        HStack {
                            Text(route.appDisplayName).frame(width: 140, alignment: .leading)
                            Text(statusText(for: route.id))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 180, alignment: .leading)
                            ProgressView(value: Double(min(supervisor.levels[route.id] ?? 0, 1)))
                                .frame(width: 120)
                            Text(String(format: "%.4f", supervisor.levels[route.id] ?? 0))
                                .font(.caption.monospacedDigit())
                        }
                    }
                    Button("Force Rebuild All Routes") { supervisor.forceRebuildAll() }
                        .padding(.top, 6)
                }

                GroupBox("Output devices") {
                    ForEach(supervisor.deviceMonitor.outputDevices) { device in
                        HStack {
                            Text(device.name).frame(width: 200, alignment: .leading)
                            Text(device.isBluetooth ? "Bluetooth" : transportName(device.transport))
                                .frame(width: 90, alignment: .leading)
                            Text("\(Int(device.sampleRate)) Hz").frame(width: 80, alignment: .leading)
                            Text(device.uid).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .font(.callout)
                    }
                    if let def = supervisor.deviceMonitor.defaultOutputUID {
                        Text("System default: \(supervisor.deviceMonitor.device(uid: def)?.name ?? def)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Audio processes (grouped by app)") {
                    ForEach(supervisor.processMonitor.apps) { app in
                        HStack {
                            Circle()
                                .fill(app.isPlayingOutput ? .green : .gray.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Text(app.name).frame(width: 180, alignment: .leading)
                            Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(app.objectIDs.count) process\(app.objectIDs.count == 1 ? "" : "es")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
            .padding()
        }
    }

    private func statusText(for id: UUID) -> String {
        switch supervisor.statuses[id] ?? .disabled {
        case .disabled: return "off"
        case .waitingForApp: return "waiting for app"
        case .waitingForAudio: return "engine live, no audio yet"
        case .active: return "active"
        case .rebuilding: return "rebuilding"
        case .deviceMissing: return "device missing"
        case .protectedAudio: return "capturing silence (DRM/permission)"
        case .direct: return "direct (system default)"
        case .failed(let msg): return "failed: \(msg)"
        }
    }

    private func transportName(_ t: UInt32) -> String {
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        default: return "Other"
        }
    }
}
