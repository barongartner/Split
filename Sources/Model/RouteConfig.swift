// The persisted description of what the user wants. Everything here is plain
// Codable value types; the supervisor turns this into live engines.
//
// legs is an array even though v1 only ever uses one entry — fan-out (one app
// to several outputs at once) is planned, and keeping the schema ready means
// no config migration when it lands.

import Foundation

enum RouteKind: String, Codable {
    /// Captured via a process tap and re-rendered to the chosen device.
    case tapped
    /// No capture: this route's device becomes the system default output.
    /// The one mechanism that works with FairPlay-protected apps (Apple TV,
    /// Netflix in Safari) — and the bucket every unrouted app falls into.
    case direct
}

struct OutputLeg: Codable, Equatable {
    var deviceUID: String
    var deviceName: String   // cached for display while the device is unplugged
}

struct RouteConfig: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var kind: RouteKind = .tapped
    var appBundleIDs: [String] = []    // empty for .direct
    var appDisplayName: String = ""    // cached for display while the app is closed
    var legs: [OutputLeg] = []
    var volume: Double = 1.0           // 0...2, tapped only
    var delayMs: Double = 0            // 0...1000, tapped only
    var isMuted: Bool = false
    var isEnabled: Bool = true

    var primaryLeg: OutputLeg? { legs.first }
}

struct RoutingTable: Codable, Equatable {
    var routes: [RouteConfig] = []
}

struct Preset: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var table: RoutingTable
}
