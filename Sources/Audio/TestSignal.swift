// The sync beep and the machinery that schedules it on a shared time grid.
//
// Both the beat-match tuner and the group click test inject the same short
// "pip" into a route's output at host times derived from one grid all routes
// share. The only difference is the sign of the delay term:
//
//   tuner beep:  emit at  grid_tick − delay     (turning the slider slides
//                the beep earlier, so the listener aligns beep-in-ear with
//                the on-screen pulse; their final value reveals latency)
//   group click: emit at  grid_tick + delay     (what playback actually does,
//                so the room hears the applied alignment)
//
// BeepInjector runs entirely on the audio thread: preallocated signal, no
// allocation, no locks. The command struct crosses inside RouteEngine's
// existing Params/os_unfair_lock mechanism.

import Foundation

enum TestTone {
    /// 5 ms Hann-windowed 2 kHz pip — perceptually a click, but band-limited
    /// enough that Bluetooth codecs keep its onset intact.
    static func beep(sampleRate: Double) -> [Float32] {
        let n = max(Int(sampleRate * 0.005), 8)
        var out = [Float32](repeating: 0, count: n)
        for i in 0..<n {
            let w = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1))
            out[i] = Float32(sin(2 * .pi * 2000.0 * Double(i) / sampleRate) * w)
        }
        return out
    }
}

/// Crosses UI → audio thread as part of RouteEngine.Params (plain data only).
struct InjectionCommand: Equatable {
    enum Mode: UInt8 { case off = 0, tunerBeep = 1, groupClick = 2 }
    var mode: Mode = .off
    var amplitude: Float = 0.25
    var t0Host: UInt64 = 0          // grid anchor in mach ticks
    var periodFrames: Int32 = 0     // grid period in device frames
}

/// The shared beat grid: one mach-time anchor that beeps, clicks, and the
/// wizard's on-screen pulse all derive from.
struct BeatGrid {
    let t0Host: UInt64
    let periodMs: Double
    let date0: Date                 // same instant as t0Host, for TimelineView

    static func startingSoon(periodMs: Double = 1000) -> BeatGrid {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ticksPerSec = Double(tb.denom) / Double(tb.numer) * 1e9
        let lead = 0.5
        return BeatGrid(t0Host: mach_absolute_time() + UInt64(lead * ticksPerSec),
                        periodMs: periodMs,
                        date0: Date().addingTimeInterval(lead))
    }

    func periodFrames(at sampleRate: Double) -> Int32 {
        Int32((periodMs / 1000.0 * sampleRate).rounded())
    }
}

/// Audio-thread-owned scheduler + mixer. All methods run on the audio thread.
struct BeepInjector {
    private let beep: UnsafeMutablePointer<Float32>
    private let beepLen: Int
    private let secPerTick: Double
    private let sampleRate: Double
    private var cursor = -1         // -1 idle, else next beep sample to write

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let b = TestTone.beep(sampleRate: sampleRate)
        let storage = UnsafeMutablePointer<Float32>.allocate(capacity: b.count)
        b.withUnsafeBufferPointer { storage.initialize(from: $0.baseAddress!, count: b.count) }
        beep = storage
        beepLen = b.count
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        secPerTick = Double(tb.numer) / Double(tb.denom) / 1e9
    }

    func destroy() {
        beep.deallocate()
    }

    /// Adds any due beep into `scratch` (interleaved) for the block whose
    /// first frame the HAL says plays at `blockHost`.
    mutating func mix(into scratch: UnsafeMutablePointer<Float32>, frames: Int,
                      channels: Int, blockHost: UInt64,
                      cmd: InjectionCommand, delayFrames: Int) {
        guard cmd.mode != .off, cmd.periodFrames > 0, cmd.t0Host != 0, blockHost != 0 else {
            cursor = -1
            return
        }

        // Finish a beep that spilled over from the previous block.
        if cursor >= 0 {
            emit(into: scratch, frames: frames, channels: channels, from: 0, amp: cmd.amplitude)
        }

        // Where this block sits on the grid, in frames (signed — the block can
        // precede the anchor).
        let dsec = blockHost >= cmd.t0Host
            ? Double(blockHost - cmd.t0Host) * secPerTick
            : -Double(cmd.t0Host - blockHost) * secPerTick
        let e0 = Int64((dsec * sampleRate).rounded())

        let shift = cmd.mode == .tunerBeep ? -Int64(delayFrames) : Int64(delayFrames)
        let p = Int64(cmd.periodFrames)
        var m = (e0 - shift) % p
        if m < 0 { m += p }
        let onset = m == 0 ? 0 : Int(p - m)

        if onset < frames, cursor < 0 {
            cursor = 0
            emit(into: scratch, frames: frames, channels: channels, from: onset, amp: cmd.amplitude)
        }
    }

    private mutating func emit(into scratch: UnsafeMutablePointer<Float32>, frames: Int,
                               channels: Int, from start: Int, amp: Float) {
        var f = start
        while f < frames && cursor < beepLen {
            let s = beep[cursor] * amp
            for c in 0..<channels {
                scratch[f * channels + c] += s
            }
            cursor += 1
            f += 1
        }
        if cursor >= beepLen { cursor = -1 }
    }
}
