// One live tapped route: tap + aggregate + a single real-time IOProc that does
// delay -> gain -> meters -> output.
//
// Real-time rules for the IOProc: no allocation, no Objective-C, no unbounded
// locks. UI-facing parameters cross into the audio thread through a tiny
// os_unfair_lock-protected struct that the audio thread only ever *try*-locks;
// if the lock is contended it just reuses the previous block's values. Same
// trick in reverse for the meter/watchdog telemetry.

import Foundation
import CoreAudio
import AudioToolbox
import os

struct RouteTelemetry {
    var peak: Float = 0
    var rms: Float = 0
    var lastIOAt: TimeInterval = 0
    var lastNonzeroAt: TimeInterval = 0
    var totalFrames: UInt64 = 0
}

final class RouteEngine {

    struct Identity: Equatable {
        let processObjectIDs: [AudioObjectID]
        let destinationUID: String
        let sampleRate: Double
    }

    let identity: Identity
    private let tap: TapAggregate
    private let delayLine: DelayLine
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var started = false

    // MARK: - Cross-thread parameter passing

    private struct Params {
        var gain: Float = 1
        var delayFrames: Int32 = 0
        var muted = false
    }

    private var paramsLock = os_unfair_lock()
    private var params = Params()

    private var telemetryLock = os_unfair_lock()
    private var telemetry = RouteTelemetry()

    // Audio-thread-owned state (never touched from other threads).
    private var rtParams = Params()
    private var rtGain: Float = 0        // smoothed gain, ramps toward rtParams.gain
    private let rtScratch: UnsafeMutablePointer<Float32>
    private let rtScratchFrames = 8192
    private let fadeFrames: Int

    init(processObjectIDs: [AudioObjectID], destinationUID: String,
         volume: Double, delayMs: Double, muted: Bool) throws {
        tap = try TapAggregate(processObjectIDs: processObjectIDs, destinationUID: destinationUID)

        let rate = tap.format.mSampleRate
        let channels = Int(tap.format.mChannelsPerFrame)
        identity = Identity(processObjectIDs: processObjectIDs,
                            destinationUID: destinationUID,
                            sampleRate: rate)

        // 2 seconds of history bounds the delay slider; +1 block of headroom.
        delayLine = DelayLine(capacityFrames: Int(rate * 2) + 8192, channels: max(channels, 1))
        fadeFrames = Int(rate * 0.010)

        rtScratch = .allocate(capacity: rtScratchFrames * max(channels, 1))
        rtScratch.initialize(repeating: 0, count: rtScratchFrames * max(channels, 1))

        params = Params(gain: Float(volume), delayFrames: Int32(delayMs * rate / 1000.0), muted: muted)
        rtParams = params
    }

    deinit {
        invalidate()
        rtScratch.deallocate()
    }

    var sampleRate: Double { identity.sampleRate }
    var channels: Int { Int(tap.format.mChannelsPerFrame) }

    // MARK: - Lifecycle

    /// Blocks until the system audio recording permission is resolved the very
    /// first time it ever runs for this app — never call on the main thread.
    func start() throws {
        guard !started else { return }

        let channels = max(self.channels, 1)
        let delayLine = self.delayLine
        let scratch = self.rtScratch
        let scratchFrames = self.rtScratchFrames
        let fade = self.fadeFrames
        // Per-sample one-pole coefficient for a ~30 ms gain ramp (no zipper noise).
        let rampCoef: Float = 1.0 - exp(-1.0 / (0.030 * Float(identity.sampleRate)))

        var err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, tap.aggregateID, nil) { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else { return }
            self.render(inInputData: inInputData, outOutputData: outOutputData,
                        channels: channels, delayLine: delayLine,
                        scratch: scratch, scratchFrames: scratchFrames,
                        fade: fade, rampCoef: rampCoef)
        }
        guard err == noErr else { throw CoreAudioError(message: "IOProc creation failed", status: err) }

        err = AudioDeviceStart(tap.aggregateID, ioProcID)
        guard err == noErr else {
            if let ioProcID { AudioDeviceDestroyIOProcID(tap.aggregateID, ioProcID) }
            ioProcID = nil
            throw CoreAudioError(message: "device start failed", status: err)
        }
        started = true
    }

    func invalidate() {
        if started, let ioProcID {
            AudioDeviceStop(tap.aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(tap.aggregateID, ioProcID)
        }
        ioProcID = nil
        started = false
        tap.invalidate()
    }

    // MARK: - Control (any thread)

    func update(volume: Double, delayMs: Double, muted: Bool) {
        os_unfair_lock_lock(&paramsLock)
        params.gain = Float(volume)
        params.delayFrames = Int32(delayMs * identity.sampleRate / 1000.0)
        params.muted = muted
        os_unfair_lock_unlock(&paramsLock)
    }

    func readTelemetry() -> RouteTelemetry {
        os_unfair_lock_lock(&telemetryLock)
        defer { os_unfair_lock_unlock(&telemetryLock) }
        return telemetry
    }

    // MARK: - Audio thread

    private func render(inInputData: UnsafePointer<AudioBufferList>,
                        outOutputData: UnsafeMutablePointer<AudioBufferList>,
                        channels: Int, delayLine: DelayLine,
                        scratch: UnsafeMutablePointer<Float32>, scratchFrames: Int,
                        fade: Int, rampCoef: Float) {
        // Pull fresh params if the lock is free; otherwise keep last block's.
        if os_unfair_lock_trylock(&paramsLock) {
            rtParams = params
            os_unfair_lock_unlock(&paramsLock)
        }

        let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        let outABL = UnsafeMutableAudioBufferListPointer(outOutputData)

        guard let inBuf = inABL.first(where: { $0.mData != nil }), let inData = inBuf.mData else { return }
        let inChannels = max(Int(inBuf.mNumberChannels), 1)
        let frames = Int(inBuf.mDataByteSize) / (MemoryLayout<Float32>.size * inChannels)
        guard frames > 0, frames <= scratchFrames else { return }

        let input = inData.bindMemory(to: Float32.self, capacity: frames * inChannels)

        // Delay.
        delayLine.write(input, frames: frames)
        delayLine.read(into: scratch, frames: frames, delayFrames: Int(rtParams.delayFrames), fadeFrames: fade)

        // Gain ramp + meters.
        let targetGain: Float = rtParams.muted ? 0 : rtParams.gain
        var peak: Float = 0
        var sumSquares: Float = 0
        var g = rtGain
        for f in 0..<frames {
            g += (targetGain - g) * rampCoef
            for c in 0..<inChannels {
                let i = f * inChannels + c
                let s = scratch[i] * g
                scratch[i] = s
                let a = abs(s)
                if a > peak { peak = a }
                sumSquares += s * s
            }
        }
        rtGain = g

        // Output: map our (usually stereo) frames onto each output stream.
        for outBuf in outABL {
            guard let outData = outBuf.mData else { continue }
            let outChannels = max(Int(outBuf.mNumberChannels), 1)
            let outFrames = Int(outBuf.mDataByteSize) / (MemoryLayout<Float32>.size * outChannels)
            let out = outData.bindMemory(to: Float32.self, capacity: outFrames * outChannels)
            let n = min(frames, outFrames)
            if outChannels == inChannels {
                memcpy(out, scratch, n * outChannels * MemoryLayout<Float32>.size)
            } else {
                for f in 0..<n {
                    for c in 0..<outChannels {
                        out[f * outChannels + c] = scratch[f * inChannels + min(c, inChannels - 1)]
                    }
                }
            }
        }

        // Telemetry (skip on contention — the next block will land it).
        if os_unfair_lock_trylock(&telemetryLock) {
            let now = CFAbsoluteTimeGetCurrent()
            telemetry.peak = peak
            telemetry.rms = (sumSquares / Float(frames * inChannels)).squareRoot()
            telemetry.lastIOAt = now
            telemetry.totalFrames += UInt64(frames)
            if peak > 1e-6 { telemetry.lastNonzeroAt = now }
            os_unfair_lock_unlock(&telemetryLock)
        }
    }
}
