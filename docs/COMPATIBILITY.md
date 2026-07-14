# Compatibility

What routes, what doesn't, and the workaround when it doesn't. "Tapped" means
a normal Split route; "Direct" means the no-capture system-default route.

The DRM rule in one line: **FairPlay audio cannot be captured, period** — the
capture "succeeds" and delivers silence. Anything FairPlay-protected needs
the Direct route. Widevine (what Netflix and friends use in Chrome/Firefox)
captures fine.

## Sources

| Source | Tapped route | Notes |
|---|---|---|
| YouTube / YouTube Music (any browser) | ✅ | No DRM on the audio path. |
| Any non-DRM website audio/video | ✅ | Whole browser = one route. |
| Netflix, Disney+, Prime in **Chrome/Firefox** | ✅ | Widevine; captures fine. |
| Netflix etc. in **Safari** | ❌ → Direct | FairPlay. Or just use Chrome. |
| **Apple TV app** | ❌ → Direct | FairPlay. Direct plays it perfectly. |
| Apple Music app | ✅* | Reported working (SoundSource routes it). *Verify on this machine — see below.* |
| Spotify | ✅ | |
| VLC, IINA, QuickTime | ✅ | |
| Games, anything else unprotected | ✅ | |

Remember the granularity: a browser is ONE route, tabs can't be split. Two
people watching two different websites means two different browsers, or a
Safari "Add to Dock" web app for one of them (those are separate apps to
macOS).

## Outputs

| Output | Works | Notes |
|---|---|---|
| Wired 3.5 mm / USB / built-in speakers | ✅ | ~5–20 ms latency. The nice, boring case. |
| One Bluetooth headphone | ✅ | 150–300 ms latency; use other routes' delay sliders to sync. |
| Two Bluetooth headphones simultaneously | ✅ with care | The practical ceiling. Keep them close, Wi-Fi on 5 GHz, no BT mouse if you can help it. |
| Three+ Bluetooth headphones | ⚠️ expect stutter | Especially on Intel MacBooks (shared BT/Wi-Fi antenna). Make listener #3 wired. |
| AirPlay devices | untested | Latency will be large; the delay sliders only go to 1000 ms. |

Bluetooth quality collapses to phone-call grade the instant something opens
the headset's **mic** (Zoom, Discord, "Hey Siri"). Split never opens mics;
keep other apps from doing it during a movie.

## Test log

Results from this machine (Intel MacBook, macOS 15.5). Updated as tested —
if a row above disagrees with a dated entry here, trust the entry.

| Date | Test | Result |
|---|---|---|
| 2026-07-13 | Tap chain end-to-end: 440 Hz tone → tapped by PID → captured | ✅ RMS 0.065, 99.4% non-zero samples, first audio at 70 ms |
| 2026-07-13 | `.mutedWhenTapped`: capture keeps flowing while the app is muted at system output | ✅ identical RMS with mute on |
| 2026-07-13 | Split full pipeline: Chrome (YouTube) → tapped route → Built-in Output | ✅ active in <10 s, stable levels for 60 s, no dropouts |
| 2026-07-13 | Paused-but-open stream (paused YouTube tab) must NOT flag as DRM | ✅ after the ever-had-audio watchdog fix |
| 2026-07-13 | Quit mid-playback: clean exit, default output restored, routes persist | ✅ |
| 2026-07-13 | Beep scheduler simulation: grid periodicity, ± delay sign per mode, block-boundary continuity | ✅ 7/7 |
| 2026-07-13 | Beat scheduling end-to-end through a real engine (real tap + aggregate + IOProc), captured and measured | ✅ intervals 1000.0 ms; tuner −200.0 ms and click +200.0 ms shifts, exact |
| — | Beat-match feel on a real Bluetooth headphone; group click across speakers + BT | pending |
| — | Apple Music app tapped | pending |
| — | Apple TV app on Direct route | pending |
| — | Netflix in Safari (expect silence + DRM flag) / in Chrome (expect capture) | pending |
| — | 2×BT + 1 wired, three simultaneous streams, 45 min | pending |
| — | Routed app quit/relaunch re-tap; sleep/wake | pending |
