#!/bin/bash
# Cross-language interop: run the Go conformance server in the background
# (setsid, detached) then run the TS generated-client tests against it, then
# stop the server.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO="$ROOT/../easy-rpc-go"
TS="$ROOT/../easy-rpc-ts"
PORT=18888
LOGFILE="/tmp/opencode/conformance-server.log"

echo "[interop] building go server..."
( cd "$GO" && go build -o /tmp/opencode/conformance-server ./cmd/conformance-server )

echo "[interop] starting go server (setsid) on :$PORT ..."
pkill -f conformance-server 2>/dev/null || true
sleep 0.5
setsid /tmp/opencode/conformance-server > "$LOGFILE" 2>&1 < /dev/null &
sleep 1.2

cleanup() {
  echo "[interop] stopping go server ..."
  pkill -f conformance-server 2>/dev/null || true
}
trap cleanup EXIT

echo "[interop] server pid: $(pgrep -f conformance-server | head -1)"
curl -s "http://127.0.0.1:$PORT/v1/health" -o /dev/null -w "health=%{http_code}\n"

echo "[interop] running TS interop tests..."
( cd "$TS" && npx vitest run tests/interop.test.ts )
