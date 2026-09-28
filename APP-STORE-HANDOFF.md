# Handoff: ship Phoenix Display on the Mac App Store

Written 2026-09-28 for Claude Cowork. Read all of it before changing anything.

Project: `~/Developer/apps/PhoenixDisplay` (git repo, last commit `fcaa348`,
"Connection status page, menu bar routes, and a burn test").
Owner: Daniel Madac. Reply to him in short, plain English - it is not his first language.

## The goal

Get Phoenix Display accepted on the Mac App Store, without breaking the
Developer ID build that is already distributed outside the store.

## Read first

- `README.md` - what the app does, how it is built, and the "Mac App Store" section.
- `~/.claude/skills/mac-notarize/SKILL.md` - Daniel's signing setup and five traps
  already hit on 2026-09-21. That skill covers Developer ID, not the App Store,
  but the traps (get-task-allow, ad-hoc signing that reports success) still apply.

## The blocker you must solve first

**Extend mode uses private Apple API and cannot go on the App Store.**

`Shim/PhoenixVD.m` builds the second desktop with the private CoreGraphics classes
`CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplayMode` and
`CGVirtualDisplaySettings`, reached through `NSClassFromString`. App Store Review
Guideline 2.5.1 bans private API however it is reached. Do not try to hide it
from review - Daniel already decided against that (README, "Mac App Store").

So the store build must be a **mirror-only** build:

1. Add a build flag, e.g. `APPSTORE`, passed as `-D APPSTORE` to `swiftc` and
   `-DAPPSTORE=1` to `clang`.
2. With the flag on, do not compile or link `Shim/PhoenixVD.m` at all. The
   class-name strings must not be in the binary. Check afterwards:
   `strings "Phoenix Display.app/Contents/MacOS/Phoenix Display" | grep -i CGVirtual`
   must print nothing.
3. Hide Extend, Arrangement and "Main display" in the UI for that build. They all
   depend on the virtual display. Mirror, codec negotiation, network choice and
   the connection page stay.
4. Keep the Developer ID build exactly as it is, with extend mode.

**Ask Daniel before starting** whether a mirror-only store version is what he
wants. If he says no, stop here - there is no compliant way to ship extend mode.

## Other things that will fail review or the sandbox

App Store apps must be sandboxed. Current build is not.

- **`Sources/LinkMonitor.swift:163`** runs `/usr/sbin/system_profiler` with
  `Process()` to detect Thunderbolt. Inside the sandbox this may fail or return
  nothing. Test it sandboxed. If it fails, read the Thunderbolt link another way
  (IOKit, if the sandbox allows it) or drop the Thunderbolt line in the store
  build and keep the rest of the connection page.
- **Entitlements** - make `Resources/AppStore.entitlements` with at least:
  - `com.apple.security.app-sandbox` = true
  - `com.apple.security.network.client` = true (connect to the other Mac)
  - `com.apple.security.network.server` = true (listen on TCP 51777, Bonjour)
  - no `com.apple.security.get-task-allow`
- **Screen Recording** - ScreenCaptureKit works in the sandbox, but the user still
  grants it by hand in System Settings (the README explains macOS never prompts).
  The app should show clear steps when permission is missing. Reviewers will hit
  this; add a note for them in App Review notes.
- **Privacy manifest** - the app uses `UserDefaults` (AppHub.swift, SenderEngine.swift,
  Transport.swift), which is a "required reason" API. Add `PrivacyInfo.xcprivacy`
  to `Contents/Resources` declaring it (reason `CA92.1`, app's own defaults) and
  no tracking, no data collected.
- **Info.plist** (`Resources/Info.plist`) - add `LSApplicationCategoryType`
  (probably `public.app-category.utilities`). Raise `CFBundleVersion` (now `20`)
  on every upload. `CFBundleShortVersionString` is `2.0` though the README says 2.1 -
  ask Daniel which is right. `ITSAppUsesNonExemptEncryption` is already `false`.
- **Bundle ID** is `danielscreatesparis.Phoenix-Display`. It must be registered in
  the Apple Developer portal and have an App Store Connect app record.

## Signing for the store (different from Developer ID)

Team ID `B7P7FR67VK`. The store needs certificates Daniel may not have yet:

- **Apple Distribution** (or "3rd Party Mac Developer Application") to sign the app
- **Mac Installer Distribution** (or "3rd Party Mac Developer Installer") to sign the .pkg
- A **Mac App Store provisioning profile** for the bundle ID, copied into the app as
  `Contents/embedded.provisionprofile`

Check with `security find-identity -v -p codesigning` and
`security find-identity -v` (installer certs are not code-signing identities).
I could not check these from my session - the sandbox hid the keychain.
Making certificates needs Daniel in Xcode (Settings > Apple Accounts > Manage
Certificates). Do not make them for him without asking.

There is no Xcode project; `build.sh` uses plain `swiftc` + `clang`. Suggested
approach: add `build-appstore.sh` next to it rather than changing `build.sh`.
Rough shape:

```sh
# after building with -D APPSTORE and without the shim
codesign --force --options runtime --timestamp \
  --entitlements Resources/AppStore.entitlements \
  --sign "Apple Distribution: Daniel Madac (B7P7FR67VK)" "$APP"
productbuild --component "$APP" /Applications \
  --sign "3rd Party Mac Developer Installer: Daniel Madac (B7P7FR67VK)" \
  "build/Phoenix Display.pkg"
```

Use the exact certificate names `security find-identity` prints. Check the
signature is real (not ad-hoc):
`codesign -dv --verbose=4 "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier'`
and the entitlements: `codesign -d --entitlements :- "$APP"`.

App Store Connect may reject the icon: the app ships `AppIcon.icns` only, no asset
catalog. If validation asks for it, build an `Assets.car` with `actool` from
`build/AppIcon.png` (1024 px).

Upload with Apple's Transporter app, or whatever upload command Xcode 27 still
supports - check, do not assume `altool` works.

## Test before upload

- Build, run the sandboxed app on this Mac, mirror to the 2017 iMac.
- `Tools/burntest.sh` and `Tools/testsuite.sh` (see README) against the store build.
  Expect the extend-mode cases to be skipped, not to fail silently.
- Confirm Bonjour discovery and connect-by-address both work sandboxed.
- Confirm no `CGVirtual` strings in the binary (see above).

## Store listing (ask Daniel for anything not here)

- Name, subtitle, description, keywords, category, price
- Screenshots: at least one Mac screenshot at an accepted size (e.g. 2880x1800)
- Privacy policy URL (required even when nothing is collected)
- Support URL
- App Review notes: explain the other-Mac requirement and the manual Screen Recording
  step, so the reviewer can test it

## Do not

- Do not ship or hide the private CGVirtualDisplay code in the store build.
- Do not change the Developer ID build or its signing.
- Do not submit for review or press anything in App Store Connect without
  Daniel saying yes first. Show him the finished .pkg and listing text.
- Commit on a branch (e.g. `appstore`), not straight onto main.
