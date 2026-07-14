// Watches output devices: what exists, what's Bluetooth, what the system
// default is. Also owns the default-device switch used by Direct routes.

import Foundation
import CoreAudio
import Observation

struct OutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    let sampleRate: Double

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

@MainActor
@Observable
final class AudioDeviceMonitor {

    private(set) var outputDevices: [OutputDevice] = []
    private(set) var defaultOutputUID: String?

    /// Fires after the device list or default output changed and state was
    /// re-read. The supervisor uses this to reconcile routes.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var listListener: CAListener?
    @ObservationIgnored private var defaultListener: CAListener?

    init() {
        refresh()
        listListener = CAListener(objectID: CA.systemObject,
                                  selector: kAudioHardwarePropertyDevices) { [weak self] in
            self?.refresh()
        }
        defaultListener = CAListener(objectID: CA.systemObject,
                                     selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.refresh()
        }
    }

    func refresh() {
        var devices: [OutputDevice] = []
        for id in CA.deviceList() {
            guard CA.outputStreamCount(id) > 0 else { continue }
            let transport = CA.transportType(id)
            // Aggregates are either our own private per-route devices (which
            // shouldn't be visible at all) or the user's multi-output setups,
            // which aren't valid route destinations for us either.
            guard transport != kAudioDeviceTransportTypeAggregate,
                  transport != kAudioDeviceTransportTypeVirtual else { continue }
            guard let uid = CA.deviceUID(id), let name = CA.deviceName(id) else { continue }
            devices.append(OutputDevice(id: id, uid: uid, name: name,
                                        transport: transport,
                                        sampleRate: CA.nominalSampleRate(id)))
        }
        devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let newDefault = CA.defaultOutputDevice().flatMap { CA.deviceUID($0) }
        let changed = devices != outputDevices || newDefault != defaultOutputUID
        outputDevices = devices
        defaultOutputUID = newDefault
        if changed { onChange?() }
    }

    func device(uid: String) -> OutputDevice? {
        outputDevices.first { $0.uid == uid }
    }

    @discardableResult
    func setDefaultOutput(uid: String) -> Bool {
        guard let device = device(uid: uid) else { return false }
        return CA.setDefaultOutputDevice(device.id) == noErr
    }
}
