#!/bin/bash
# Builds Phoenix Display as a universal .app targeting macOS 13 (Ventura),
# so the same bundle runs on the Apple-silicon MacBook and the 2017 Intel iMac.
set -euo pipefail
P="$(cd "$(dirname "$0")" && pwd)"
B="$P/build"
APP="$B/Phoenix Display.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MIN="13.0"
CACHE="$B/modulecache"
mkdir -p "$CACHE" "$B"
rm -rf "$APP"

SOURCES=( "$P"/Sources/*.swift )
SHIM="$P/Shim/PhoenixVD.m"
HEADER="$P/Shim/PhoenixVD.h"

build_arch () {
  local arch="$1"
  local triple="${arch}-apple-macos${MIN}"
  echo "  • $arch"
  clang -c "$SHIM" -o "$B/PhoenixVD-$arch.o" \
        -isysroot "$SDK" -target "$triple" -fobjc-arc -fmodules \
        -fmodules-cache-path="$CACHE" -I "$P/Shim" -O2 -Wall
  swiftc "${SOURCES[@]}" \
        -sdk "$SDK" -target "$triple" \
        -module-cache-path "$CACHE" \
        -import-objc-header "$HEADER" \
        -parse-as-library -O -swift-version 5 \
        -o "$B/phoenix-$arch" \
        -Xlinker "$B/PhoenixVD-$arch.o" \
        -framework ScreenCaptureKit -framework VideoToolbox \
        -framework AVFoundation -framework CoreMedia \
        -framework Network -framework AppKit -framework SwiftUI
}

ARCHS=()
echo "Compiling:"
for a in arm64 x86_64; do
  if build_arch "$a"; then ARCHS+=("$B/phoenix-$a"); else echo "  (skipped $a)"; fi
done

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "${#ARCHS[@]}" -gt 1 ]; then
  lipo -create "${ARCHS[@]}" -output "$APP/Contents/MacOS/Phoenix Display"
else
  cp "${ARCHS[0]}" "$APP/Contents/MacOS/Phoenix Display"
fi
chmod +x "$APP/Contents/MacOS/Phoenix Display"
cp "$P/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$B/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sign. Prefer the Developer ID: macOS keys Screen Recording permission to the
# signing identity, so an ad-hoc signature makes every rebuild look like a brand
# new app and the user has to grant permission again. Falls back to ad-hoc only
# when the certificate is not on this machine.
xattr -cr "$APP"
# Override with CODESIGN_IDENTITY to sign with your own certificate.
DEVID="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
if [ -n "$DEVID" ] && security find-identity -v -p codesigning 2>/dev/null | grep -qF "$DEVID"; then
  codesign --force --deep --options runtime --timestamp --sign "$DEVID" "$APP"
  echo "signed as: $DEVID"
else
  echo "WARNING: Developer ID certificate not found — falling back to ad-hoc."
  echo "         Screen Recording permission will reset on every rebuild."
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP" && echo "signature OK"
lipo -archs "$APP/Contents/MacOS/Phoenix Display"
echo "built: $APP"
