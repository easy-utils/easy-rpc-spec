#!/bin/bash
# Run the Go conformance client against $EASY_RPC_BASE. Exit 0 => PASS.
set -u
EASY_RPC_BASE="${EASY_RPC_BASE:-http://127.0.0.1:18888}"
export EASY_RPC_BASE
export EASY_RPC_TRANSPORT="${EASY_RPC_TRANSPORT:-std}"
if ( cd /home/user/easy-utils/easy-rpc-go && go run ./cmd/conformance-client ) >/tmp/opencode/matrix/cli-go.log 2>&1; then
  echo "PASS"
else
  echo "FAIL"; tail -20 /tmp/opencode/matrix/cli-go.log; exit 1
fi
