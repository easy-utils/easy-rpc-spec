#!/bin/bash
# Run the Kotlin conformance client against $EASY_RPC_BASE. Exit 0 => PASS.
set -u
EASY_RPC_BASE="${EASY_RPC_BASE:-http://127.0.0.1:18888}"
export EASY_RPC_BASE
export EASY_RPC_TRANSPORT="${EASY_RPC_TRANSPORT:-}"
if ( cd /home/user/easy-utils/easy-rpc-kotlin && gradle test --console=plain -q >/tmp/opencode/matrix/cli-kotlin.log 2>&1 ); then
  echo "PASS"
else
  echo "FAIL"; tail -20 /tmp/opencode/matrix/cli-kotlin.log; exit 1
fi
