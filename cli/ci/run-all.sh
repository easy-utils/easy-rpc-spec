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
# Usage:  ./run-all.sh [lang...]     (default: all languages)
# Exit 0 => everything green.
set -u
cd "$(dirname "$0")/../.."
SPEC_ROOT="$(pwd)"
EASY_UTILS="$(cd .. && pwd)"
SVC="supervisorctl -c /opt/tools/etc/supervisord.conf"

PASS=(); FAIL=(); SKIP=()
record() { # <status> <name>
  case "$1" in
    pass) PASS+=("$2"); echo "ok   $2" ;;
    fail) FAIL+=("$2"); echo "FAIL $2" ;;
    skip) SKIP+=("$2"); echo "skip $2" ;;
  esac
}
run() { # <name> <cmd...>
  local name="$1"; shift
  if "$@" >/tmp/opencode/run-all-"$name".log 2>&1; then record pass "$name"
  else record fail "$name"; tail -5 /tmp/opencode/run-all-"$name".log; fi
}

want() { # is this language selected?
  [ "$#" -eq 0 ] && return 0
  local l; for l in "$@"; do [ "$l" = "$1" ] && return 0; done
  return 1
}
LANGS=("$@")
sel() { want "${LANGS[@]}" "$1"; }

# ---- conformance servers (supervisor-managed; no ad-hoc daemons) ----
for srv in conformance-go conformance-rust conformance-python; do
  $SVC status "$srv" 2>/dev/null | grep -q RUNNING || $SVC start "$srv" >/dev/null 2>&1
done
sleep 0.5
for port in 18888 18889 18887; do
  curl -s -m 2 "http://127.0.0.1:$port/v1/health" >/dev/null || echo "warn: conformance server on :$port not up" >&2
done

# ---- per-language suites ----
if sel ts; then
  run ts "env" "PATH=$PATH" bash -c "cd '$EASY_UTILS/easy-rpc-ts' && npx vitest run --reporter=basic"
fi
if sel go; then
  run go "env" "PATH=$PATH" bash -c "cd '$EASY_UTILS/easy-rpc-go' && go vet ./... && go test ./...'"
fi
if sel rust; then
  run rust "env" "PATH=$PATH" bash -c "cd '$EASY_UTILS/easy-rpc-rust' && cargo test"
fi
if sel python; then
  run python "env" "PATH=$PATH" bash -c "cd '$EASY_UTILS/easy-rpc-python' && python3 tests/errors_test.py && python3 tests/connect_test.py && python3 tests/stream_timing.py && EASY_RPC_BASE=http://127.0.0.1:18888 python3 tests/interop.py"
fi
if sel dart; then
  if command -v dart >/dev/null 2>&1; then
    run dart "env" "PATH=$PATH" bash -c "cd '$EASY_UTILS/easy-rpc-dart' && dart test"
  else record skip "dart (no toolchain)"; fi
fi
if sel kotlin; then
  if command -v gradle >/dev/null 2>&1; then
    run kotlin "env" "PATH=$PATH" "JAVA_HOME=/opt/tools/mise/installs/java/17.0.2" bash -c "cd '$EASY_UTILS/easy-rpc-kotlin' && gradle test"
  else record skip "kotlin (no toolchain)"; fi
fi
if sel csharp; then
  if [ -x /tmp/opencode/dotnetw/dotnet ]; then
    run csharp "env" "DOTNET_ROOT=/tmp/opencode/dotnetw" bash -c "cd '$EASY_UTILS/easy-rpc-csharp' && /tmp/opencode/dotnetw/dotnet test tests/tests.csproj -c Release"
  else record skip "csharp (no toolchain)"; fi
fi
if sel swift; then
  if command -v swift >/dev/null 2>&1; then
    run swift "env" "PATH=$PATH" bash -c "cd '$EASY_UTILS/easy-rpc-swift' && swift test"
    # interop against all three conformance servers
    for port in 18888 18889 18887; do
      run "swift-interop-$port" "env" "PATH=$PATH" "EASY_RPC_BASE=http://127.0.0.1:$port" bash -c "cd '$EASY_UTILS/easy-rpc-swift' && swift test --filter InteropTests"
    done
  else record skip "swift (no toolchain)"; fi
fi

# ---- cross-language interop: every client against every server ----
if sel matrix; then
  for port in 18888 18889 18887; do
    run "go-client-vs-$port" env "EASY_RPC_BASE=http://127.0.0.1:$port" bash -c \
      "cd '$EASY_UTILS/easy-rpc-go' && go run ./cmd/conformance-client"
  done
fi

# ---- golden + compile-matrix ----
if sel golden; then
  run golden "env" "PATH=/tmp/opencode/bin:$PATH" bash -c "'$SPEC_ROOT/cli/golden/gen-golden.sh' && EASYRPC_BIN=/tmp/opencode/bin '$SPEC_ROOT/cli/golden/compile-matrix.sh'"
fi

echo
echo "=== run-all: ${#PASS[@]} passed, ${#FAIL[@]} failed, ${#SKIP[@]} skipped ==="
[ "${#FAIL[@]}" -eq 0 ]
