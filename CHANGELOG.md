# Changelog

Versioning is semantic: fixes bump patch, features bump minor, breaking
changes bump major. The version in Info.plist, the git tag, and the GitHub
release name always match.

## 1.1.0 — 2026-07-13

Delay tuning stopped being homework.

- **Sync wizard (beat-match)**: each listener watches a pulsing ring and taps
  arrows until the beep in their headphones lands on it (~15 s per person).
  Their answer doubles as a latency measurement, so Split aligns the whole
  group to the slowest headphones automatically. No microphone, nothing to
  hold, no new permissions.
- Direct-route listeners get the same beat-match as a check; if their device
  can't keep up with the group, Split says by how much instead of pretending.
- **Group click test**: every route clicks at once — one click heard = synced.
- **Master nudge**: one slider shifts everyone together to match the picture.
- Route cards show when they were last synced, with a drift hint for
  Bluetooth after half an hour.
- Diagnostics gained a per-route Beep button (three seconds of clicks —
  the fastest "is this route audible at all" check).

## 1.0.0 — 2026-07-13

First release.

- Tapped routes: any app's audio to any output device, several at once.
  Per-route volume (0–200%, click-free ramp) and delay (0–1000 ms, live,
  crossfaded) with level meters.
- Direct route: makes a device the system default output — the DRM escape
  hatch (Apple TV app, Netflix-in-Safari) and the "everything else" bucket.
  Restores your previous default on removal and on quit, even after a crash.
- Reconciler + watchdog: routes survive app relaunches, device unplug/replug,
  sample-rate changes, and the known tap zero-buffer decay bug; capturing
  silence from a playing app gets flagged as protected audio with a
  one-click switch to Direct.
- Presets: save and restore whole routing setups by name.
- Main window + menu bar quick controls; first-run explainer for the
  System Audio Recording permission; Bluetooth-ceiling and per-app-routing
  warnings where they're relevant; Diagnostics window with live meters.
