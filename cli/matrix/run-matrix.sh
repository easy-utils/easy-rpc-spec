#!/bin/bash
# easy-rpc 8x8 interop matrix: for each server language, start the conformance
# server on a dedicated port, run every language client against it, then stop.
# Produces a markdown table matrix.md.
set -u
cd "$(dirname "$0")"
MATRIX=/tmp/opencode/matrix
mkdir -p "$MATRIX"
BASE_PORT=21000

LANGS=(go ts rust python dart kotlin csharp swift)
declare -A SRV=( [go]=srv-go.sh [ts]=srv-ts.sh [rust]=srv-rust.sh [python]=srv-python.sh [dart]=srv-dart.sh [kotlin]=srv-kotlin.sh [csharp]=srv-csharp.sh [swift]=srv-swift.sh )
declare -A CLI=( [go]=cli-go.sh [ts]=cli-ts.sh [rust]=cli-rust.sh [python]=cli-python.sh [dart]=cli-dart.sh [kotlin]=cli-kotlin.sh [csharp]=cli-csharp.sh [swift]=cli-swift.sh )

# Build the Kotlin runtime classpath once (needed by srv-kotlin.sh).
if [ ! -s "$MATRIX/kotlin_cp.txt" ]; then
  find "$HOME/.gradle/caches/modules-2/files-2.1" -name '*.jar' | tr '\n' ':' > "$MATRIX/kotlin_cp.txt"
fi

# ---- pre-build all server artifacts once (avoids per-start races) ----
prebuild() {
  echo "[prebuild] go" >&2
  ( cd /home/user/easy-utils/easy-rpc-go && go build -o "$MATRIX/srv-go" ./cmd/conformance-server ) || echo "  go build failed" >&2
  echo "[prebuild] csharp" >&2
  ( cd /home/user/easy-utils/easy-rpc-csharp && dotnet build server/server.csproj >/dev/null 2>&1 ) || echo "  csharp build failed" >&2
  echo "[prebuild] kotlin" >&2
  ( cd /home/user/easy-utils/easy-rpc-kotlin && gradle compileKotlin --rerun-tasks >"$MATRIX/prebuild-kotlin.log" 2>&1 ) || echo "  kotlin build failed" >&2
  echo "[prebuild] done" >&2
}
prebuild

header() {
  printf "| client\\server | " > matrix.md
  for L in "${LANGS[@]}"; do printf "%-10s | " "$L" >> matrix.md; done
  printf "\n|" >> matrix.md
  for L in "${LANGS[@]}"; do printf "%s|" "----------:" >> matrix.md; done
  printf "\n" >> matrix.md
}

line_start() {
  printf "| **%s** | " "$1" >> matrix.md
}

fail_run() {
  echo "  - $CLIENT vs $SERVER: FAIL (see $MATRIX/cli-$CLIENT.log)" >&2
}

line_add() {
  printf "%-10s | " "$1" >> matrix.md
}

header

for SERVER in "${LANGS[@]}"; do
  PORT=$((BASE_PORT))
  BASE_PORT=$((BASE_PORT+1))
  echo "== server=$SERVER port=$PORT =="
  if ! PORT="$PORT" "./${SRV[$SERVER]}" start "$PORT" ; then
    echo "  !! could not start $SERVER server" >&2
    line_start "$SERVER"
    for _ in "${LANGS[@]}"; do line_add "ERR"; done
    printf "\n" >> matrix.md
    continue
  fi
  line_start "$SERVER"
  for CLIENT in "${LANGS[@]}"; do
    if EASY_RPC_BASE="http://127.0.0.1:$PORT" "./${CLI[$CLIENT]}" >/dev/null 2>&1; then
      line_add "PASS"
    else
      line_add "FAIL"
      fail_run
    fi
  done
  printf "\n" >> matrix.md
  "./${SRV[$SERVER]}" stop
done

echo "=== matrix.md ==="
cat matrix.md
