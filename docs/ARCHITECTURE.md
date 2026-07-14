# Architecture

Split is small on purpose: a routing table (plain Codable structs), a
reconciler that turns the table into live audio engines, and SwiftUI on top.
No third-party dependencies.

```
RoutingTable (routes.json)          what the user wants
        │
        ▼
RouteSupervisor (reconciler)        makes reality match the table
        │
        ├── RouteEngine ×N          one per enabled tapped route
        │     └── TapAggregate      process tap + private aggregate device
        │     └── DelayLine         ring buffer, the only DSP
        │     └── IOProc            real-time callback: delay → gain → meters → out
        │
        └── default-output switch   the Direct route (no engine, no capture)

AudioProcessMonitor                 which apps have audio processes, grouped
AudioDeviceMonitor                  which output devices exist, hot-plug
```

## The two route kinds

**Tapped** is the interesting one. A Core Audio process tap captures one app's
audio and, because the tap is created with `muteBehavior = .mutedWhenTapped`,
the app goes silent in the normal system mix while Split re-renders it to the
chosen device. `.mutedWhenTapped` rather than `.muted` is a deliberate failure-
mode choice: if Split's render path ever stalls without crashing, the app's
audio leaks back to the system default — degraded but audible. `.muted` would
leave it silent everywhere, which is a worse way for movie night to fail.

**Direct** captures nothing. It sets the system default output device and
remembers what the default used to be (persisted in UserDefaults, so a crash
can't strand the system on someone's headphones). It exists because FairPlay-
protected audio — the Apple TV app, anything DRM'd in Safari — cannot be
captured by taps at all; the capture succeeds with all-zero samples. Not
capturing is the only approach that always works, so that's what Direct does.
There can only be one, because there's only one system default.

## The reconciler

`RouteSupervisor.reconcile()` is the single code path that makes reality match
the routing table. Everything funnels into it:

- table edits from the UI
- app launch/quit (the HAL process-object list changed)
- device plug/unplug (the device list changed)
- destination sample-rate changes (per-device listener)
- watchdog rebuilds

For each enabled tapped route it resolves the app's current audio process
objects and the destination device, compares them against the live engine's
identity, and tears down + rebuilds on any mismatch. One diff instead of five
event handlers, because the event handlers *will* disagree with each other
eventually.

Engine builds happen on a background queue: the first `AudioDeviceStart` on a
tap aggregate blocks until the user answers the TCC permission prompt, and
that can take as long as it takes a person to notice a dialog.

## The watchdog

Everything that fails in this API fails as **silence with noErr**: a denied
permission, DRM-protected sources, a miswired tap description, and a known
intermittent bug where a tap decays to all-zero buffers after Bluetooth churn
(Apple forums thread 825780). The IOProc callbacks keep firing in every case.

So a 1 Hz watchdog compares what should be true against measured signal:

- No IO callbacks for 3 s → the aggregate died; rebuild.
- App reports playing, route unmuted, but the tap delivers zeros for 5 s →
  rebuild once (this recovers the decay bug).
- Still zero 12 s in → flag the route `protectedAudio` and let the UI suggest
  the Direct route. We can't distinguish DRM from a denied permission from
  the outside, and it doesn't matter much: the fix we can offer is the same.

Meters in the UI come from the same telemetry, which crosses from the audio
thread through a try-lock so the RT path never blocks (see AUDIO-PIPELINE.md).

## Process grouping

Users route *apps*; the HAL hands out process objects for *processes*. Chrome
plays every tab's audio from one sandboxed helper, Safari from
`com.apple.WebKit.GPU`, Electron apps from a renderer. `AudioProcessMonitor`
groups helpers under the app you can see: first by stripping known `.helper`
bundle-ID suffixes, then by walking the parent-PID chain until it finds a
process that is a real, user-visible application. A route stores bundle IDs
and re-resolves them to live process objects on every reconcile, which is
also what makes app relaunch work: the old tap dies with the old process, the
process-list listener fires, and reconcile re-taps the new one.

This is also why per-tab routing is impossible, in Split or anywhere: one
audio process per browser is all the OS can see.

## Shutdown

`applicationWillTerminate` tears down every engine (destroying a tap
auto-unmutes its app — macOS guarantees this even on crash) and puts the
system default output back where the user had it.

## Files

```
Sources/
  SplitApp.swift                 app entry, scenes, shutdown hook
  Audio/CoreAudioSupport.swift   typed HAL property wrappers (from AudioCap)
  Audio/AudioProcessMonitor.swift  process objects → user-visible apps
  Audio/AudioDeviceMonitor.swift   output devices, transport, default switch
  Audio/ProcessTap.swift         tap + aggregate create/teardown pair
  Audio/DelayLine.swift          interleaved ring buffer with crossfade
  Audio/RouteEngine.swift        the real-time IOProc and its param passing
  Audio/RouteSupervisor.swift    reconciler, watchdog, Direct route
  Model/RouteConfig.swift        Codable schema (legs array is future fan-out)
  Model/RouteStore.swift         JSON persistence, debounced
  UI/…                           SwiftUI: window, cards, menu bar, onboarding,
                                 diagnostics
```
