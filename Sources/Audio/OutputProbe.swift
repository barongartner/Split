// A bare output IOProc on a physical device that can join the beat grid.
//
// The Direct route deliberately has no engine (nothing is captured), but its
// listener still needs a voice in the sync wizard: a beep for the phantom
// beat-match and a click in the group test. This is that voice — created for
// the wizard's lifetime, then destroyed. Output-only, so it triggers no
// permission prompts.

import Foundation
import CoreAudio
import os

final class OutputProbe {

    let deviceID: AudioDeviceID
    let sampleRate: Double

    private var ioProcID: AudioDeviceIOProcID?
    private var started = false

    private var lock = os_unfair_lock()
    private var cmd = InjectionCommand()
    private var delayFrames: Int32 = 0

    private var rtCmd = InjectionCommand()
    private var rtDelayFrames: Int32 = 0
    private var rtInjector: BeepInjector

    init?(deviceUID: String) {
        guard let id = CA.deviceList().first(where: { CA.deviceUID($0) == deviceUID }) else { return nil }
        deviceID = id
        sampleRate = max(CA.nominalSampleRate(id), 8000)
        rtInjector = BeepInjector(sampleRate: sampleRate)
    }

    deinit {
        invalidate()
        rtInjector.destroy()
    }

    func start() throws {
        guard !started else { return }
        var err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, nil) { [weak self] _, _, _, outOutputData, inOutputTime in
            guard let self else { return }
            self.render(outOutputData: outOutputData, outputHostTime: inOutputTime.pointee.mHostTime)
        }
        guard err == noErr else { throw CoreAudioError(message: "probe IOProc creation failed", status: err) }
        err = AudioDeviceStart(deviceID, ioProcID)
        guard err == noErr else {
            if let ioProcID { AudioDeviceDestroyIOProcID(deviceID, ioProcID) }
            ioProcID = nil
            throw CoreAudioError(message: "probe start failed", status: err)
        }
        started = true
    }

    func invalidate() {
        if started, let ioProcID {
            AudioDeviceStop(deviceID, ioProcID)
            AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        }
        ioProcID = nil
        started = false
    }

    func setInjection(_ newCmd: InjectionCommand) {
        os_unfair_lock_lock(&lock)
        cmd = newCmd
        os_unfair_lock_unlock(&lock)
    }

    /// The phantom tuner value — same units and sign convention as a real
    /// route's delay, it just isn't applied to anything.
    func setDelay(ms: Double) {
        os_unfair_lock_lock(&lock)
        delayFrames = Int32(ms * sampleRate / 1000.0)
        os_unfair_lock_unlock(&lock)
    }

    private func render(outOutputData: UnsafeMutablePointer<AudioBufferList>, outputHostTime: UInt64) {
        if os_unfair_lock_trylock(&lock) {
            rtCmd = cmd
            rtDelayFrames = delayFrames
            os_unfair_lock_unlock(&lock)
        }
        guard rtCmd.mode != .off else { return }

        // Our client buffers arrive zeroed; mix the beep straight into the
        // first valid buffer (typical devices expose exactly one).
        let outABL = UnsafeMutableAudioBufferListPointer(outOutputData)
        guard let buf = outABL.first(where: { $0.mData != nil }), let data = buf.mData else { return }
        let channels = max(Int(buf.mNumberChannels), 1)
        let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float32>.size * channels)
        guard frames > 0 else { return }

        rtInjector.mix(into: data.bindMemory(to: Float32.self, capacity: frames * channels),
                       frames: frames, channels: channels,
                       blockHost: outputHostTime,
                       cmd: rtCmd, delayFrames: Int(rtDelayFrames))
    }
}
