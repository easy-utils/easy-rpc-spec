#!/bin/bash
# easy-rpc interop matrix: each SERVER language (only Go/Python/Rust/TS provide
# servers; Dart/Kotlin/C#/Swift are client-only) starts a conformance server on
# a dedicated port, and ALL 8 language clients run against it. matrix.md is
# clients (rows) x servers (columns).
set -u
cd "$(dirname "$0")"
MATRIX=/tmp/opencode/matrix
mkdir -p "$MATRIX"
BASE_PORT=21000

CLIENTS=(go ts rust python dart kotlin csharp swift)
SERVERS=(go ts rust python)

declare -A CLI=( [go]=cli-go.sh [ts]=cli-ts.sh [rust]=cli-rust.sh [python]=cli-python.sh [dart]=cli-dart.sh [kotlin]=cli-kotlin.sh [csharp]=cli-csharp.sh [swift]=cli-swift.sh )
declare -A SRV=( [go]=srv-go.sh [ts]=srv-ts.sh [rust]=srv-rust.sh [python]=srv-python.sh )

prebuild() {
  echo "[prebuild] go" >&2
  ( cd /home/user/easy-utils/easy-rpc-go && go build -o "$MATRIX/srv-go" ./cmd/conformance-server ) || echo "  go build failed" >&2
  echo "[prebuild] done" >&2
}
prebuild

# result[<client>][<server>]=PASS|FAIL
reset_result() { for c in "${CLIENTS[@]}"; do for s in "${SERVERS[@]}"; do RESULT["$c|$s"]="-"; done; done; }
declare -A RESULT
reset_result

for SERVER in "${SERVERS[@]}"; do
  PORT=$BASE_PORT; BASE_PORT=$((BASE_PORT+1))
  echo "== server=$SERVER port=$PORT =="
  if ! PORT="$PORT" "./${SRV[$SERVER]}" start "$PORT"; then
    echo "  !! could not start $SERVER server" >&2
    for c in "${CLIENTS[@]}"; do RESULT["$c|$SERVER"]="ERR"; done
    continue
  fi
  for CLIENT in "${CLIENTS[@]}"; do
    if EASY_RPC_BASE="http://127.0.0.1:$PORT" "./${CLI[$CLIENT]}" >/dev/null 2>&1; then
      RESULT["$CLIENT|$SERVER"]="PASS"
    else
      RESULT["$CLIENT|$SERVER"]="FAIL"
      echo "  - $CLIENT vs $SERVER: FAIL (see $MATRIX/cli-$CLIENT.log)" >&2
    fi
  done
  "./${SRV[$SERVER]}" stop
done

# render
{
  printf "| client\\\\server | "
  for s in "${SERVERS[@]}"; do printf "%-8s | " "$s"; done
  printf "\n|"
  for s in "${SERVERS[@]}"; do printf "%s|" "---------:"; done
  printf "\n"
  for c in "${CLIENTS[@]}"; do
    printf "| **%s** | " "$c"
    for s in "${SERVERS[@]}"; do printf "%-8s | " "${RESULT["$c|$s"]}"; done
    printf "\n"
  done
} > matrix.md

echo "=== matrix.md ==="
cat matrix.md
