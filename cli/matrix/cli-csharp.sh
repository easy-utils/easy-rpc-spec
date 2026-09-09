#!/bin/bash
# Run the C# conformance client against $EASY_RPC_BASE. Exit 0 => PASS.
set -u
EASY_RPC_BASE="${EASY_RPC_BASE:-http://127.0.0.1:18888}"
export EASY_RPC_BASE
if ( cd /home/user/easy-utils/easy-rpc-csharp && rm -rf obj bin tests/obj tests/bin && dotnet test tests/tests.csproj >/tmp/opencode/matrix/cli-csharp.log 2>&1 ); then
  echo "PASS"
else
  echo "FAIL"; tail -20 /tmp/opencode/matrix/cli-csharp.log; exit 1
fi
