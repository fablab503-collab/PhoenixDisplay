#!/bin/bash
# Burn test: hammer the sender with repeated connect/negotiate/stream/disconnect
# cycles, impersonating the capabilities of every iMac that can actually run
# this app, plus the degenerate cases.
#
# IMPORTANT, so nobody mistakes this for something it is not:
#   Apple ships NO macOS simulator. There is no way to simulate a 2012 iMac's
#   video hardware. What this does is drive OUR negotiation and streaming code
#   against each machine's real capability profile, many times over, looking for
#   wrong choices, stalls, leaks and drift. It proves our code behaves; it does
#   not prove anything about silicon that is not physically here.
P="$(cd "$(dirname "$0")/.." && pwd)"
B="$P/build"
APP="/Applications/Phoenix Display.app"
ROUNDS="${ROUNDS:-3}"
SECS="${SECS:-6}"

# name | caps JSON (empty = announces nothing) | expected codec | expected width
PROFILES=(
"iMac 2017 27in 5K (Kaby Lake)|{\"codecs\":[\"h264\",\"hevc\"],\"maxWidth\":5120,\"maxHeight\":2880,\"appVersion\":\"imac2017\"}|hevc|5120"
"iMac Pro 2017 (Skylake-W/Vega)|{\"codecs\":[\"h264\",\"hevc\"],\"maxWidth\":5120,\"maxHeight\":2880,\"appVersion\":\"imacpro2017\"}|hevc|5120"
"iMac 2019 27in (Coffee Lake)|{\"codecs\":[\"h264\",\"hevc\"],\"maxWidth\":5120,\"maxHeight\":2880,\"appVersion\":\"imac2019\"}|hevc|5120"
"iMac 2020 27in (Comet Lake)|{\"codecs\":[\"h264\",\"hevc\"],\"maxWidth\":5120,\"maxHeight\":2880,\"appVersion\":\"imac2020\"}|hevc|5120"
"iMac 24in M1 2021|{\"codecs\":[\"h264\",\"hevc\"],\"maxWidth\":4480,\"maxHeight\":2520,\"appVersion\":\"imacM1\"}|hevc|4480"
"iMac 24in M4 2024|{\"codecs\":[\"h264\",\"hevc\"],\"maxWidth\":4480,\"maxHeight\":2520,\"appVersion\":\"imacM4\"}|hevc|4480"
"no-HEVC receiver (H.264 only)|{\"codecs\":[\"h264\"],\"maxWidth\":4096,\"maxHeight\":2304,\"appVersion\":\"h264only\"}|h264|4096"
"1080p-limited receiver|{\"codecs\":[\"h264\"],\"maxWidth\":1920,\"maxHeight\":1080,\"appVersion\":\"small\"}|h264|1920"
"old build, announces nothing||h264|4096"
)

pass=0; fail=0
echo "Burn test - $ROUNDS rounds x ${SECS}s per profile"
echo "sender: $(sysctl -n hw.model), macOS $(sw_vers -productVersion)"
echo
printf "%-34s %-6s %-9s %-7s %s\n" "receiver profile" "round" "codec" "width" "frames"
echo "--------------------------------------------------------------------------"

for entry in "${PROFILES[@]}"; do
  IFS='|' read -r name caps wantCodec wantWidth <<< "$entry"
  for r in $(seq 1 "$ROUNDS"); do
    mode="${caps:-none}"
    out=$("$B/probe" 127.0.0.1 "$mode" "$SECS" 2>&1)
    codec=$(echo "$out" | sed -n 's/.*"codec":"\([a-z0-9]*\)".*/\1/p' | tail -1)
    width=$(echo "$out" | sed -n 's/.*"width":\([0-9]*\).*/\1/p' | tail -1)
    frames=$(echo "$out" | sed -n 's/^frames: \([0-9]*\) .*/\1/p')
    fmt=$(echo "$out" | grep -c "format received: true")
    okCodec=$([ "$codec" = "$wantCodec" ] && echo 1 || echo 0)
    okWidth=$([ "$width" = "$wantWidth" ] && echo 1 || echo 0)
    okFmt=$([ "$fmt" = "1" ] && echo 1 || echo 0)
    if [ "$okCodec$okWidth$okFmt" = "111" ]; then
      pass=$((pass+1)); mark="ok"
    else
      fail=$((fail+1))
      mark="FAIL(want $wantCodec/$wantWidth got ${codec:-?}/${width:-?} fmt=$fmt)"
    fi
    printf "%-34s %-6s %-9s %-7s %-6s %s\n" "$name" "$r/$ROUNDS" "${codec:-?}" "${width:-?}" "${frames:-0}" "$mark"
  done
done

echo "--------------------------------------------------------------------------"
echo "cycles: $((pass+fail))   passed: $pass   failed: $fail"
PID=$(pgrep -f "MacOS/Phoenix Display" | head -1)
if [ -n "$PID" ]; then
  echo "sender survived: pid $PID, $(ps -o rss= -p "$PID" | tr -d ' ') KB resident"
else
  echo "SENDER DIED during the burn test"
  fail=$((fail+1))
fi
crashes=$(find ~/Library/Logs/DiagnosticReports -iname "*Phoenix*" -mmin -30 2>/dev/null | wc -l | tr -d ' ')
echo "crash reports in the last 30 min: $crashes"
[ "$fail" -eq 0 ] && [ "$crashes" -eq 0 ]
