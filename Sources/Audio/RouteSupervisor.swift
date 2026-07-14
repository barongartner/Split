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
    /// Routes that have produced at least one non-zero sample since they were
    /// created or edited. DRM'd sources never produce a single one, which is
    /// the only reliable way to tell "protected" from "paused": a paused tab
    /// keeps the app's audio unit running with genuine silence.
    @ObservationIgnored private var everHadAudio: Set<UUID> = []
    @ObservationIgnored private var silentRebuilds: [UUID: Int] = [:]
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
            // A Direct route isn't bound to an app anymore — it's the bucket
            // everything unrouted (including the app that brought us here)
            // falls into. Rename accordingly or the card reads like a lie.
            table.routes[idx2].kind = .direct
            table.routes[idx2].legs = leg
            table.routes[idx2].appBundleIDs = []
            table.routes[idx2].appDisplayName = "Everything else"
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

    // MARK: - Sync wizard (beat-match calibration)

    private(set) var isCalibrating = false
    @ObservationIgnored private var phantomProbe: OutputProbe?
    @ObservationIgnored private var delaysBeforeCalibration: [UUID: Double] = [:]

    /// Route IDs the wizard can beat-match right now (enabled, tapped, engine live).
    var tunableRouteIDs: [UUID] {
        table.routes.filter { $0.isEnabled && $0.kind == .tapped && engines[$0.id] != nil }.map(\.id)
    }

    var directRoute: RouteConfig? {
        table.routes.first { $0.kind == .direct && $0.isEnabled }
    }

    func beginCalibration() {
        guard !isCalibrating else { return }
        isCalibrating = true
        delaysBeforeCalibration = Dictionary(uniqueKeysWithValues: table.routes.map { ($0.id, $0.delayMs) })
        for (_, engine) in engines { engine.setProgramMuted(true) }
    }

    /// `revert: true` (cancel) puts every live engine's delay back to the
    /// table's values; `false` (applied) leaves the freshly applied ones.
    func endCalibration(revert: Bool) {
        stopAllInjection()
        phantomProbe?.invalidate()
        phantomProbe = nil
        for (id, engine) in engines {
            engine.setProgramMuted(false)
            if revert, let route = table.routes.first(where: { $0.id == id }) {
                let delay = delaysBeforeCalibration[id] ?? route.delayMs
                engine.update(volume: route.volume, delayMs: delay, muted: route.isMuted)
            }
        }
        delaysBeforeCalibration.removeAll()
        isCalibrating = false
    }

    func startTunerBeep(routeID: UUID, grid: BeatGrid) {
        stopAllInjection()
        guard let engine = engines[routeID] else { return }
        engine.setInjection(InjectionCommand(mode: .tunerBeep,
                                             t0Host: grid.t0Host,
                                             periodFrames: grid.periodFrames(at: engine.sampleRate)))
    }

    /// The tuner turns the route's live delay; the table is untouched until Apply.
    func setTunerDelay(routeID: UUID, ms: Double) {
        guard let route = table.routes.first(where: { $0.id == routeID }),
              let engine = engines[routeID] else { return }
        engine.update(volume: route.volume, delayMs: ms, muted: route.isMuted)
    }

    /// Beep on the Direct route's device via a throwaway output probe.
    @discardableResult
    func startPhantomBeep(grid: BeatGrid) -> Bool {
        stopAllInjection()
        guard let leg = directRoute?.primaryLeg else { return false }
        if phantomProbe == nil || phantomProbe?.deviceID != deviceMonitor.device(uid: leg.deviceUID)?.id {
            phantomProbe?.invalidate()
            phantomProbe = OutputProbe(deviceUID: leg.deviceUID)
            do { try phantomProbe?.start() } catch { phantomProbe = nil }
        }
        guard let probe = phantomProbe else { return false }
        probe.setInjection(InjectionCommand(mode: .tunerBeep,
                                            t0Host: grid.t0Host,
                                            periodFrames: grid.periodFrames(at: probe.sampleRate)))
        return true
    }

    func setPhantomDelay(ms: Double) {
        phantomProbe?.setDelay(ms: ms)
    }

    func startGroupClick(grid: BeatGrid) {
        for (_, engine) in engines {
            engine.setInjection(InjectionCommand(mode: .groupClick,
                                                 t0Host: grid.t0Host,
                                                 periodFrames: grid.periodFrames(at: engine.sampleRate)))
        }
        if let leg = directRoute?.primaryLeg {
            if phantomProbe == nil {
                phantomProbe = OutputProbe(deviceUID: leg.deviceUID)
                do { try phantomProbe?.start() } catch { phantomProbe = nil }
            }
            phantomProbe?.setDelay(ms: 0)
            if let probe = phantomProbe {
                probe.setInjection(InjectionCommand(mode: .groupClick,
                                                    t0Host: grid.t0Host,
                                                    periodFrames: grid.periodFrames(at: probe.sampleRate)))
            }
        }
    }

    func stopAllInjection() {
        for (_, engine) in engines { engine.setInjection(InjectionCommand()) }
        phantomProbe?.setInjection(InjectionCommand())
    }

    /// Three seconds of clicks on one route — the Diagnostics "can you hear
    /// this route at all" button.
    func diagnosticsBeep(routeID: UUID) {
        guard let engine = engines[routeID] else { return }
        let grid = BeatGrid.startingSoon(periodMs: 500)
        engine.setInjection(InjectionCommand(mode: .groupClick,
                                             t0Host: grid.t0Host,
                                             periodFrames: grid.periodFrames(at: engine.sampleRate)))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.engines[routeID]?.setInjection(InjectionCommand())
        }
    }

    /// The tuned value of each route reveals its latency (plus a constant that
    /// cancels). Final playback delay aligns everyone to the slowest:
    /// final_i = max(tuned) − tuned_i. The Direct route can't be delayed; if
    /// it isn't the slowest, `directLeadMs` says how far ahead it runs.
    private(set) var directLeadMs: Double?

    func applyTunedDelays(_ tuned: [UUID: Double], phantomTuned: Double?) {
        var all = Array(tuned.values)
        if let phantomTuned { all.append(phantomTuned) }
        guard let maxTuned = all.max() else { return }

        for (id, v) in tuned {
            guard let idx = table.routes.firstIndex(where: { $0.id == id }) else { continue }
            let final = min(max(maxTuned - v, 0), 1000)
            table.routes[idx].delayMs = final
            table.routes[idx].impliedLatencyMs = v
            table.routes[idx].tunedAt = Date()
            engines[id]?.update(volume: table.routes[idx].volume,
                                delayMs: final,
                                muted: table.routes[idx].isMuted)
        }
        directLeadMs = phantomTuned.map { maxTuned - $0 }
        store.save(table: table)
    }

    var masterNudgeFloorMs: Double {
        -(table.routes.filter { $0.isEnabled && $0.kind == .tapped }.map(\.delayMs).min() ?? 0)
    }

    /// Shifts the whole group against the picture; relative sync is preserved.
    func nudgeAllTappedDelays(by deltaMs: Double) {
        for idx in table.routes.indices where table.routes[idx].kind == .tapped && table.routes[idx].isEnabled {
            let new = min(max(table.routes[idx].delayMs + deltaMs, 0), 1000)
            table.routes[idx].delayMs = new
            engines[table.routes[idx].id]?.update(volume: table.routes[idx].volume,
                                                  delayMs: new,
                                                  muted: table.routes[idx].isMuted)
        }
        store.save(table: table)
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
        everHadAudio = everHadAudio.intersection(seen)
        silentRebuilds = silentRebuilds.filter { seen.contains($0.key) }

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

            // During the sync wizard, program audio is muted engine-side, so
            // "playing but silent" is expected — a rebuild here would tear
            // down the very engine someone is beat-matching.
            if isCalibrating {
                zeroSince[id] = nil
                continue
            }

            if appIsPlaying && !route.isMuted && t.peak <= 1e-6 {
                let since = zeroSince[id] ?? now
                zeroSince[id] = since
                let zeroFor = now - since
                // Silent rebuilds back off exponentially (30 s, 60 s, …) so a
                // paused-but-open stream doesn't churn taps forever, while the
                // first rebuild still lands fast enough to fix the tap-decay
                // bug and the built-before-permission case.
                let attempts = silentRebuilds[id] ?? 0
                let cooldown = 30.0 * Double(1 << min(attempts, 4))
                if zeroFor > 5, (lastRebuildAt[id].map { now - $0 > cooldown } ?? true) {
                    silentRebuilds[id] = attempts + 1
                    rebuild(id)
                } else if zeroFor > 12, attempts >= 1, !everHadAudio.contains(id) {
                    // Rebuilt, still not one non-zero sample ever: protected
                    // audio (or a denied permission — indistinguishable).
                    statuses[id] = .protectedAudio
                }
            } else {
                zeroSince[id] = nil
                if t.peak > 1e-6 {
                    everHadAudio.insert(id)
                    silentRebuilds[id] = 0
                    statuses[id] = .active
                } else if statuses[id] == .active {
                    statuses[id] = .waitingForAudio
                }
            }
        }

        dumpStatus()
    }

    /// One line of machine-readable truth per second, next to routes.json.
    /// Everything in this API fails silently, so having the live state on disk
    /// turns "is it working?" from guesswork into `cat status.json`.
    private func dumpStatus() {
        var routesDump: [[String: Any]] = []
        for route in table.routes {
            routesDump.append([
                "app": route.appDisplayName,
                "kind": route.kind.rawValue,
                "device": route.primaryLeg?.deviceName ?? "",
                "status": String(describing: statuses[route.id] ?? RouteStatus.disabled),
                "level": Double(levels[route.id] ?? 0),
            ])
        }
        let dump: [String: Any] = ["at": Date().timeIntervalSince1970, "routes": routesDump]
        guard let data = try? JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted, .sortedKeys]) else { return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? data.write(to: base.appendingPathComponent("Split/status.json"), options: .atomic)
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
