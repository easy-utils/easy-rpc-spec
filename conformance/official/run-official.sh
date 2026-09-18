#!/usr/bin/env bash
# Run the OFFICIAL ConnectRPC conformance suite against an easy-rpc server.
#
# Requires the upstream runner (`connectconformance`), built once from
# https://github.com/connectrpc/conformance:
#   git clone --depth 1 https://github.com/connectrpc/conformance /tmp/cconf
#   ( cd /tmp/cconf && go build -o /tmp/opencode/bin/connectconformance ./cmd/connectconformance )
#
# The server command reads a ServerCompatRequest from stdin and starts a server
# exposing the official connectrpc.conformance.v1.ConformanceService.
#
# Usage: official-server.sh <lang> [port-base]
#   lang: ts | go | rust | python
set -u
LANG_="${1:-ts}"
RUNNER="${CONNECTCONFORMANCE:-/tmp/opencode/bin/connectconformance}"
CONF="$(cd "$(dirname "$0")" && pwd)/configs/easy-rpc-server.yaml"
EU=/home/user/easy-utils

if [ ! -x "$RUNNER" ]; then echo "runner not found: $RUNNER (build it first)" >&2; exit 2; fi

case "$LANG_" in
  ts)   CMD=(node "$EU/easy-rpc-ts/dist/conformance/official-server.js");;
  go)   CMD=("$EU/easy-rpc-go/bin/conformance-official-server");;
  rust) CMD=("$EU/easy-rpc-rust/target/release/conformance_official_server");;
  python) CMD=(python3 "$EU/easy-rpc-python/conformance_official_server.py");;
  *) echo "unknown lang: $LANG_" >&2; exit 2;;
esac

echo "== official conformance: $LANG_ =="
exec "$RUNNER" --mode server --conf "$CONF" -- ${CMD[@]}
