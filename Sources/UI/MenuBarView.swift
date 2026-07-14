import SwiftUI

/// The mid-movie panel: quick volume and mute without leaving fullscreen.
struct MenuBarView: View {
    @Environment(RouteSupervisor.self) private var supervisor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if supervisor.table.routes.isEmpty {
                Text("No routes")
                    .foregroundStyle(.secondary)
            }
            ForEach(supervisor.table.routes) { route in
                HStack(spacing: 8) {
                    Text(route.appDisplayName)
                        .frame(width: 110, alignment: .leading)
                        .lineLimit(1)
                    if route.kind == .tapped {
                        Slider(value: Binding(
                            get: { route.volume },
                            set: { v in var r = route; r.volume = v; supervisor.update(r) }
                        ), in: 0...2)
                        .frame(width: 130)
                        Button {
                            var r = route
                            r.isMuted.toggle()
                            supervisor.update(r)
                        } label: {
                            Image(systemName: route.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .foregroundStyle(route.isMuted ? .red : .primary)
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Text(route.primaryLeg?.deviceName ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                Button("Open Split") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(12)
        .frame(width: 300)
    }
}
