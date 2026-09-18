#!/usr/bin/env bash
# Raw-wire conformance oracle (spec §8). Uses ONLY curl + standard tools, so it
# is independent of every easy-rpc implementation. It validates the wire
# contract on a live server: paths, content-types, status codes, trailer
# headers, END-frame bytes, and the proto-only rejections.
#
# Usage: raw-wire.sh [base-url]      (default http://127.0.0.1:18888)
# Exit 0 => all oracle checks pass.
set -u
BASE="${1:-http://127.0.0.1:18888}"
SVC="easyrpc.conformance.v1.ConformanceService"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

req() { # req <name> <expected-status> <curl args...>
  local name="$1" want="$2"; shift 2
  local code
  code="$(curl -s -o /tmp/opencode/raw-body.bin -w '%{http_code}' "$@")"
  if [ "$code" = "$want" ]; then ok "$name ($code)"; else bad "$name (got $code want $want)"; fi
}

echo "== raw-wire oracle @ $BASE =="

# ---- unary: proto + JSON rejected (415) ----
# EchoRequest{input:"hi"} = 0a 02 68 69
printf '\x0a\x02hi' > /tmp/opencode/echo-req.bin
req "unary proto Echo 200" 200 -X POST "$BASE/$SVC/Echo" \
  -H 'content-type: application/proto' --data-binary @/tmp/opencode/echo-req.bin
req "unary JSON rejected 415" 415 -X POST "$BASE/$SVC/Echo" \
  -H 'content-type: application/json' --data-binary '{"input":"hi"}'
req "unknown method 404" 404 -X POST "$BASE/$SVC/Nope" \
  -H 'content-type: application/proto' --data-binary ''
# protocol-version 12 (unimplemented) -> HTTP 501 (spec §4)
req "bad protocol-version 501" 501 -X POST "$BASE/$SVC/Echo" \
  -H 'content-type: application/proto' -H 'connect-protocol-version: 999' --data-binary @/tmp/opencode/echo-req.bin

# ---- unary error: HTTP status + JSON body code ----
curl -s -o /tmp/opencode/raw-err.bin -w '%{http_code}' -X POST "$BASE/$SVC/FailDetails" \
  -H 'content-type: application/proto' --data-binary $'\x08\x08\x12\x07limited' >/tmp/opencode/raw-code.txt
if [ "$(cat /tmp/opencode/raw-code.txt)" = "429" ] && grep -q 'resource_exhausted' /tmp/opencode/raw-err.bin; then
  ok "unary error status=429 + JSON code"
else
  bad "unary error (status $(cat /tmp/opencode/raw-code.txt); body $(head -c 80 /tmp/opencode/raw-err.bin))"
fi

# ---- unary trailer: trailer-* response header ----
printf '\x0a\x01x' > /tmp/opencode/et-req.bin
curl -s -D /tmp/opencode/raw-hdrs.txt -o /dev/null -X POST "$BASE/$SVC/EchoTrailer" \
  -H 'content-type: application/proto' --data-binary @/tmp/opencode/et-req.bin
if grep -qi '^trailer-x-trl: unary-x' /tmp/opencode/raw-hdrs.txt; then
  ok "unary trailer-* header"
else
  bad "unary trailer-* header (headers: $(grep -i trailer /tmp/opencode/raw-hdrs.txt | tr -d '\r' | tr '\n' ' '))"
fi

# ---- server-stream: framed response + END frame + trailers ----
# CountRequest{count:3} = 08 03, enveloped as one frame: 00 00 00 00 02 08 03
printf '\x00\x00\x00\x00\x02\x08\x03' > /tmp/opencode/count-req.bin
curl -s -o /tmp/opencode/raw-stream.bin -w '%{http_code}' -X POST "$BASE/$SVC/Count" \
  -H 'content-type: application/connect+proto' --data-binary @/tmp/opencode/count-req.bin >/tmp/opencode/raw-sc.txt
if [ "$(cat /tmp/opencode/raw-sc.txt)" = "200" ]; then ok "server-stream status=200"; else bad "server-stream status=$(cat /tmp/opencode/raw-sc.txt)"; fi
# The stream MUST terminate with an END frame (flags bit1=0x02). A clean end
# is `{}` -> 7 bytes: 02 00000002 7b7d.
tail_hex="$(od -An -tx1 /tmp/opencode/raw-stream.bin | tr -d ' \n' | tail -c 14)"
if [ "$tail_hex" = "02000000027b7d" ]; then ok "stream END frame (02 00000002 7b7d)"; else bad "stream END frame (tail=$tail_hex)"; fi

# ---- streaming trailer: END frame JSON metadata ----
printf '\x00\x00\x00\x00\x02\x08\x02' > /tmp/opencode/ct-req.bin
curl -s -o /tmp/opencode/raw-ct.bin -X POST "$BASE/$SVC/CountTrailer" \
  -H 'content-type: application/connect+proto' --data-binary @/tmp/opencode/ct-req.bin
if grep -aq 'x-ctrailer' /tmp/opencode/raw-ct.bin; then ok "stream END metadata (x-ctrailer)"; else bad "stream END metadata missing"; fi

# ---- new: EchoBytes (non-UTF-8 round-trip) ----
printf '\x0a\x04\x00\x01\x02\xff' > /tmp/opencode/eb-req.bin
curl -s -o /tmp/opencode/eb-out.bin -X POST "$BASE/$SVC/EchoBytes" \
  -H 'content-type: application/proto' --data-binary @/tmp/opencode/eb-req.bin
if [ "$(od -An -tx1 /tmp/opencode/eb-out.bin | tr -d ' \n')" = "0a04000102ff" ]; then ok "EchoBytes round-trip"; else bad "EchoBytes round-trip"; fi

# ---- new: Empty ----
req "Empty 200" 200 -X POST "$BASE/$SVC/Empty" -H 'content-type: application/proto' --data-binary ''

# ---- new: deadline (Sleep 200ms with 50ms timeout) -> 504 deadline_exceeded ----
req "Sleep deadline 504" 504 -X POST "$BASE/$SVC/Sleep" \
  -H 'content-type: application/proto' -H 'connect-timeout-ms: 50' --data-binary $'\x08\xc8\x01'

echo
echo "=== raw-wire: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
