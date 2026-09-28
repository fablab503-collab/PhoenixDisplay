# Phoenix Display

Turn another Mac into a second screen — over Wi-Fi, ethernet or a Thunderbolt cable.
Mirror it, or extend onto it as a genuinely separate desktop.

Streams a real **5120 × 2880** desktop with HEVC. Universal binary, macOS 13 and later.

---

## Why HEVC, and why that matters

Apple's hardware **H.264** encoder refuses anything above **4096 × 2304** — measured, not guessed:

```
VTCompressionSessionCreate, Apple M2 Pro
  H.264  4096x2304  ok        H.264  4480x2520  FAILS (-12903)
  HEVC   5120x2880  ok        HEVC   7680x4320  ok
```

So a full 5K desktop is impossible over H.264 and straightforward over HEVC. The receiving
Mac is asked what it can decode and the sender picks accordingly:

```
receiver connects ──► sends `caps` {codecs, maxWidth, maxHeight}
sender  ──► picks HEVC if both ends support it, else H.264
        ──► `hello` {width, height, fps, mode, codec}
        ──► `format` (VPS+SPS+PPS for HEVC, SPS+PPS for H.264)
        ──► `frame` …
```

A receiver that sends no capabilities within 1.2 s is treated as an older build and gets H.264,
so new and old versions interoperate.

Worth knowing: a 2017 Intel iMac (Kaby Lake + Radeon Pro 580) **does** decode 5120 × 2880 HEVC
in hardware. Spec sheets suggest 4K; the hardware says otherwise. The app probes rather than
assumes, via `VTIsHardwareDecodeSupported` and a real session.

## What it does

- **Mirror** — the other screen shows the same picture.
- **Extend** — a real second desktop you can drag windows onto, created with `CGVirtualDisplay`.
- **Arrangement** — put the extra screen left, right, above or below.
- **Main display** — move the menu bar to the streamed screen, so the other Mac becomes primary.
- **Network choice** — Automatic, or pin the stream to a named interface (Wi-Fi, ethernet,
  Thunderbolt Bridge). Plus connect-by-address when Bonjour is blocked.
- Discovery over Bonjour `_phoenixdisplay._tcp`, framed TCP on port 51777.

## Honest limits

- **Latency.** Capture, encode, send, decode and display all cost time. It is good for reference
  windows, documentation, chat, monitoring. It is *not* a substitute for a cabled monitor if you
  are doing fast pointer work or anything latency-sensitive.
- **An extra desktop stays until the app quits.** Releasing the `CGVirtualDisplay` object
  deallocates it — verified with a weak reference — but the window server keeps the display
  registered. So the app creates at most one per size and reuses it.
- **Screen Recording permission is per-signature.** Ad-hoc builds get a fresh identity on every
  rebuild, so the grant resets each time. `build.sh` signs with a Developer ID when one is
  available, which keeps it.
- **macOS never prompts for Screen Recording.** `kTCCServiceScreenCapture does not allow
  prompting; returning denied` — you must add the app by hand in
  System Settings ▸ Privacy & Security ▸ Screen Recording. If it was denied before, clear the old
  decision first: `tccutil reset ScreenCapture danielscreatesparis.Phoenix-Display`.
- **Not shippable on the Mac App Store** with extend mode. See below.

## Build

```sh
./build.sh
```

Universal (arm64 + x86_64), minimum macOS 13.0. Signs with the first Developer ID certificate it
finds; override with `CODESIGN_IDENTITY`. No Xcode project — plain `swiftc` + `clang`.

Notarize for distribution:

```sh
APP="build/Phoenix Display.app"
ditto -c -k --keepParent "$APP" /tmp/notarize.zip
xcrun notarytool submit /tmp/notarize.zip --keychain-profile notarytool --wait
xcrun stapler staple "$APP"
spctl --assess --type execute -vv "$APP"   # want: accepted, Notarized Developer ID
```

Sign first, then notarize, then staple. Signing after notarizing throws the ticket away.

## Mac App Store

**Extend mode cannot ship on the App Store.** It depends on the private CoreGraphics classes
`CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplayMode` and
`CGVirtualDisplaySettings`. Resolving them at runtime with `NSClassFromString` avoids link-time
imports, but it does not make the app compliant — App Store Review Guideline 2.5.1 prohibits
private API use however it is reached. Hiding it from review is not an option worth taking.

The notarized Developer ID build has no such restriction, which is how this is distributed.

## Layout

| path | job |
|---|---|
| `Shim/PhoenixVD.{h,m}` | crash-proof `CGVirtualDisplay` wrapper, un-mirror, arrangement, main display |
| `Sources/Capture.swift` | ScreenCaptureKit capture, H.264 + HEVC hardware encoder |
| `Sources/Capabilities.swift` | probes what this Mac can actually encode and decode |
| `Sources/Net.swift` | Bonjour, framed TCP, capability handshake, backpressure |
| `Sources/Transport.swift` | interface enumeration and pinning |
| `Sources/DisplayView.swift` | receiver rendering via `AVSampleBufferDisplayLayer` |
| `Sources/SenderEngine.swift` | ties capture, encode, network and the virtual display together |
| `Tools/` | standalone probes used to establish the facts above |

## Tools

- `Tools/caps.swift` — which codecs and sizes this Mac will hardware-encode.
- `Tools/hevcprobe.swift` — encodes a real 5K HEVC keyframe on one Mac, decodes it on another.
- `Tools/vdtest.m` — creates a virtual display and prints the mirror state before/during/after.
- `Tools/probe.swift` — connects to a running sender and reports codec, frame rate and bitrate.

## Licence

MIT. See [LICENSE](LICENSE).
