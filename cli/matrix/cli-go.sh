#!/bin/bash
# Run the Go conformance client against $EASY_RPC_BASE. Exit 0 => PASS.
set -u
EASY_RPC_BASE="${EASY_RPC_BASE:-http://127.0.0.1:18888}"
export EASY_RPC_BASE
if /tmp/opencode/matrix/cli-go; then echo "PASS"; else echo "FAIL"; exit 1; fi
