# The audio pipeline

What actually happens to a sample between Spotify and someone's headphones.

## Capture: tap + aggregate

Creating a tapped route:

1. Resolve the app's PIDs to HAL process objects
   (`kAudioHardwarePropertyTranslatePIDToProcessObject`).
2. `CATapDescription(stereoMixdownOfProcesses:)` over those objects, with
   `muteBehavior = .mutedWhenTapped` and `isPrivate = true`, then
   `AudioHardwareCreateProcessTap`.
3. Create a **private aggregate device** whose main sub-device is the
   *destination* (the headphones), with the tap attached via
   `kAudioAggregateDeviceTapListKey` and drift compensation on
   (`kAudioSubTapDriftCompensationKey`).
4. One `AudioDeviceCreateIOProcIDWithBlock` on that aggregate, then
   `AudioDeviceStart`.

The aggregate design is the part worth understanding. The destination device
is the aggregate's clock; the tap is drift-compensated *to that clock* by the
HAL. That means each route lives in exactly one clock domain and Split
contains zero resampling code. Ten routes to ten devices are ten independent
aggregates, each ticking on its own device's clock — nothing needs to agree
with anything else.

Two mistakes produce a "working" pipeline that delivers pure silence, all
calls returning noErr. Learn them here rather than rediscovering them:

- The aggregate **must** have the real output device as its main sub-device.
  A tap-only aggregate is valid and useless.
- Don't touch `CATapDescription.isExclusive` after using a convenience
  initializer — the flag silently inverts include/exclude semantics.

Also: never wire a tap aggregate into `AVAudioEngine`. Device assignment
no-ops silently. Raw IOProc only.

## Inside the IOProc

The callback gets the tap's frames as input and the destination device's
buffers as output, in the same call. Per block:

```
write block into ring buffer
read block back out, delayed        (the delay slider)
gain, ramped ~30 ms per-sample      (no zipper noise)
peak + RMS                          (meters, watchdog food)
copy into the output buffers        (channel-mapped if counts differ)
```

Real-time rules observed: no allocation, no locks that can block, no
Objective-C. Everything the callback needs is preallocated at engine build
time, including the crossfade scratch.

**Parameter passing.** The UI writes volume/delay/mute into a tiny struct
under an `os_unfair_lock`; the audio thread *try*-locks each block and keeps
the previous values if it loses the race. Telemetry (peak, RMS, last-IO
timestamp) crosses back the same way. Nothing ever waits on anything.

## The delay line

A preallocated ring buffer, 2 s of history plus a block of headroom, at the
tap's sample rate and channel count. Write and read both happen inside the
one IOProc, so there's no concurrent access at all — the ring is just memory
and arithmetic.

Delay = read position trailing the write position. Delay 0 reads back the
exact block just written (pure passthrough). When the target delay changes,
jumping the read position would click, so the block that lands the change
crossfades between the old and new read positions over ~10 ms.

Why delay at all: Bluetooth headphones are 150–300 ms late and you can't make
them earlier. Syncing multiple listeners means delaying the *fast* outputs
(wired, speakers) to match the slowest. The Direct route gets no delay —
it's the hardware path, i.e. the reference everyone else tunes against.

The slider's starting value comes from `kAudioDevicePropertyLatency` +
`kAudioDevicePropertySafetyOffset`, which for Bluetooth devices is a static
number that tracks nothing — AirPods really measure ~220 ms cold and ~155 ms
half an hour later. Hence a live slider and not a calibration wizard.

## The sync beep

The beat-match tuner and the group click test inject a 5 ms Hann-windowed
2 kHz pip into the IOProc's scratch buffer *after* the delay line and gain
stage, just before the output copy. Consequences of that placement, all
deliberate:

- The pip's level is constant regardless of route volume or mute, and program
  audio can be silenced during tuning without silencing the beat.
- It stays out of the meters and the watchdog (those measure program audio).
- It works while the routed app is paused or silent — IOProcs keep firing on
  a tap aggregate either way.

Every route derives its beeps from one shared grid: a mach-time anchor plus a
1 s period. The scheduler compares each block's `inOutputTime.mHostTime` (the
HAL's projection of when that buffer hits the device — NOT the wall clock,
which leads the device by a different amount per device) against the grid and
drops the pip at the exact frame offset. Two modes, one sign apart:

```
tuner beep:  onset at grid_tick − delay    (the listener slides their beep
                                            onto the on-screen pulse; the
                                            value they land on reveals their
                                            headphones' latency)
group click: onset at grid_tick + delay    (what playback actually does, so
                                            the room hears the applied result)
```

After everyone tunes, final delays are `max(tuned) − tuned_i` — align to the
slowest. Verified end-to-end on hardware: onsets land on the grid with 1000.0
ms spacing, and a 200 ms delay moves them by exactly ∓200.0 ms per mode.

## Teardown

Exact order, always: `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` →
`AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`.
Destroying the tap is what un-mutes the app in the system mix. macOS also
does that automatically if Split dies, so a crash can't leave Spotify
permanently silent.

## Cost

One tap, one aggregate, one IOProc, one ring buffer per route. The IOProc
does a memcpy, a multiply, and an add per sample. Three simultaneous routes
on a 2019 Intel MacBook are low-single-digit percent CPU. The HAL's drift
compensation (a resampler) is the biggest line item and it's Apple's code,
not ours.
