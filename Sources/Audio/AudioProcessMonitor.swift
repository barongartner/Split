// Watches which apps are (or could be) playing audio.
//
// The HAL hands out one "process object" per audio-touching process, but what
// the user thinks of as an app is often several processes: Chrome plays all of
// its audio from a sandboxed helper, Safari from com.apple.WebKit.GPU, Electron
// apps from a renderer. We group every helper under the app the user can see,
// because that is the granularity taps give us anyway — you route Chrome, not
// a Chrome tab.

import Foundation
import AppKit
import CoreAudio
import Observation

struct AudioApp: Identifiable, Equatable {
    let bundleID: String
    let name: String
    var objectIDs: [AudioObjectID]
    var pids: [pid_t]
    var isPlayingOutput: Bool

    var id: String { bundleID }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.objectIDs == rhs.objectIDs && lhs.isPlayingOutput == rhs.isPlayingOutput
    }
}

@MainActor
@Observable
final class AudioProcessMonitor {

    private(set) var apps: [AudioApp] = []

    @ObservationIgnored private var listListener: CAListener?
    @ObservationIgnored private var pollTimer: Timer?

    init() {
        refresh()
        listListener = CAListener(objectID: CA.systemObject,
                                  selector: kAudioHardwarePropertyProcessObjectList) { [weak self] in
            self?.refresh()
        }
        // The per-process IsRunningOutput listeners are documented-by-forum to
        // never fire, so a light poll keeps the "audible now" state honest.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        var grouped: [String: AudioApp] = [:]

        for objectID in CA.processObjectList() {
            guard let pid = CA.processPID(objectID) else { continue }
            guard let owner = Self.owningApp(forPID: pid, helperBundleID: CA.processBundleID(objectID)) else { continue }

            let playing = CA.processIsRunningOutput(objectID)
            if var existing = grouped[owner.bundleID] {
                existing.objectIDs.append(objectID)
                existing.pids.append(pid)
                existing.isPlayingOutput = existing.isPlayingOutput || playing
                grouped[owner.bundleID] = existing
            } else {
                grouped[owner.bundleID] = AudioApp(bundleID: owner.bundleID,
                                                   name: owner.name,
                                                   objectIDs: [objectID],
                                                   pids: [pid],
                                                   isPlayingOutput: playing)
            }
        }

        let sorted = grouped.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if sorted != apps { apps = sorted }
    }

    func app(bundleID: String) -> AudioApp? {
        apps.first { $0.bundleID == bundleID }
    }

    /// All current audio process objects belonging to the given app bundle IDs.
    func objectIDs(forBundleIDs bundleIDs: [String]) -> [AudioObjectID] {
        apps.filter { bundleIDs.contains($0.bundleID) }.flatMap(\.objectIDs)
    }

    static func icon(forBundleID bundleID: String) -> NSImage? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
    }

    // MARK: - Helper-process grouping

    private struct Owner { let bundleID: String; let name: String }

    private static func owningApp(forPID pid: pid_t, helperBundleID: String?) -> Owner? {
        // Fast path: the helper's bundle ID is the app's bundle ID plus a
        // suffix (com.google.Chrome.helper, com.apple.WebKit.GPU under Safari
        // is handled by the parent walk below).
        if let helperBundleID {
            for suffix in [".helper", ".Helper", ".helper.plugin", ".helper.renderer", ".helper.gpu"] {
                if helperBundleID.hasSuffix(suffix) {
                    let base = String(helperBundleID.dropLast(suffix.count))
                    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: base).first,
                       let bid = app.bundleIdentifier {
                        return Owner(bundleID: bid, name: app.localizedName ?? bid)
                    }
                }
            }
        }

        // Walk up the parent-process chain until we hit a process that is a
        // real, user-visible application.
        var current = pid
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: current),
               let bid = app.bundleIdentifier,
               app.activationPolicy != .prohibited {
                return Owner(bundleID: bid, name: app.localizedName ?? bid)
            }
            var info = proc_bsdinfo()
            let size = proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { break }
            let ppid = pid_t(info.pbi_ppid)
            guard ppid > 1, ppid != current else { break }
            current = ppid
        }

        // Last resort: the process itself, even if it's a faceless helper.
        if let app = NSRunningApplication(processIdentifier: pid), let bid = app.bundleIdentifier {
            return Owner(bundleID: bid, name: app.localizedName ?? bid)
        }
        if let helperBundleID {
            return Owner(bundleID: helperBundleID, name: helperBundleID)
        }
        return nil
    }
}
