#!/bin/bash
# Phoenix Display test suite. Every case is executed for real on real hardware.
# Nothing here is simulated or asserted from a spec sheet.
P="$(cd "$(dirname "$0")/.." && pwd)"
B="$P/build"
APP="/Applications/Phoenix Display.app"
IMAC="${PHOENIX_IMAC:?set PHOENIX_IMAC to user@host of the second Mac}"
KEY="${PHOENIX_KEY:-$HOME/.ssh/id_ed25519}"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10 -i $KEY $IMAC"

pass=0; fail=0; n=0
ok()   { n=$((n+1)); pass=$((pass+1)); printf "  %2d  PASS  %s\n" "$n" "$1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); printf "  %2d  FAIL  %s  <- %s\n" "$n" "$1" "$2"; }
check(){ if [ "$1" = "1" ]; then ok "$2"; else bad "$2" "$3"; fi }

restart() {  # $1=mode $2=preset
  pkill -f "MacOS/Phoenix Display" 2>/dev/null; sleep 2
  defaults write danielscreatesparis.Phoenix-Display phoenix.mode -string "$1"
  defaults write danielscreatesparis.Phoenix-Display phoenix.preset -string "$2"
  defaults write danielscreatesparis.Phoenix-Display phoenix.startMinimised -bool true
  open -a "$APP"; sleep 6
}
stream() { "$B/probe" 127.0.0.1 "$1" "${2:-8}" 2>&1; }

echo "Phoenix Display - test suite"
echo "sender:   $(sysctl -n hw.model), macOS $(sw_vers -productVersion)"
echo "receiver: $($SSH 'sysctl -n hw.model; sw_vers -productVersion' 2>/dev/null | tr '\n' ' ')"
echo

echo "ENCODE / DECODE"
c=$("$B/phoenix-compat" | grep "5120x2880" | grep -c "no .*yes")
check "$([ "$c" -ge 1 ] && echo 1)" "sender: HEVC encodes 5K, H.264 refuses it" "expected H.264 no / HEVC yes at 5120x2880"
c=$($SSH '/tmp/phoenix-compat' 2>/dev/null | grep -c "can RECEIVE a 5K desktop: YES")
check "$([ "$c" -ge 1 ] && echo 1)" "receiver: iMac decodes 5K HEVC in hardware" "probe said no"
"$B/hevcprobe-arm" encode /tmp/claude-501/t5k.bin 5120 2880 >/dev/null 2>&1
scp -q -o BatchMode=yes -i "$KEY" /tmp/claude-501/t5k.bin "$IMAC:/tmp/" 2>/dev/null
c=$($SSH '/tmp/hevcprobe-x86 decode /tmp/t5k.bin 5120 2880' 2>/dev/null | grep -c "hardware-only.*DECODED 5120x2880")
check "$([ "$c" -ge 1 ] && echo 1)" "end to end: 5K keyframe encoded here, decoded on the iMac" "no hardware decode"

echo
echo "VIRTUAL DISPLAY"
pkill -f "MacOS/Phoenix Display" 2>/dev/null; sleep 3   # only one holder at a time
r=$("$B/sizetest" 5120 2880 1 2>&1); sleep 1
check "$(echo "$r" | grep -qc 'got 5120x2880' && echo 1)" "extend: a 5K request gives a 5120x2880 desktop" "$r"
check "$(echo "$r" | grep -qc 'mirrored=0' && echo 1)" "extend: not left in a mirror set" "$r"
r=$("$B/maintest" 2>&1); sleep 1
check "$(echo "$r" | grep -qc 'makeMainDisplay -> 1' && echo 1)" "main display: menu bar moves to the streamed screen" "$r"
check "$(echo "$r" | grep -qc 'restoreBuiltInAsMain -> 1' && echo 1)" "main display: restores to the built-in" "$r"
r=$("$B/sizetest" 1920 1080 1 2>&1); sleep 1
check "$(echo "$r" | grep -qc 'got 1920x1080' && echo 1)" "extend: a 1080p request gives 1920x1080" "$r"

echo
echo "CODEC NEGOTIATION"
restart mirror 5k
r=$(stream hevc 8)
check "$(echo "$r" | grep -qc '"codec":"hevc"' && echo 1)" "HEVC chosen when the receiver offers it" "$r"
check "$(echo "$r" | grep -qc '"width":5120' && echo 1)" "5120x2880 negotiated over HEVC" "$r"
r=$(stream h264 8)
check "$(echo "$r" | grep -qc '"codec":"h264"' && echo 1)" "H.264 chosen for an HEVC-incapable receiver" "$r"
check "$(echo "$r" | grep -qc '"width":4096' && echo 1)" "resolution clamped to 4096x2304 on H.264" "$r"
r=$(stream none 8)
check "$(echo "$r" | grep -qc '"codec":"h264"' && echo 1)" "H.264 fallback for a receiver that announces nothing" "$r"

echo
echo "STREAMING"
r=$(stream hevc 8)
check "$(echo "$r" | grep -qc 'format received: true' && echo 1)" "mirror: parameter sets delivered" "$r"
f=$(echo "$r" | sed -n 's/.*frames: \([0-9]*\) .*/\1/p')
check "$([ "${f:-0}" -gt 20 ] && echo 1)" "mirror: frames flowing (got ${f:-0})" "only ${f:-0} frames"
restart extend 5k
r=$(stream hevc 8)
check "$(echo "$r" | grep -qc '"mode":"extend"' && echo 1)" "extend: streams a separate desktop" "$r"
d=$(/usr/bin/python3 -c "
import ctypes
cg=ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
a=(ctypes.c_uint32*16)(); n=ctypes.c_uint32()
cg.CGGetOnlineDisplayList(16,a,ctypes.byref(n))
cg.CGDisplayPixelsWide.restype=ctypes.c_size_t
print(max(cg.CGDisplayPixelsWide(a[i]) for i in range(n.value)))" 2>/dev/null)
check "$([ "${d:-0}" -ge 5120 ] && echo 1)" "extend: the desktop really is 5120 wide (got ${d:-0})" "widest display was ${d:-0}"

echo
echo "DISTRIBUTION"
check "$(spctl --assess --type execute "$APP" >/dev/null 2>&1 && echo 1)" "sender build passes Gatekeeper" "rejected"
check "$($SSH 'spctl --assess --type execute "/Applications/Phoenix Display.app"' >/dev/null 2>&1 && echo 1)" "receiver build passes Gatekeeper on the iMac" "rejected"

echo
echo "-------------------------------------------"
printf " %d passed, %d failed, %d total\n" "$pass" "$fail" "$n"
echo "-------------------------------------------"
[ "$fail" -eq 0 ]
