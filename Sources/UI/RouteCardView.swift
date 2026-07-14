import SwiftUI

struct RouteCardView: View {
    @Environment(RouteSupervisor.self) private var supervisor
    let route: RouteConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                appIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.appDisplayName)
                        .font(.headline)
                    statusBadge
                }
                Spacer()
                devicePicker
                Button {
                    var r = route
                    r.isMuted.toggle()
                    supervisor.update(r)
                } label: {
                    Image(systemName: route.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(route.isMuted ? .red : .primary)
                }
                .buttonStyle(.borderless)
                .help(route.isMuted ? "Unmute" : "Mute")
                .opacity(route.kind == .tapped ? 1 : 0)
                Button {
                    supervisor.remove(route.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove route")
            }

            if route.kind == .tapped {
                controls
                hints
            } else {
                Text("Direct route: this device is the system output. Anything you don't route — including DRM video apps like Apple TV — plays here. No delay is added, so tune the other routes' delays to match this one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    // MARK: - Pieces

    private var appIcon: some View {
        Group {
            if route.kind == .direct {
                Image(systemName: "asterisk.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
            } else if let bundleID = route.appBundleIDs.first,
                      let icon = AudioProcessMonitor.icon(forBundleID: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 34, height: 34)
    }

    private var status: RouteStatus {
        supervisor.statuses[route.id] ?? .disabled
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch status {
            case .disabled: return ("Off", .secondary)
            case .waitingForApp: return ("Waiting for \(route.appDisplayName) to run", .secondary)
            case .waitingForAudio: return ("Ready — waiting for audio", .secondary)
            case .active: return ("Playing", .green)
            case .rebuilding: return ("Reconnecting…", .orange)
            case .deviceMissing: return ("\(route.primaryLeg?.deviceName ?? "Device") is disconnected", .orange)
            case .protectedAudio: return ("No audio captured — likely protected (DRM)", .red)
            case .direct: return ("System output", .blue)
            case .failed(let msg): return ("Failed: \(msg)", .red)
            }
        }()
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var devicePicker: some View {
        Picker("", selection: Binding(
            get: { route.primaryLeg?.deviceUID ?? "" },
            set: { uid in
                guard let device = supervisor.deviceMonitor.device(uid: uid) else { return }
                var r = route
                r.legs = [OutputLeg(deviceUID: device.uid, deviceName: device.name)]
                supervisor.update(r)
            }
        )) {
            ForEach(supervisor.deviceMonitor.outputDevices) { device in
                HStack {
                    Text(device.name)
                    if device.isBluetooth { Image(systemName: "wave.3.right") }
                }.tag(device.uid)
            }
            if let leg = route.primaryLeg, supervisor.deviceMonitor.device(uid: leg.deviceUID) == nil {
                Text("\(leg.deviceName) (disconnected)").tag(leg.deviceUID)
            }
        }
        .frame(width: 210)
        .labelsHidden()
    }

    private var controls: some View {
        HStack(spacing: 24) {
            // Volume + meter
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.1")
                    .foregroundStyle(.secondary)
                ZStack(alignment: .leading) {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.green.opacity(0.35))
                            .frame(width: geo.size.width * CGFloat(min(supervisor.levels[route.id] ?? 0, 1)),
                                   height: 4)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    Slider(value: Binding(
                        get: { route.volume },
                        set: { v in var r = route; r.volume = v; supervisor.update(r) }
                    ), in: 0...2)
                }
                Text("\(Int(route.volume * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            .frame(maxWidth: .infinity)

            // Delay
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .help("Delay this route to sync with slower (Bluetooth) listeners")
                Slider(value: Binding(
                    get: { route.delayMs },
                    set: { v in var r = route; r.delayMs = v; supervisor.update(r) }
                ), in: 0...1000)
                .frame(width: 130)
                Stepper(value: Binding(
                    get: { route.delayMs },
                    set: { v in var r = route; r.delayMs = min(max(v, 0), 1000); supervisor.update(r) }
                ), in: 0...1000, step: 10) {
                    Text("\(Int(route.delayMs)) ms")
                        .font(.caption.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private var hints: some View {
        if status == .protectedAudio {
            HStack(spacing: 8) {
                Text("This app's audio can't be captured — it's DRM-protected, or Split was denied the recording permission. If it's a video app, the Direct route plays it fine (or play the site in Chrome).")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Make this the Direct route") { supervisor.convertToDirect(route.id) }
                    .font(.caption)
            }
        } else if let bundleID = route.appBundleIDs.first,
                  RouteSupervisor.browserBundleIDs.contains(bundleID) {
            Text("All of this browser's tabs share one route — use a different browser or app for each listener.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
