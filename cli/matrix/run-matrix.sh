#!/bin/bash
# easy-rpc interop matrix: (client x transport) x (server x protocol-capability).
#
# Each server runs on ONE port. Capabilities:
#   go/rust/python : h1 + h2c   (net/http Protocols / hyper auto / hypercorn)
#   ts             : h1 only    (Node cannot mux h1+h2c on one socket)
# A client transport declares the protocol it speaks (h1|h2|any); it is SKIPped
# (N/A) when the server cannot serve that protocol, and run otherwise.
#
# Output: matrix.md
set -u
cd "$(dirname "$0")"
MATRIX=/tmp/opencode/matrix
mkdir -p "$MATRIX"

CLIENTS=(go ts rust python dart kotlin csharp swift)
SERVERS=(go rust python ts)
declare -A SERVER_PROTOS=( [go]="h1,h2c" [rust]="h1,h2c" [python]="h1,h2c" [ts]="h1" )

# client transports, each "name:proto" (proto = h1 | h2 | any).
declare -A CLIENT_TRANSPORTS=(
  [ts]="fetch:any node:h2 h1:h1 auto:any"
  [go]="std:any auto:any"
  [rust]="reqwest:any hyper:h1"
  [python]="std:any"
  [dart]="io:h1 http2:h2"
  [kotlin]="okhttp:any cio:h1"
  [csharp]="h1:h1 h2:h2"
  [swift]="urlsession:any ahc:h2"
)
declare -A CLI=( [go]=cli-go.sh [ts]=cli-ts.sh [rust]=cli-rust.sh [python]=cli-python.sh [dart]=cli-dart.sh [kotlin]=cli-kotlin.sh [csharp]=cli-csharp.sh [swift]=cli-swift.sh )
declare -A SRV=( [go]=srv-go.sh [ts]=srv-ts.sh [rust]=srv-rust.sh [python]=srv-python.sh )

declare -A RESULT
for c in "${CLIENTS[@]}"; do for spec in ${CLIENT_TRANSPORTS[$c]}; do for s in "${SERVERS[@]}"; do RESULT["$c/${spec%%:*}|$s"]="-"; done; done; done

proto_ok() { # <transport-proto> <server-protos-csv>
  local t="$1" sp="$2"
  [ "$t" = "any" ] && return 0
  case ",$sp," in *",$t,"*) return 0;; esac
  [ "$t" = "h2" ] && case ",$sp," in *",h2c,"*) return 0;; esac
  return 1
}

echo "[matrix] prebuild" >&2
( cd /home/user/easy-utils/easy-rpc-go && go build -o "$MATRIX/srv-go" ./cmd/conformance-server ) 2>/dev/null || true
( cd /home/user/easy-utils/easy-rpc-ts && npm run build >/dev/null 2>&1 ) || true

PORT=21000
for SERVER in "${SERVERS[@]}"; do
  P=$PORT; PORT=$((PORT+1))
  echo "== server=$SERVER (${SERVER_PROTOS[$SERVER]}) port=$P ==" >&2
  if ! SERVER_PROTO="h1" PORT="$P" "./${SRV[$SERVER]}" start "$P"; then
    for c in "${CLIENTS[@]}"; do for spec in ${CLIENT_TRANSPORTS[$c]}; do RESULT["$c/${spec%%:*}|$SERVER"]="ERR"; done; done
    continue
  fi
  for CLIENT in "${CLIENTS[@]}"; do
    for spec in ${CLIENT_TRANSPORTS[$CLIENT]}; do
      TRANSPORT="${spec%%:*}"; CP="${spec##*:}"
      KEY="$CLIENT/$TRANSPORT"
      if ! proto_ok "$CP" "${SERVER_PROTOS[$SERVER]}"; then RESULT["$KEY|$SERVER"]="N/A"; continue; fi
      if EASY_RPC_BASE="http://127.0.0.1:$P" EASY_RPC_TRANSPORT="$TRANSPORT" \
           "./${CLI[$CLIENT]}" >/dev/null 2>&1; then
        RESULT["$KEY|$SERVER"]="PASS"
      else
        RESULT["$KEY|$SERVER"]="FAIL"
        echo "  - $CLIENT[$TRANSPORT] vs $SERVER: FAIL" >&2
      fi
    done
  done
  "./${SRV[$SERVER]}" stop
done

{
  printf "| client / transport | "
  for s in "${SERVERS[@]}"; do printf "%-6s | " "$s"; done
  printf "\n|"
  for s in "${SERVERS[@]}"; do printf "%s|" "------:"; done
  printf "\n"
  for c in "${CLIENTS[@]}"; do
    for spec in ${CLIENT_TRANSPORTS[$c]}; do
      t="${spec%%:*}"
      printf "| **%s** \`%s\` | " "$c" "$t"
      for s in "${SERVERS[@]}"; do printf "%-6s | " "${RESULT["$c/$t|$s"]}"; done
      printf "\n"
    done
  done
} > matrix.md

echo "=== matrix.md ==="
cat matrix.md
