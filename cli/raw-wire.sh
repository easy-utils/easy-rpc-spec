#!/usr/bin/env bash
# Raw-wire conformance oracle (spec §8). Uses ONLY curl + POSIX tools (printf,
# od, awk, grep), so it is independent of every easy-rpc implementation. It
# validates the wire contract on a live server:
#
#   * all 16 Connect codes (unary HTTP status + JSON body; stream HTTP 200 + END)
#   * stream boundaries (0 / N data frames, error before/after frames)
#   * unexpected requests (verb, path, content-type, version, encoding, frames)
#   * malformed envelopes (truncated header/frame, oversize, corrupt gzip flag)
#   * limits (oversize request -> code 8)
#   * metadata (multi-value request header, unary trailer, stream END metadata)
#   * HTTP version negotiation (h1.1 + h2c prior-knowledge)
#
# Usage: raw-wire.sh [base-url] [server-protos]
#   server-protos: comma list of HTTP versions the server can serve, e.g.
#   "h1,h2c" (default) or "h1" (Node h1-only). h2c checks are skipped when the
#   server does not advertise h2c.
set -u
BASE="${1:-http://127.0.0.1:18888}"
SERVER_PROTOS="${2:-h1,h2c}"
SVC="easyrpc.conformance.v1.ConformanceService"
TMP=/tmp/opencode/raw-wire
mkdir -p "$TMP"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

# ---- byte / message helpers (no external deps) ----
byte() { printf "\\$(printf '%03o' "$1")"; }

# Connect code -> wire name (index 1..16).
code_name() {
  case "$1" in
    1) echo canceled;; 2) echo unknown;; 3) echo invalid_argument;;
    4) echo deadline_exceeded;; 5) echo not_found;; 6) echo already_exists;;
    7) echo permission_denied;; 8) echo resource_exhausted;;
    9) echo failed_precondition;; 10) echo aborted;; 11) echo out_of_range;;
    12) echo unimplemented;; 13) echo internal;; 14) echo unavailable;;
    15) echo data_loss;; 16) echo unauthenticated;; *) echo unknown;;
  esac
}

# http status for a Connect code (spec §4 table).
http_for_code() {
  case "$1" in
    1) echo 499;; 3) echo 400;; 4) echo 504;; 5) echo 404;; 6) echo 409;;
    7) echo 403;; 8) echo 429;; 9) echo 400;; 10) echo 409;; 11) echo 400;;
    12) echo 501;; 14) echo 503;; 16) echo 401;; *) echo 500;;
  esac
}

# FailDetailsRequest{code, message:"x"}; code fits one byte (1..16).
gen_fail_details() { # <code> > file
  byte 0x08; byte "$1"; byte 0x12; byte 0x01; printf 'x'
}
# StreamFailRequest{emit_before, code, message:"x"}; both fit one byte.
gen_stream_fail() { # <emit_before> <code> > file
  byte 0x08; byte "$1"; byte 0x10; byte "$2"; byte 0x1a; byte 0x01; printf 'x'
}
# CountRequest{count:n}; n fits one byte.
gen_count() { byte 0x08; byte "$1"; }
# Wrap the contents of <infile> in ONE framed envelope (flags=0) -> <outfile>.
# File-based (never command substitution) so NUL bytes survive.
gen_frame_file() { # <infile> <outfile>
  local n; n=$(wc -c < "$1")
  { byte 0; byte $(( (n >> 24) & 255 )); byte $(( (n >> 16) & 255 ))
    byte $(( (n >> 8) & 255 )); byte $(( n & 255 )); cat "$1"; } > "$2"
}
gen_frame() { # <infile> <outfile>
  gen_frame_file "$1" "$2"
}

# frame_stats <file> -> "<data_frames> <end?1:0> <end_json_error_name>"
# Parses Connect envelopes with od+awk (no easy-rpc code).
frame_stats() {
  od -An -v -tu1 "$1" | awk '
    { for (i = 1; i <= NF; i++) b[++n] = $i }
    END {
      off = 0; data = 0; end = 0; names = "";
      while (off + 5 <= n) {
        flags = b[off+1];
        len = b[off+2]*16777216 + b[off+3]*65536 + b[off+4]*256 + b[off+5];
        if (off + 5 + len > n) break;
        payload = "";
        for (j = off+6; j <= off+5+len; j++) payload = payload sprintf("%c", b[j]);
        if (int(flags/2) % 2 == 1) {
          end = 1;
          # extract the error code name from the END JSON
          if (match(payload, /"code"[ \t]*:[ \t]*"[a-z_]+"/)) {
            s = substr(payload, RSTART, RLENGTH);
            gsub(/.*"code"[ \t]*:[ \t]*"/, "", s);
            gsub(/".*/, "", s);
            names = s;
          }
        } else data++;
        off = off + 5 + len;
      }
      printf "%d %d %s\n", data, end, names;
    }'
}

# get_response_http_version <url> <curl args...> -> prints %{http_version}
http_version() { curl -s -o /dev/null -w '%{http_version}' "$@"; }

echo "== raw-wire oracle @ $BASE =="

# ---------------------------------------------------------------------------
# 1. All 16 Connect codes: unary (HTTP status + JSON body code name)
# ---------------------------------------------------------------------------
all_codes=1
for c in $(seq 1 16); do
  gen_fail_details "$c" > "$TMP/fd.bin"
  want_http="$(http_for_code "$c")"; name="$(code_name "$c")"
  got_http="$(curl -s -o "$TMP/fd-out.bin" -w '%{http_code}' -X POST \
    "$BASE/$SVC/FailDetails" -H 'content-type: application/proto' \
    --data-binary @"$TMP/fd.bin")"
  if [ "$got_http" != "$want_http" ]; then
    all_codes=0; bad "unary code $c HTTP (got $got_http want $want_http)"
  elif ! grep -qE "\"code\"[[:space:]]*:[[:space:]]*\"$name\"" "$TMP/fd-out.bin"; then
    all_codes=0; bad "unary code $c body (want name $name; got $(head -c 90 "$TMP/fd-out.bin"))"
  fi
done
[ "$all_codes" = 1 ] && ok "unary: all 16 codes (HTTP status + JSON code name)"

# ---------------------------------------------------------------------------
# 2. All 16 Connect codes: server-stream (HTTP 200 + END-frame error name)
# ---------------------------------------------------------------------------
all_scodes=1
for c in $(seq 1 16); do
  gen_stream_fail 0 "$c" > "$TMP/sf.bin"
  gen_frame "$TMP/sf.bin" "$TMP/sf-env.bin"
  got_http="$(curl -s -o "$TMP/sf-out.bin" -w '%{http_code}' -X POST \
    "$BASE/$SVC/StreamFail" -H 'content-type: application/connect+proto' \
    --data-binary @"$TMP/sf-env.bin")"
  read -r data end name <<< "$(frame_stats "$TMP/sf-out.bin")"
  if [ "$got_http" != "200" ]; then
    all_scodes=0; bad "stream code $c HTTP (got $got_http want 200)"
  elif [ "$end" != "1" ] || [ "$name" != "$(code_name "$c")" ]; then
    all_scodes=0; bad "stream code $c END (end=$end name=$name want $(code_name "$c"))"
  fi
done
[ "$all_scodes" = 1 ] && ok "stream: all 16 codes (HTTP 200 + END-frame error)"

# ---------------------------------------------------------------------------
# 3. Stream boundaries: 0 / N data frames, error before/after frames
# ---------------------------------------------------------------------------
# Count 0 -> clean END (impl may default to 3; must not error).
gen_count 0 > "$TMP/c0-in.bin"; gen_frame "$TMP/c0-in.bin" "$TMP/c0.bin"
curl -s -o "$TMP/c0-out.bin" -X POST "$BASE/$SVC/Count" \
  -H 'content-type: application/connect+proto' --data-binary @"$TMP/c0.bin"
read -r d0 e0 n0 <<< "$(frame_stats "$TMP/c0-out.bin")"
if [ "$e0" = "1" ] && [ -z "$n0" ]; then ok "boundary: Count 0 -> clean END ($d0 data frames)"
else bad "boundary: Count 0 (data=$d0 end=$e0 name=$n0)"; fi

gen_count 5 > "$TMP/c5-in.bin"; gen_frame "$TMP/c5-in.bin" "$TMP/c5.bin"
curl -s -o "$TMP/c5-out.bin" -X POST "$BASE/$SVC/Count" \
  -H 'content-type: application/connect+proto' --data-binary @"$TMP/c5.bin"
read -r d5 e5 n5 <<< "$(frame_stats "$TMP/c5-out.bin")"
if [ "$d5" = "5" ] && [ "$e5" = "1" ] && [ -z "$n5" ]; then ok "boundary: Count 5 -> 5 frames + clean END"
else bad "boundary: Count 5 (data=$d5 end=$e5 name=$n5)"; fi

for eb in 0 3; do
  gen_stream_fail "$eb" 13 > "$TMP/sfe.bin"
  gen_frame "$TMP/sfe.bin" "$TMP/sfe-env.bin"
  curl -s -o "$TMP/sfe-out.bin" -X POST "$BASE/$SVC/StreamFail" \
    -H 'content-type: application/connect+proto' --data-binary @"$TMP/sfe-env.bin"
  read -r de ee ne <<< "$(frame_stats "$TMP/sfe-out.bin")"
  if [ "$de" = "$eb" ] && [ "$ee" = "1" ] && [ "$ne" = "internal" ]; then
    ok "boundary: StreamFail emitBefore=$eb -> $eb frames + END error"
  else bad "boundary: StreamFail emitBefore=$eb (data=$de end=$ee name=$ne)"; fi
done

# ---------------------------------------------------------------------------
# 4. Unexpected requests
# ---------------------------------------------------------------------------
req_status() { # <expected> <name> <curl args...>
  local want="$1" name="$2"; shift 2
  local code
  code="$(curl -s -o "$TMP/u.bin" -w '%{http_code}' "$@")"
  if [ "$code" = "$want" ]; then ok "$name ($code)"; else bad "$name (got $code want $want)"; fi
}

req_status 405 "unexpected: GET on unary path" -X GET "$BASE/$SVC/Echo" \
  -H 'content-type: application/proto'
req_status 404 "unexpected: unknown path" -X POST "$BASE/$SVC/Nope" \
  -H 'content-type: application/proto' --data-binary ''
# Unknown codec / wrong shape still -> 415.
req_status 415 "unexpected: unsupported codec" -X POST "$BASE/$SVC/Echo" \
  -H 'content-type: application/xml' --data-binary '{}'
req_status 415 "unexpected: stream JSON on unary method" -X POST "$BASE/$SVC/Echo" \
  -H 'content-type: application/connect+json' --data-binary '{}'
req_status 415 "unexpected: unary JSON on stream method" -X POST "$BASE/$SVC/Count" \
  -H 'content-type: application/json' --data-binary '{}'
req_status 501 "unexpected: bad protocol-version (unary)" -X POST "$BASE/$SVC/Echo" \
  -H 'content-type: application/proto' -H 'connect-protocol-version: 999' --data-binary ''
req_status 501 "unexpected: bad protocol-version (stream)" -X POST "$BASE/$SVC/Count" \
  -H 'content-type: application/connect+proto' -H 'connect-protocol-version: 999' --data-binary ''
printf '\x0a\x02hi' > "$TMP/echo.bin"
req_status 501 "unexpected: unknown content-encoding" -X POST "$BASE/$SVC/Echo" \
  -H 'content-type: application/proto' -H 'content-encoding: br' --data-binary @"$TMP/echo.bin"

# stream with zero / two enveloped frames -> HTTP 200 + END code 12.
curl -s -o "$TMP/zf.bin" -X POST "$BASE/$SVC/Count" \
  -H 'content-type: application/connect+proto' --data-binary ''
read -r dz ez nz <<< "$(frame_stats "$TMP/zf.bin")"
if [ "$ez" = "1" ] && [ "$nz" = "unimplemented" ] && [ "$dz" = "0" ]; then
  ok "unexpected: stream 0 frames -> END unimplemented"
else bad "unexpected: stream 0 frames (data=$dz end=$ez name=$nz)"; fi

gen_count 1 > "$TMP/one.bin"; gen_frame "$TMP/one.bin" "$TMP/one-env.bin"
cat "$TMP/one-env.bin" "$TMP/one-env.bin" > "$TMP/two-env.bin"
curl -s -o "$TMP/tf.bin" -X POST "$BASE/$SVC/Count" \
  -H 'content-type: application/connect+proto' --data-binary @"$TMP/two-env.bin"
read -r dt et nt <<< "$(frame_stats "$TMP/tf.bin")"
if [ "$et" = "1" ] && [ "$nt" = "unimplemented" ] && [ "$dt" = "0" ]; then
  ok "unexpected: stream 2 frames -> END unimplemented"
else bad "unexpected: stream 2 frames (data=$dt end=$et name=$nt)"; fi

# ---------------------------------------------------------------------------
# 5. Malformed envelopes
# ---------------------------------------------------------------------------
# truncated frame header (3 bytes)
printf '\x00\x00\x00' > "$TMP/th.bin"
curl -s -o "$TMP/th-out.bin" -X POST "$BASE/$SVC/Count" \
  -H 'content-type: application/connect+proto' --data-binary @"$TMP/th.bin"
read -r dth eth nth <<< "$(frame_stats "$TMP/th-out.bin")"
if [ "$eth" = "1" ] && [ "$nth" = "internal" ]; then ok "malformed: truncated frame header -> END internal"
else bad "malformed: truncated frame header (end=$eth name=$nth)"; fi

# frame declares 10 bytes, supplies 4
{ byte 0; byte 0; byte 0; byte 0; byte 10; byte 0x08; byte 0x01; byte 0x02; byte 0x03; } > "$TMP/tf.bin"
curl -s -o "$TMP/tf-out.bin" -X POST "$BASE/$SVC/Count" \
  -H 'content-type: application/connect+proto' --data-binary @"$TMP/tf.bin"
read -r dtf etf ntf <<< "$(frame_stats "$TMP/tf-out.bin")"
if [ "$etf" = "1" ] && [ "$ntf" = "internal" ]; then ok "malformed: truncated frame -> END internal"
else bad "malformed: truncated frame (end=$etf name=$ntf)"; fi

# oversize frame (declares 5 MiB) -> code 8
{ byte 0; byte 0; byte 80; byte 0; byte 0; byte 0x08; byte 0x01; } > "$TMP/of.bin"
curl -s -o "$TMP/of-out.bin" -X POST "$BASE/$SVC/Count" \
  -H 'content-type: application/connect+proto' --data-binary @"$TMP/of.bin"
read -r dof eof nof <<< "$(frame_stats "$TMP/of-out.bin")"
if [ "$eof" = "1" ] && [ "$nof" = "resource_exhausted" ]; then ok "malformed: oversize frame -> END resource_exhausted"
else bad "malformed: oversize frame (end=$eof name=$nof)"; fi

# compressed flag set, payload not gzip -> code 13 (never raw bytes)
{ byte 1; byte 0; byte 0; byte 0; byte 3; byte 0x08; byte 0x01; byte 0x02; } > "$TMP/gz.bin"
curl -s -o "$TMP/gz-out.bin" -X POST "$BASE/$SVC/Count" \
  -H 'content-type: application/connect+proto' --data-binary @"$TMP/gz.bin"
read -r dgz egz ngz <<< "$(frame_stats "$TMP/gz-out.bin")"
if [ "$egz" = "1" ] && [ "$ngz" = "internal" ]; then ok "malformed: corrupt gzip flag -> END internal"
else bad "malformed: corrupt gzip flag (end=$egz name=$ngz)"; fi

# ---------------------------------------------------------------------------
# 6. Limits: oversize request -> code 8 (HTTP 429)
# ---------------------------------------------------------------------------
head -c 5000000 /dev/zero | tr '\0' 'x' > "$TMP/big-input.txt"
{ byte 0x0a; byte $(( (5000000 >> 24) & 255 )); byte $(( (5000000 >> 16) & 255 )); \
  byte $(( (5000000 >> 8) & 255 )); byte $(( 5000000 & 255 )); cat "$TMP/big-input.txt"; } > "$TMP/big-req.bin"
got_http="$(curl -s -o "$TMP/big-out.bin" -w '%{http_code}' -X POST "$BASE/$SVC/Echo" \
  -H 'content-type: application/proto' --data-binary @"$TMP/big-req.bin")"
if [ "$got_http" = "429" ] && grep -qE "\"code\"[[:space:]]*:[[:space:]]*\"resource_exhausted\"" "$TMP/big-out.bin"; then
  ok "limits: oversize request -> 429 resource_exhausted"
else bad "limits: oversize request (got $got_http; $(head -c 80 "$TMP/big-out.bin"))"; fi

# ---------------------------------------------------------------------------
# 7. Metadata
# ---------------------------------------------------------------------------
# multi-value request header must not crash (fully asserted by the official suite)
printf '\x0a\x02hi' > "$TMP/em.bin"
got_http="$(curl -s -o "$TMP/em-out.bin" -w '%{http_code}' -X POST "$BASE/$SVC/EchoMeta" \
  -H 'content-type: application/proto' -H 'x-test: v1' -H 'x-test: v2' \
  --data-binary @"$TMP/em.bin")"
if [ "$got_http" = "200" ] && grep -aq 'hi' "$TMP/em-out.bin"; then ok "metadata: multi-value request header accepted"
else bad "metadata: multi-value request header (got $got_http)"; fi

# unary trailer -> trailer-* response header
printf '\x0a\x01x' > "$TMP/et.bin"
curl -s -D "$TMP/et-hdrs.txt" -o /dev/null -X POST "$BASE/$SVC/EchoTrailer" \
  -H 'content-type: application/proto' --data-binary @"$TMP/et.bin"
if grep -qi '^trailer-x-trl: unary-x' "$TMP/et-hdrs.txt"; then ok "metadata: unary trailer-* header"
else bad "metadata: unary trailer-* header"; fi

# stream END metadata
gen_count 2 > "$TMP/ct-in.bin"; gen_frame "$TMP/ct-in.bin" "$TMP/ct.bin"
curl -s -o "$TMP/ct-out.bin" -X POST "$BASE/$SVC/CountTrailer" \
  -H 'content-type: application/connect+proto' --data-binary @"$TMP/ct.bin"
if grep -aq 'x-ctrailer' "$TMP/ct-out.bin"; then ok "metadata: stream END metadata (x-ctrailer)"
else bad "metadata: stream END metadata missing"; fi

# ---------------------------------------------------------------------------
# 7b. JSON codec (proto3 JSON)
# ---------------------------------------------------------------------------
# unary JSON round-trip: {"input":"hi"} -> {"output":"echo:hi"}
got_http="$(curl -s -o "$TMP/js.bin" -w '%{http_code}' -X POST "$BASE/$SVC/Echo" \
  -H 'content-type: application/json' --data-binary '{"input":"hi"}')"
if [ "$got_http" = "200" ] && grep -aq 'echo:hi' "$TMP/js.bin"; then ok "json: unary round-trip"
else bad "json: unary round-trip (got $got_http; $(head -c 80 "$TMP/js.bin"))"; fi
# JSON response content-type
ctjson="$(curl -s -D - -o /dev/null -X POST "$BASE/$SVC/Echo" \
  -H 'content-type: application/json' --data-binary '{"input":"hi"}' | tr -d '\r' | grep -i '^content-type:' | head -1)"
case "$ctjson" in *application/json*) ok "json: response content-type application/json";; *) bad "json: response content-type ($ctjson)";; esac
# unary JSON error body code
curl -s -o "$TMP/jerr.bin" -w '%{http_code}' -X POST "$BASE/$SVC/FailDetails" \
  -H 'content-type: application/json' --data-binary '{"code":8,"message":"limited","detailType":"t/x","detailText":"d"}' > "$TMP/jerr.code"
if [ "$(cat "$TMP/jerr.code")" = "429" ] && grep -aq 'resource_exhausted' "$TMP/jerr.bin"; then ok "json: unary error 429 + code"
else bad "json: unary error ($(cat "$TMP/jerr.code"); $(head -c 80 "$TMP/jerr.bin"))"; fi
# stream JSON: envelope frame carrying the JSON request message
gen_frame_json() { # <json-bytes> -> stdout (one framed envelope)
  local n; n=$(printf '%s' "$1" | wc -c)
  byte 0; byte $(( (n >> 24) & 255 )); byte $(( (n >> 16) & 255 )); byte $(( (n >> 8) & 255 )); byte $(( n & 255 )); printf '%s' "$1"
}
gen_frame_json '{"count":2}' > "$TMP/cj.bin"
curl -s -o "$TMP/cj-out.bin" -X POST "$BASE/$SVC/Count" \
  -H 'content-type: application/connect+json' --data-binary @"$TMP/cj.bin"
read -r dcj ecj ncj <<< "$(frame_stats "$TMP/cj-out.bin")"
if [ "$dcj" = "2" ] && [ "$ecj" = "1" ] && [ -z "$ncj" ]; then ok "json: stream 2 frames + clean END"
else bad "json: stream (data=$dcj end=$ecj name=$ncj)"; fi
if grep -aq '"index"' "$TMP/cj-out.bin"; then ok "json: stream frame is JSON"; else bad "json: stream frame is JSON"; fi

# ---------------------------------------------------------------------------
# 8. HTTP version negotiation
# ---------------------------------------------------------------------------
if curl --help all 2>/dev/null | grep -q 'http2-prior-knowledge'; then
  h1="$(curl -s -o /dev/null -w '%{http_version}' --http1.1 -X POST \
    "$BASE/$SVC/Echo" -H 'content-type: application/proto' --data-binary @"$TMP/echo.bin")"
  if [ "$h1" = "1.1" ]; then ok "http-version: --http1.1 negotiates 1.1"
  else bad "http-version: --http1.1 got $h1"; fi
  if [[ ",$SERVER_PROTOS," == *",h2c,"* || ",$SERVER_PROTOS," == *",h2,"* ]]; then
    h2="$(curl -s -o /dev/null -w '%{http_version}' --http2-prior-knowledge -X POST \
      "$BASE/$SVC/Echo" -H 'content-type: application/proto' --data-binary @"$TMP/echo.bin")"
    if [ "$h2" = "2" ]; then ok "http-version: --http2-prior-knowledge negotiates 2"
    else bad "http-version: h2 prior-knowledge got $h2"; fi
  else
    echo "  skip http-version h2c (server advertises $SERVER_PROTOS)"
  fi
else
  echo "  skip http-version (curl lacks --http2-prior-knowledge)"
fi

# ---- EchoBytes / Empty / Sleep deadline (kept from the original oracle) ----
printf '\x0a\x04\x00\x01\x02\xff' > "$TMP/eb.bin"
curl -s -o "$TMP/eb-out.bin" -X POST "$BASE/$SVC/EchoBytes" \
  -H 'content-type: application/proto' --data-binary @"$TMP/eb.bin"
if [ "$(od -An -tx1 "$TMP/eb-out.bin" | tr -d ' \n')" = "0a04000102ff" ]; then ok "EchoBytes round-trip"
else bad "EchoBytes round-trip"; fi

req_status 200 "Empty 200" -X POST "$BASE/$SVC/Empty" -H 'content-type: application/proto' --data-binary ''
req_status 504 "Sleep deadline 504" -X POST "$BASE/$SVC/Sleep" \
  -H 'content-type: application/proto' -H 'connect-timeout-ms: 50' --data-binary $'\x08\xc8\x01'

echo
echo "=== raw-wire: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
