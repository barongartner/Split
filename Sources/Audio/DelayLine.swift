// A fixed-size interleaved ring buffer that implements the per-route delay.
//
// This is the only "DSP" in Split. The IOProc writes each incoming block, then
// immediately reads the same number of frames back out at (write position -
// delay). Because write and read both happen inside the single IOProc callback
// there is no concurrency to manage here at all — the only cross-thread value
// is the target delay, which the engine passes in per block.
//
// When the delay target changes, the read jumps to a new position in the ring.
// A hard jump clicks, so the block that lands the change crossfades between
// the old and new read positions (~10 ms).

import Foundation

final class DelayLine {

    let capacityFrames: Int
    let channels: Int

    private let buffer: UnsafeMutablePointer<Float32>
    private let scratchBuffer: UnsafeMutablePointer<Float32>   // crossfade blend space
    private var writeIndex = 0          // in frames
    private var currentDelay = 0        // in frames
    private var primedFrames = 0        // how much history exists (caps usable delay)

    init(capacityFrames: Int, channels: Int) {
        self.capacityFrames = max(capacityFrames, 1)
        self.channels = max(channels, 1)
        let count = self.capacityFrames * self.channels
        buffer = .allocate(capacity: count)
        buffer.initialize(repeating: 0, count: count)
        scratchBuffer = .allocate(capacity: 4096 * self.channels)
        scratchBuffer.initialize(repeating: 0, count: 4096 * self.channels)
    }

    deinit {
        buffer.deallocate()
        scratchBuffer.deallocate()
    }

    func write(_ input: UnsafePointer<Float32>, frames: Int) {
        var remaining = frames
        var src = input
        while remaining > 0 {
            let chunk = min(remaining, capacityFrames - writeIndex)
            memcpy(buffer + writeIndex * channels, src, chunk * channels * MemoryLayout<Float32>.size)
            writeIndex = (writeIndex + chunk) % capacityFrames
            src += chunk * channels
            remaining -= chunk
        }
        primedFrames = min(primedFrames + frames, capacityFrames)
    }

    /// Reads `frames` frames delayed by `delayFrames` into `out`. Call after
    /// write() for the same block. Crossfades if the delay changed.
    func read(into out: UnsafeMutablePointer<Float32>, frames: Int, delayFrames: Int, fadeFrames: Int) {
        // Never ask for more history than has been written, or more than the
        // ring can hold alongside the current block.
        let maxDelay = max(0, min(primedFrames - frames, capacityFrames - frames - 1))
        let target = max(0, min(delayFrames, maxDelay))
        let old = min(currentDelay, maxDelay)

        if target == old {
            copyDelayed(into: out, frames: frames, delay: target)
        } else {
            // Crossfade old -> target across this block.
            let fade = max(1, min(fadeFrames, frames))
            copyDelayed(into: out, frames: frames, delay: target)
            // Blend the first `fade` frames with the old position's signal.
            withScratch(frames: fade) { scratch in
                copyDelayed(into: scratch, frames: fade, delay: old)
                for f in 0..<fade {
                    let t = Float32(f) / Float32(fade)
                    for c in 0..<channels {
                        let i = f * channels + c
                        out[i] = scratch[i] * (1 - t) + out[i] * t
                    }
                }
            }
            currentDelay = target
        }
        currentDelay = target
    }

    // MARK: - Internals

    private func copyDelayed(into out: UnsafeMutablePointer<Float32>, frames: Int, delay: Int) {
        // Start of the block we just wrote is (writeIndex - frames); delayed
        // read starts `delay` frames before that.
        var readIndex = writeIndex - frames - delay
        readIndex %= capacityFrames
        if readIndex < 0 { readIndex += capacityFrames }

        var remaining = frames
        var dst = out
        var idx = readIndex
        while remaining > 0 {
            let chunk = min(remaining, capacityFrames - idx)
            memcpy(dst, buffer + idx * channels, chunk * channels * MemoryLayout<Float32>.size)
            idx = (idx + chunk) % capacityFrames
            dst += chunk * channels
            remaining -= chunk
        }
    }

    private func withScratch(frames: Int, _ body: (UnsafeMutablePointer<Float32>) -> Void) {
        guard frames <= 4096 else { return }
        body(scratchBuffer)
    }
}
