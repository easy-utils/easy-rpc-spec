#!/bin/bash
# Cross-language interop: run the Go conformance server (setsid) then run all
# available language clients against it. Add new languages as they land.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO="$ROOT/../easy-rpc-go"
TS="$ROOT/../easy-rpc-ts"
RUST="$ROOT/../easy-rpc-rust"
PYTHON="$ROOT/../easy-rpc-python"
DART="$ROOT/../easy-rpc-dart"
KOTLIN="$ROOT/../easy-rpc-kotlin"
CSHARP="$ROOT/../easy-rpc-csharp"
SWIFT="$ROOT/../easy-rpc-swift"
PORT=18888
BIN=/tmp/opencode/conformance-server
LOG=/tmp/opencode/conformance-server.log

echo "[interop] building go server..."
( cd "$GO" && go build -o "$BIN" ./cmd/conformance-server )

echo "[interop] starting go server (setsid) on :$PORT ..."
pkill -f conformance-server 2>/dev/null || true
sleep 0.5
setsid "$BIN" > "$LOG" 2>&1 < /dev/null &
sleep 1.2

cleanup() { echo "[interop] stopping go server..."; pkill -f conformance-server 2>/dev/null || true; }
trap cleanup EXIT

echo "[interop] health=$(curl -s "$HOST/v1/health" -o /dev/null -w '%{http_code}')"

echo "[interop] TS client..."
( cd "$TS" && npx vitest run tests/interop.test.ts )

echo "[interop] Rust client..."
( cd "$RUST" && cargo test --test interop )

echo "[interop] Python client..."
( cd "$PYTHON" && python3 tests/interop.py )

echo "[interop] Dart client..."
( cd "$DART" && dart test test/interop_test.dart )

echo "[interop] Kotlin client..."
( cd "$KOTLIN" && gradle test --console=plain -q )

echo "[interop] C# client..."
( cd "$CSHARP" && dotnet test tests/tests.csproj )

echo "[interop] Swift client..."
( cd "$SWIFT" && swift test )
