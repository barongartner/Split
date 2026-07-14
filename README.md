# Split

Several people, one Mac, everyone hearing their own thing.

Split routes each app's audio to its own output device. Apple Music can play
to your AirPods while Netflix plays to someone's wired headphones and YouTube
Music to a third pair — at the same time, from the same MacBook. Each route
has its own volume and its own delay slider so video stays lip-synced across
headphones with different latencies.

macOS can't do any of this out of the box: there's one default output and no
per-app routing. Split fixes that with the Core Audio process-tap API
(macOS 14.4+). No kernel extensions, no virtual audio drivers to install.

## Installing

Grab the `.dmg` (or `.zip`) from the
[latest release](https://github.com/barongartner/Split/releases/latest), open
it, and drag **Split** into Applications. Nothing to build, nothing else to
install.

First launch only: Split isn't notarized by Apple (that program costs $99 a
year; this app is free), so macOS will balk once. On macOS 15: try to open
Split, then go to **System Settings → Privacy & Security**, scroll down, and
click **Open Anyway**. On older macOS: right-click Split → Open → Open. You
do this exactly once.

When you add your first route, macOS asks to allow **System Audio Recording**
— that's the capture permission everything depends on. Allow it, also once.

## Using it

Click **+** and pick an app and a device. The app's audio moves to that device
and disappears from the system output. Apps show up in the picker once they've
played any audio; "audible now" marks the ones making sound this second.

The first route you add triggers a macOS permission prompt for **System Audio
Recording** — that's the capture permission everything depends on. If you
deny it, every route stays silent.

The menu bar icon has quick volume and mute for every route, for adjustments
mid-movie without leaving fullscreen.

### The Direct route

One route can be **Direct**: instead of capturing anything, Split makes that
device the system default output. Whatever you don't explicitly route plays
there. This is also the answer to DRM: the Apple TV app and Netflix-in-Safari
refuse to be captured (FairPlay protects the audio pipeline itself), but they
play through a Direct route just fine, because nothing is being captured.

Rule of thumb for movie night: the movie goes on the Direct route or in
Chrome, music apps get tapped routes.

### Syncing everyone (the Sync button)

Bluetooth headphones run 150–300 ms behind wired ones, so video needs the
faster listeners delayed to match. You don't tune that by hand — hit **Sync**:

Each listener, wearing their headphones on the couch, watches two arrows fly
toward a center line — they meet exactly on the beat, rhythm-game style — and
taps ← → until the beep in their ears lands right as they meet. About 15
seconds per person. When someone's beep sits on the beat, their slider
position has quietly measured their headphones' real latency — so after the
last person, Split aligns the whole group to the slowest pair automatically.

Then two optional checks: a **group click test** (every headphone clicks at
once — the room hearing ONE click means you're synced) and a **master nudge**
that shifts everyone together if the picture still feels off. Route cards
show when they were last synced; Bluetooth latency drifts as the electronics
warm up, so if lips wander mid-session, a re-sync is 15 seconds.

## Limits worth knowing

- **Routing is per-app, not per-tab.** Every browser plays all its tabs from
  one audio process. Two people want two different websites? Two different
  browsers (or make a Safari "Add to Dock" web app — those count as separate
  apps).
- **Two Bluetooth headphones is the reliable ceiling**, especially on Intel
  MacBooks where Bluetooth and 2.4 GHz Wi-Fi share an antenna. Listener three
  should be wired or on the speakers. Put Wi-Fi on 5 GHz and mice on USB
  dongles if things stutter.
- **One Direct route at a time.** There's only one system default output, so
  only one DRM stream can play at once. Tapped routes are unlimited (within
  reason).
- **Don't let anything grab a Bluetooth headset's mic** (Zoom, Discord, Siri).
  Bluetooth drops to phone-call quality the moment its mic opens.
- Using AirPods? Set them to **Connect to This Mac: When Last Connected** —
  on the Mac *and* on your iPhone — or they'll wander off to the phone
  mid-movie.

What works with what, tested on real hardware:
[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

## How it works

Short version: one process tap + one private aggregate device + one real-time
IOProc per route; the tap mutes the app in the system mix so its audio only
comes out where you pointed it. A reconciler rebuilds routes when apps
relaunch, devices unplug, or the capture silently dies (which it does — see
the watchdog notes). Long version:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[docs/AUDIO-PIPELINE.md](docs/AUDIO-PIPELINE.md).

## Requirements

macOS 14.4 or later. Built and tested on an Intel MacBook running macOS 15.5;
everything is architecture-independent.

## Hacking on it

```
./build.sh            # compile + sign Split.app (needs Xcode's toolchain)
./build.sh release    # also produce the dist/ zip + dmg that go on a release
```

No Xcode project, no dependencies — one script. You want an "Apple
Development" certificate in your keychain (sign into Xcode with any Apple ID,
free): the audio permission is keyed to the signing identity, and without a
stable one macOS forgets the grant on every rebuild. Details in
[docs/PERMISSIONS-AND-SIGNING.md](docs/PERMISSIONS-AND-SIGNING.md).

## License

MIT. The Core Audio property helpers and tap setup are adapted from
[AudioCap](https://github.com/insidegui/AudioCap) (BSD-2-Clause) — see
LICENSE for both notices.
