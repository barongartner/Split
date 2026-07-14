// The reconciler. Owns every live RouteEngine and the Direct route's
// default-device switch, and continuously drives reality toward the routing
// table. Every recovery path — app relaunch, device unplug, sample-rate flip,
// the zero-buffer tap bug — funnels through the same reconcile pass, because
// four separate event handlers is how routing apps end up subtly wrong.
//
// The 1 Hz watchdog exists because everything that fails in this API fails as
// silence with noErr: a denied permission, DRM-protected audio, and the known
// intermittent tap decay (Apple forums thread 825780) are indistinguishable at
// the API level. The watchdog rebuilds when the app claims to be playing but
// the tap delivers nothing, and if rebuilding doesn't help it flags the route
// as protected audio so the UI can suggest the Direct route.

import Foundation
import CoreAudio
import Observation

enum RouteStatus: Equatable {
    case disabled
    case waitingForApp        // route exists, app not running / no audio process yet
    case waitingForAudio      // engine live, nothing audible yet
    case active               // engine live, audio flowing
    case rebuilding
    case deviceMissing
    case protectedAudio       // playing but capturing silence — DRM or denied permission
    case direct               // direct route, currently the system default
    case failed(String)
}

@MainActor
@Observable
final class RouteSupervisor {

    private(set) var table: RoutingTable
    private(set) var statuses: [UUID: RouteStatus] = [:]
    private(set) var levels: [UUID: Float] = [:]     // smoothed meter per route
    private(set) var presets: [Preset]

    let processMonitor: AudioProcessMonitor
    let deviceMonitor: AudioDeviceMonitor
    @ObservationIgnored private let store: RouteStore

    @ObservationIgnored private var engines: [UUID: RouteEngine] = [:]
    @ObservationIgnored private var rateListeners: [UUID: CAListener] = [:]
    @ObservationIgnored private var watchdogTimer: Timer?
    @ObservationIgnored private var zeroSince: [UUID: TimeInterval] = [:]
    @ObservationIgnored private var lastRebuildAt: [UUID: TimeInterval] = [:]
    @ObservationIgnored private var buildsInFlight: Set<UUID> = []
    @ObservationIgnored private let buildQueue = DispatchQueue(label: "split.route-build", qos: .userInitiated)

    /// The default output device the user had before the first Direct route
    /// took over, persisted so a crash can't strand the system on someone
    /// else's headphones.
    @ObservationIgnored private var savedDefaultUID: String? {
        get { UserDefaults.standard.string(forKey: "savedDefaultOutputUID") }
        set { UserDefaults.standard.set(newValue, forKey: "savedDefaultOutputUID") }
    }

    init(processMonitor: AudioProcessMonitor, deviceMonitor: AudioDeviceMonitor, store: RouteStore) {
        self.processMonitor = processMonitor
        self.deviceMonitor = deviceMonitor
        self.store = store
        self.table = store.loadTable()
        self.presets = store.loadPresets()

        deviceMonitor.onChange = { [weak self] in self?.reconcile() }

        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdogTick() }
        }

        // Process list changes arrive via the monitor's refresh; observe by
        // polling its apps in the watchdog and reconciling on change is too
        // lazy — hook it directly:
        _ = withObservationTracking { processMonitor.apps } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeProcessChanges()
                self?.reconcile()
            }
        }

        reconcile()
    }

    private func observeProcessChanges() {
        _ = withObservationTracking { processMonitor.apps } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeProcessChanges()
                self?.reconcile()
            }
        }
    }

    // MARK: - Table mutations (UI entry points)

    func addTappedRoute(app: AudioApp, deviceUID: String) {
        guard let device = deviceMonitor.device(uid: deviceUID) else { return }
        var route = RouteConfig()
        route.kind = .tapped
        route.appBundleIDs = [app.bundleID]
        route.appDisplayName = app.name
        route.legs = [OutputLeg(deviceUID: device.uid, deviceName: device.name)]
        // Seed the delay with the device's reported latency — a hint, not truth.
        route.delayMs = Double(CA.reportedOutputLatencyFrames(device.id)) / max(device.sampleRate, 1) * 1000
        table.routes.append(route)
        persistAndReconcile()
    }

    func addDirectRoute(deviceUID: String) {
        guard let device = deviceMonitor.device(uid: deviceUID) else { return }
        // Only one Direct route can exist — there is only one system default.
        table.routes.removeAll { $0.kind == .direct }
        var route = RouteConfig()
        route.kind = .direct
        route.appDisplayName = "Everything else"
        route.legs = [OutputLeg(deviceUID: device.uid, deviceName: device.name)]
        table.routes.append(route)
        persistAndReconcile()
    }

    func update(_ route: RouteConfig) {
        guard let idx = table.routes.firstIndex(where: { $0.id == route.id }) else { return }
        table.routes[idx] = route
        // Live-tweak without a rebuild when only volume/delay/mute changed.
        engines[route.id]?.update(volume: route.volume, delayMs: route.delayMs, muted: route.isMuted)
        persistAndReconcile()
    }

    func remove(_ routeID: UUID) {
        table.routes.removeAll { $0.id == routeID }
        persistAndReconcile()
    }

    func convertToDirect(_ routeID: UUID) {
        guard let idx = table.routes.firstIndex(where: { $0.id == routeID }) else { return }
        let leg = table.routes[idx].legs
        table.routes.removeAll { $0.kind == .direct }
        if let idx2 = table.routes.firstIndex(where: { $0.id == routeID }) {
            table.routes[idx2].kind = .direct
            table.routes[idx2].legs = leg
        }
        persistAndReconcile()
    }

    func apply(preset: Preset) {
        table = preset.table
        persistAndReconcile()
    }

    func savePreset(named name: String) {
        presets.removeAll { $0.name == name }
        presets.append(Preset(name: name, table: table))
        store.save(presets: presets)
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        store.save(presets: presets)
    }

    func forceRebuildAll() {
        for (_, engine) in engines { engine.invalidate() }
        engines.removeAll()
        rateListeners.removeAll()
        reconcile()
    }

    private func persistAndReconcile() {
        store.save(table: table)
        reconcile()
    }

    // MARK: - Warnings for the UI

    var bluetoothLegCount: Int {
        Set(table.routes.filter(\.isEnabled)
            .flatMap(\.legs)
            .map(\.deviceUID))
            .filter { deviceMonitor.device(uid: $0)?.isBluetooth == true }
            .count
    }

    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    // MARK: - Reconcile

    func reconcile() {
        var seen = Set<UUID>()

        for route in table.routes {
            seen.insert(route.id)
            guard route.isEnabled else {
                teardownEngine(for: route.id)
                statuses[route.id] = .disabled
                continue
            }
            switch route.kind {
            case .direct: reconcileDirect(route)
            case .tapped: reconcileTapped(route)
            }
        }

        // Engines for deleted routes.
        for id in Array(engines.keys) where !seen.contains(id) {
            teardownEngine(for: id)
        }
        statuses = statuses.filter { seen.contains($0.key) }

        // If no enabled Direct route remains, give the system default back.
        let directActive = table.routes.contains { $0.kind == .direct && $0.isEnabled }
        if !directActive, let saved = savedDefaultUID {
            if deviceMonitor.device(uid: saved) != nil {
                deviceMonitor.setDefaultOutput(uid: saved)
            }
            savedDefaultUID = nil
        }
    }

    private func reconcileDirect(_ route: RouteConfig) {
        teardownEngine(for: route.id)   // direct routes have no engine
        guard let leg = route.primaryLeg, deviceMonitor.device(uid: leg.deviceUID) != nil else {
            statuses[route.id] = .deviceMissing
            return
        }
        if deviceMonitor.defaultOutputUID != leg.deviceUID {
            if savedDefaultUID == nil {
                savedDefaultUID = deviceMonitor.defaultOutputUID
            }
            deviceMonitor.setDefaultOutput(uid: leg.deviceUID)
        }
        statuses[route.id] = .direct
    }

    private func reconcileTapped(_ route: RouteConfig) {
        guard let leg = route.primaryLeg else { return }
        guard deviceMonitor.device(uid: leg.deviceUID) != nil else {
            teardownEngine(for: route.id)
            statuses[route.id] = .deviceMissing
            return
        }
        let objectIDs = processMonitor.objectIDs(forBundleIDs: route.appBundleIDs).sorted()
        guard !objectIDs.isEmpty else {
            teardownEngine(for: route.id)
            statuses[route.id] = .waitingForApp
            return
        }

        // Engine exists and still matches reality -> leave it alone.
        if let engine = engines[route.id] {
            let currentRate = deviceMonitor.device(uid: leg.deviceUID)?.sampleRate ?? engine.sampleRate
            if engine.identity.processObjectIDs == objectIDs,
               engine.identity.destinationUID == leg.deviceUID,
               abs(engine.identity.sampleRate - currentRate) < 1 || currentRate == 0 {
                return
            }
            teardownEngine(for: route.id)
        }

        buildEngine(for: route, objectIDs: objectIDs, deviceUID: leg.deviceUID)
    }

    private func buildEngine(for route: RouteConfig, objectIDs: [AudioObjectID], deviceUID: String) {
        guard !buildsInFlight.contains(route.id) else { return }
        buildsInFlight.insert(route.id)
        statuses[route.id] = .rebuilding

        let volume = route.volume, delayMs = route.delayMs, muted = route.isMuted
        let routeID = route.id

        // Engine creation + start happens off the main thread: AudioDeviceStart
        // blocks until the TCC permission is resolved the first time it fires.
        buildQueue.async { [weak self] in
            do {
                let engine = try RouteEngine(processObjectIDs: objectIDs,
                                             destinationUID: deviceUID,
                                             volume: volume, delayMs: delayMs, muted: muted)
                try engine.start()
                Task { @MainActor in
                    guard let self else { engine.invalidate(); return }
                    // The table may have changed while we were building.
                    guard let current = self.table.routes.first(where: { $0.id == routeID }),
                          current.isEnabled, current.kind == .tapped,
                          current.primaryLeg?.deviceUID == deviceUID else {
                        engine.invalidate()
                        self.buildsInFlight.remove(routeID)
                        return
                    }
                    self.engines[routeID] = engine
                    self.statuses[routeID] = .waitingForAudio
                    self.buildsInFlight.remove(routeID)
                    self.lastRebuildAt[routeID] = CFAbsoluteTimeGetCurrent()
                    self.installRateListener(routeID: routeID, deviceUID: deviceUID)
                }
            } catch {
                Task { @MainActor in
                    self?.statuses[routeID] = .failed("\(error)")
                    self?.buildsInFlight.remove(routeID)
                }
            }
        }
    }

    private func installRateListener(routeID: UUID, deviceUID: String) {
        guard let device = deviceMonitor.device(uid: deviceUID) else { return }
        rateListeners[routeID] = CAListener(objectID: device.id,
                                            selector: kAudioDevicePropertyNominalSampleRate) { [weak self] in
            self?.deviceMonitor.refresh()
            self?.reconcile()
        }
    }

    private func teardownEngine(for id: UUID) {
        engines[id]?.invalidate()
        engines[id] = nil
        rateListeners[id] = nil
        zeroSince[id] = nil
    }

    // MARK: - Watchdog

    private func watchdogTick() {
        let now = CFAbsoluteTimeGetCurrent()

        for (id, engine) in engines {
            guard let route = table.routes.first(where: { $0.id == id }) else { continue }
            let t = engine.readTelemetry()

            // Meter (simple decay smoothing for the UI).
            let level = max(t.peak, (levels[id] ?? 0) * 0.7)
            levels[id] = level

            let appIsPlaying = processMonitor.apps
                .filter { route.appBundleIDs.contains($0.bundleID) }
                .contains { $0.isPlayingOutput }

            // No IO callbacks at all for 3+ seconds means the aggregate died.
            if t.lastIOAt > 0, now - t.lastIOAt > 3 {
                rebuild(id)
                continue
            }

            if appIsPlaying && !route.isMuted && t.peak <= 1e-6 {
                let since = zeroSince[id] ?? now
                zeroSince[id] = since
                let zeroFor = now - since
                if zeroFor > 5, (lastRebuildAt[id].map { now - $0 > 30 } ?? true) {
                    // One rebuild attempt — this recovers the known tap-decay bug.
                    rebuild(id)
                } else if zeroFor > 12 {
                    // Rebuilt and still silent while playing: almost certainly
                    // protected audio (or a permission denial).
                    statuses[id] = .protectedAudio
                }
            } else {
                zeroSince[id] = nil
                if t.peak > 1e-6 {
                    statuses[id] = .active
                } else if statuses[id] == .active {
                    statuses[id] = .waitingForAudio
                }
            }
        }
    }

    private func rebuild(_ id: UUID) {
        teardownEngine(for: id)
        lastRebuildAt[id] = CFAbsoluteTimeGetCurrent()
        reconcile()
    }

    // MARK: - Shutdown

    /// Tear down every engine (taps auto-unmute their apps) and hand the
    /// system default output back. Called from applicationWillTerminate.
    func shutdown() {
        for (_, engine) in engines { engine.invalidate() }
        engines.removeAll()
        if let saved = savedDefaultUID, deviceMonitor.device(uid: saved) != nil {
            deviceMonitor.setDefaultOutput(uid: saved)
        }
        savedDefaultUID = nil
    }
}
