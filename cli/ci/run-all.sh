#!/bin/bash
# Local CI orchestrator: run every language's test suite + the golden /
# compile-matrix checks + cross-language interop, in one command.
#
# Conformance servers are managed by supervisord (see ~/HOME_SERVICES.md):
#   conformance-go     :18888   (h1 + h2c)
#   conformance-rust   :18889   (h1 + h2c)
#   conformance-python :18887   (h1 + h2c, hypercorn)
# No ad-hoc background processes are started by this script.
#
# Usage:  ./run-all.sh [lang...]     (default: all)
#         langs: ts go rust python dart kotlin csharp swift matrix
#                rawwire h2 h3 vectors golden
# Exit 0 => everything green.
set -u
cd "$(dirname "$0")/../.."
SPEC_ROOT="$(pwd)"
EASY_UTILS="$(cd .. && pwd)"
export PATH="/home/user/flutter/bin:/opt/tools/mise/installs/gradle/latest/gradle-9.7.0/bin:/tmp/opencode/bin:$PATH"
export JAVA_HOME=/opt/tools/mise/installs/java/17.0.2
export DOTNET_ROOT=/tmp/opencode/dotnetw
SVC="supervisorctl -c /opt/tools/etc/supervisord.conf"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; tail -n 5 "/tmp/opencode/run-all-$1.log" 2>/dev/null; }
skip() { SKIP=$((SKIP+1)); echo "skip $1"; }

# run <name> <dir> <command...> — cd into <dir> and run; log to /tmp/opencode.
run() {
  local name="$1" dir="$2"; shift 2
  if ( cd "$dir" && "$@" ) >"/tmp/opencode/run-all-$name.log" 2>&1; then ok "$name"
  else bad "$name"; fi
}

# withenv <VAR=VAL>... -- <name> <dir> <command...>: run with env prefix.
want_lang() {
  [ $# -eq 0 ] && return 0
  local l; for l in $LANGS; do [ "$l" = "$1" ] && return 0; done
  return 1
}
LANGS="${*:-}"

# ---- conformance servers (supervisor-managed; no ad-hoc daemons) ----
for srv in conformance-go conformance-rust conformance-python; do
  $SVC status "$srv" 2>/dev/null | grep -q RUNNING || $SVC start "$srv" >/dev/null 2>&1
done
sleep 0.5
for port in 18888 18889 18887; do
  curl -s -m 2 "http://127.0.0.1:$port/easyrpc.conformance.v1.ConformanceService/Health" >/dev/null \
    || echo "warn: conformance server on :$port not up" >&2
done

# ---- per-language suites ----
if want_lang ts; then
  run ts "$EASY_UTILS/easy-rpc-ts" npx vitest run --reporter=basic
fi
if want_lang go; then
  if ( cd "$EASY_UTILS/easy-rpc-go" && go vet ./... && go test ./... ) >/tmp/opencode/run-all-go.log 2>&1; then ok go; else bad go; fi
fi
if want_lang rust; then
  run rust "$EASY_UTILS/easy-rpc-rust" cargo test
fi
if want_lang python; then
  if ( cd "$EASY_UTILS/easy-rpc-python" \
       && python3 tests/errors_test.py && python3 tests/connect_test.py \
       && python3 tests/stream_timing.py \
       && EASY_RPC_BASE=http://127.0.0.1:18888 python3 tests/interop.py ) >/tmp/opencode/run-all-python.log 2>&1
  then ok python; else bad python; fi
fi
if want_lang dart; then
  if command -v dart >/dev/null 2>&1; then
    run dart "$EASY_UTILS/easy-rpc-dart" dart test
  else skip "dart (no toolchain)"; fi
fi
if want_lang kotlin; then
  if command -v gradle >/dev/null 2>&1; then
    run kotlin "$EASY_UTILS/easy-rpc-kotlin" gradle test
  else skip "kotlin (no toolchain)"; fi
fi
if want_lang csharp; then
  if [ -x /tmp/opencode/dotnetw/dotnet ]; then
    run csharp "$EASY_UTILS/easy-rpc-csharp" /tmp/opencode/dotnetw/dotnet test tests/tests.csproj -c Release
  else skip "csharp (no toolchain)"; fi
fi
if want_lang swift; then
  if command -v swift >/dev/null 2>&1; then
    run swift "$EASY_UTILS/easy-rpc-swift" swift test
    for port in 18888 18889 18887; do
      if ( cd "$EASY_UTILS/easy-rpc-swift" && EASY_RPC_BASE="http://127.0.0.1:$port" swift test --filter InteropTests ) \
        >"/tmp/opencode/run-all-swift-interop-$port.log" 2>&1
      then ok "swift-interop-$port"; else bad "swift-interop-$port"; fi
    done
  else skip "swift (no toolchain)"; fi
fi

# ---- cross-language interop: go client against every server ----
if want_lang matrix; then
  for port in 18888 18889 18887; do
    if ( cd "$EASY_UTILS/easy-rpc-go" && EASY_RPC_BASE="http://127.0.0.1:$port" go run ./cmd/conformance-client ) \
      >"/tmp/opencode/run-all-go-client-$port.log" 2>&1
    then ok "go-client-vs-$port"; else bad "go-client-vs-$port"; fi
  done
fi

# ---- raw-wire oracle (curl-only; independent of every implementation) ----
if want_lang rawwire; then
  # go/rust/python advertise h1+h2c; ts-http is h1-only.
  if "$SPEC_ROOT/cli/raw-wire.sh" "http://127.0.0.1:18888" "h1,h2c" >"/tmp/opencode/run-all-rawwire-18888.log" 2>&1
  then ok "raw-wire-vs-18888"; else bad "raw-wire-vs-18888"; fi
  if "$SPEC_ROOT/cli/raw-wire.sh" "http://127.0.0.1:18889" "h1,h2c" >"/tmp/opencode/run-all-rawwire-18889.log" 2>&1
  then ok "raw-wire-vs-18889"; else bad "raw-wire-vs-18889"; fi
  if "$SPEC_ROOT/cli/raw-wire.sh" "http://127.0.0.1:18887" "h1,h2c" >"/tmp/opencode/run-all-rawwire-18887.log" 2>&1
  then ok "raw-wire-vs-18887"; else bad "raw-wire-vs-18887"; fi
  if "$SPEC_ROOT/cli/raw-wire.sh" "http://127.0.0.1:18899" "h1" >"/tmp/opencode/run-all-rawwire-18899.log" 2>&1
  then ok "raw-wire-vs-18899"; else bad "raw-wire-vs-18899"; fi
fi

# ---- h2 same-connection multiplexing oracle (h2 lib only) ----
if want_lang h2; then
  for port in 18888 18889 18887; do
    if python3 "$SPEC_ROOT/cli/h2-concurrent.py" 127.0.0.1 "$port" >"/tmp/opencode/run-all-h2-$port.log" 2>&1
    then ok "h2-concurrent-vs-$port"; else bad "h2-concurrent-vs-$port"; fi
  done
fi

# ---- h3/QUIC same-connection multiplexing oracle (aioquic only) ----
# The QUIC endpoint is caddy `tls internal` (IP-SAN self-signed, ALPN h2+h3)
# reverse-proxying the Go conformance server. A self-signed CA + bare IP works:
# point --ca at caddy's local root (see conformance-tls.Caddyfile).
if want_lang h3; then
  H3_HOST="${EASY_RPC_H3_HOST:-172.17.0.196}"
  H3_PORT="${EASY_RPC_H3_PORT:-18443}"
  H3_CA="${EASY_RPC_H3_CA:-/home/user/caddy-tls/data/caddy/pki/authorities/local/root.crt}"
  if [ -f "$H3_CA" ]; then
    if python3 "$SPEC_ROOT/cli/h3-concurrent.py" "$H3_HOST" "$H3_PORT" 6 --ca "$H3_CA" \
      >"/tmp/opencode/run-all-h3.log" 2>&1
    then ok "h3-concurrent-vs-$H3_HOST:$H3_PORT"; else bad "h3-concurrent-vs-$H3_HOST:$H3_PORT"; fi
  else
    skip "h3 (no CA at $H3_CA)"
  fi
fi

# ---- wire golden vectors (transport-independent protocol conformance) ----
if want_lang vectors; then
  okv=0; badv=0
  if ( cd "$EASY_UTILS/easy-rpc-ts" && npx vitest run tests/wire-vectors.test.ts ) >/tmp/opencode/run-all-vectors-ts.log 2>&1; then okv=$((okv+1)); else badv=$((badv+1)); bad "vectors-ts"; fi
  if ( cd "$EASY_UTILS/easy-rpc-go" && go test -run TestWireVectors . ) >/tmp/opencode/run-all-vectors-go.log 2>&1; then okv=$((okv+1)); else badv=$((badv+1)); bad "vectors-go"; fi
  if ( cd "$EASY_UTILS/easy-rpc-rust" && cargo test --test wire_vectors ) >/tmp/opencode/run-all-vectors-rust.log 2>&1; then okv=$((okv+1)); else badv=$((badv+1)); bad "vectors-rust"; fi
  if ( cd "$EASY_UTILS/easy-rpc-python" && python3 tests/wire_vectors_test.py ) >/tmp/opencode/run-all-vectors-python.log 2>&1; then okv=$((okv+1)); else badv=$((badv+1)); bad "vectors-python"; fi
  [ "$badv" -eq 0 ] && ok "vectors ($okv/4 languages)"
fi

# ---- golden + compile-matrix ----
if want_lang golden; then
  if ( "$SPEC_ROOT/cli/golden/gen-golden.sh" && EASYRPC_BIN=/tmp/opencode/bin "$SPEC_ROOT/cli/golden/compile-matrix.sh" ) \
    >/tmp/opencode/run-all-golden.log 2>&1
  then ok golden; else bad golden; fi
fi

echo
echo "=== run-all: $PASS passed, $FAIL failed, $SKIP skipped ==="
[ "$FAIL" -eq 0 ]
