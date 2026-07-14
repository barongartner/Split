// One tap + one private aggregate device = the capture side of a route.
//
// The aggregate is clocked by the destination device with the tap drift-
// compensated to it, so each route lives in exactly one clock domain and we
// never resample anything ourselves. Setup and teardown order follow AudioCap
// (BSD-2-Clause, https://github.com/insidegui/AudioCap).
//
// Two things in here are load-bearing and non-obvious:
//  - The destination device MUST be the aggregate's main sub-device. A tap-only
//    aggregate "works" (all calls return noErr) and delivers pure silence.
//  - Don't touch CATapDescription.isExclusive after using a convenience
//    initializer — the flag inverts include/exclude semantics and the failure
//    mode is, again, silence with noErr.

import Foundation
import CoreAudio
import AudioToolbox

final class TapAggregate {

    let tapID: AudioObjectID
    let aggregateID: AudioObjectID
    let format: AudioStreamBasicDescription
    let destinationUID: String
    let processObjectIDs: [AudioObjectID]

    private(set) var invalidated = false

    init(processObjectIDs: [AudioObjectID], destinationUID: String) throws {
        precondition(!processObjectIDs.isEmpty, "a tapped route needs at least one process")
        self.processObjectIDs = processObjectIDs
        self.destinationUID = destinationUID

        let desc = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        desc.uuid = UUID()
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr, tapID != kAudioObjectUnknown else {
            throw CoreAudioError(message: "process tap creation failed", status: err)
        }
        self.tapID = tapID

        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Split-\(desc.uuid.uuidString.prefix(8))",
            kAudioAggregateDeviceUIDKey: "com.barongartner.Split.agg.\(desc.uuid.uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: destinationUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: destinationUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]

        var aggID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &aggID)
        guard err == noErr, aggID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            throw CoreAudioError(message: "aggregate device creation failed", status: err)
        }
        self.aggregateID = aggID

        guard let format = CA.tapFormat(tapID) else {
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(tapID)
            throw CoreAudioError(message: "could not read tap format", status: -1)
        }
        self.format = format
    }

    /// Teardown must happen in exactly this order (stop and IOProc destruction
    /// are the caller's job, since it owns the IOProc).
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
    }

    deinit { invalidate() }
}
