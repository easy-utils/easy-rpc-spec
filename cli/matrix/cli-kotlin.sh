#!/bin/bash
# Run the Kotlin conformance client against $EASY_RPC_BASE. Exit 0 => PASS.
set -u
EASY_RPC_BASE="${EASY_RPC_BASE:-http://127.0.0.1:18888}"
export EASY_RPC_BASE
export EASY_RPC_TRANSPORT="${EASY_RPC_TRANSPORT:-}"
GRADLE_BIN="${GRADLE_BIN:-/opt/tools/mise/installs/gradle/latest/gradle-9.7.0/bin/gradle}"
# The live-server interop lives in jvmTest; select the transport via
# EASY_RPC_TRANSPORT (okhttp | cio).
if ( cd /home/user/easy-utils/easy-rpc-kotlin && EASY_RPC_BASE="$EASY_RPC_BASE" EASY_RPC_TRANSPORT="$EASY_RPC_TRANSPORT"      "$GRADLE_BIN" jvmTest --tests 'easyrpc.InteropTest' --no-daemon --rerun-tasks >/tmp/opencode/matrix/cli-kotlin.log 2>&1 ); then
  echo "PASS"
else
  echo "FAIL"; tail -20 /tmp/opencode/matrix/cli-kotlin.log; exit 1
fi
