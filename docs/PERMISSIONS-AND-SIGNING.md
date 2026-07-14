# Permissions and signing

This is the part of the project that produces no error messages when it's
wrong, so it gets its own document.

## The permission

Split needs **System Audio Recording Only** — it appears in System Settings →
Privacy & Security → **Screen & System Audio Recording**, but it's the
audio-only entry, not full screen recording. The prompt fires automatically
the first time Split starts IO on a tap aggregate (in practice: the first
route you add). `NSAudioCaptureUsageDescription` in Info.plist is mandatory;
note that Xcode's plist editor doesn't list this key in its dropdown — it has
to be typed by hand. The raw TCC service name is `kTCCServiceAudioCapture`.

There is **no API to ask whether the permission was granted**. A denied
permission and a working tap on a silent app look byte-identical: valid
callbacks, all-zero samples, noErr everywhere. Split's watchdog treats
sustained silence-while-playing as "protected or denied" and says so in the
UI, because it genuinely cannot tell the difference.

One more trap: `AudioDeviceStart` **blocks** until the user answers the
prompt the first time. Split calls it on a background queue for exactly this
reason. If you're building something similar, don't put it on the main thread.

The Direct route needs no permission at all — it captures nothing.

## Signing, and why ad-hoc bites

TCC keys the grant to the code-signing identity. Consequences:

- **Ad-hoc signing** (`codesign -s -`) produces a new CDHash every build, so
  macOS treats each rebuild as a brand-new app: the grant is gone, and a stale
  entry can suppress the re-prompt entirely — the app just silently captures
  zeros.
- **Unsigned doesn't prompt at all.** And on Intel x86_64 the linker does
  *not* auto-ad-hoc-sign binaries the way it does on Apple Silicon, so a bare
  `swiftc` build is genuinely unsigned. This cost an evening of confusion
  during development; it will not cost you one.

The fix is a stable identity: `build.sh` signs with the **"Apple
Development"** certificate from your keychain, which any free Apple ID gets
you (sign into Xcode once: Settings → Accounts). With a stable identity +
stable bundle ID, the grant survives rebuilds.

No paid Developer ID is required for personal use. A paid cert only matters
if you distribute to other people and want Gatekeeper to be polite to them.

## When permission state gets wedged

Testing deny-then-allow flows, or switching signing identities, can leave TCC
in a state where nothing prompts and nothing works. Reset it:

```
tccutil reset AudioCapture com.barongartner.Split
```

(Verified on macOS 15.5 — some writeups say `SystemAudioCaptureRequests`,
which fails here. `tccutil reset All com.barongartner.Split` is the
sledgehammer if the service name ever changes again.)

A related wedge, learned the hard way: if the permission dialog is up and the
requesting process gets killed before anyone answers it, TCC can end up in a
state where taps run, `AudioDeviceStart` succeeds, and the IOProc simply
never fires — no prompt, no error, no data. The reset above fixes that too.

Then relaunch Split and add a route — the prompt should fire again. You can
verify what TCC actually has recorded with:

```
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT client, auth_value FROM access WHERE service='kTCCServiceAudioCapture';"
```

`auth_value` 2 means granted, 0 means denied.

## Distributing to other Macs

Users install from the release `.dmg`/`.zip` — never from source. What they
hit and why:

- **The one-time Gatekeeper hoop.** Split is signed with an Apple Development
  certificate but not notarized — notarization requires the $99/year
  Developer Program. So the first launch on a new Mac needs System Settings →
  Privacy & Security → **Open Anyway** (macOS 15) or right-click → Open
  (earlier). Once per Mac, then never again.
- **Signatures are timestamped** (`codesign --timestamp` in build.sh), so a
  release keeps launching after the signing certificate expires — Apple
  Development certs only live a year, and a customer's download shouldn't
  care.
- **The audio permission travels fine.** TCC keys the grant to the signing
  identity + bundle ID, both of which are stable across releases, so updating
  Split on any Mac keeps its System Audio Recording grant. (This is the same
  reason ad-hoc signing was never an option — a new identity per build means
  a new permission prompt per build.)
- `./build.sh release` produces the artifacts (`dist/Split-<version>.zip` and
  `.dmg`); the version comes from Info.plist, and the tag and release name
  must match it.

## Indicators

While any tap is live, macOS shows the system audio-capture indicator (the
purple-ish dot / menu bar icon, milder than the orange mic dot). That's
normal and there's no way to avoid it — Split is, as far as macOS is
concerned, recording system audio the whole time it's routing.
