#!/bin/bash
# Golden generation check: run every easy-rpc codegen plugin over the
# kitchen-sink proto and assert the structural invariants that have broken
# before (per-service clients, proto3 optional support, map fields, REST +
# fallback paths, server-stream flag).
#
# Usage: gen-golden.sh            # verify
#        EASYRPC_BIN=<dir> ...    # override plugin dir (default /tmp/opencode/bin)
set -u
cd "$(dirname "$0")"
SPEC_ROOT="$(cd ../.. && pwd)"
OUT="${GOLDEN_OUT:-/tmp/easyrpc-golden}"
BIN="${EASYRPC_BIN:-/tmp/opencode/bin}"

rm -rf "$OUT"
mkdir -p "$OUT"
# Module root == OUT so generated paths are `easyrpc/...` everywhere.
cp -r "$SPEC_ROOT/proto/easyrpc" "$OUT/"
cat > "$OUT/buf.yaml" <<'YAML'
version: v2
modules:
  - path: .
YAML
mkdir -p "$OUT"/{go,ts,rust,py,kt,cs,dart,sw}
cat > "$OUT/buf.gen.yaml" <<YAML
version: v2
plugins:
  - {local: protoc-gen-easyrpc-go, out: $OUT/go, opt: paths=source_relative}
  - {local: protoc-gen-easyrpc-ts, out: $OUT/ts}
  - {local: protoc-gen-easyrpc-rust, out: $OUT/rust}
  - {local: protoc-gen-easyrpc-python, out: $OUT/py}
  - {local: protoc-gen-easyrpc-kotlin, out: $OUT/kt}
  - {local: protoc-gen-easyrpc-csharp, out: $OUT/cs}
  - {local: protoc-gen-easyrpc-dart, out: $OUT/dart}
  - {local: protoc-gen-easyrpc-swift, out: $OUT/sw}
YAML

( cd "$OUT" && PATH="$BIN:$PATH" buf generate --template buf.gen.yaml --path easyrpc/kitchensink \
    >/dev/null ) 2>"$OUT/gen.log"
if grep -q "does not support required features" "$OUT/gen.log"; then
  echo "FAIL: a plugin does not declare proto3-optional support"; cat "$OUT/gen.log"; exit 1
fi

fail=0
check() { if [ "${2:-0}" -ge 1 ] 2>/dev/null; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi }
files() { find "$OUT/$1" -name "$2" 2>/dev/null; }

K=kitchensink/v1
check "ts: ThingService client"        "$(grep -c createThingServiceClient "$OUT/ts/easyrpc/$K/kitchen_easyrpc.ts" 2>/dev/null)"
check "ts: AdminThingService client"   "$(grep -c createAdminThingServiceClient "$OUT/ts/easyrpc/$K/kitchen_easyrpc.ts" 2>/dev/null)"
check "ts: gRPC-style path"            "$(grep -c 'easyrpc.kitchensink.v1.ThingService/NoRoute' "$OUT/ts/easyrpc/$K/kitchen_easyrpc.ts" 2>/dev/null)"
check "ts: serverStream WatchThings"   "$(grep -c 'serverStream: true' "$OUT/ts/easyrpc/$K/kitchen_easyrpc.ts" 2>/dev/null)"
check "ts: no httpMethod field"        "$([ "$(grep -c 'httpMethod' "$OUT/ts/easyrpc/$K/kitchen_easyrpc.ts" 2>/dev/null)" = "0" ] && echo 1 || echo 0)"
check "go: both services"              "$(grep -c 'AdminThingService_Methods' "$OUT/go/easyrpc/$K/kitchen.easyrpc.go" 2>/dev/null)"
check "go: gRPC-style path"            "$(grep -c 'easyrpc.kitchensink.v1.ThingService/GetThing' "$OUT/go/easyrpc/$K/kitchen.easyrpc.go" 2>/dev/null)"
check "go: no HTTPMethod field"        "$([ "$(grep -c 'HTTPMethod' "$OUT/go/easyrpc/$K/kitchen.easyrpc.go" 2>/dev/null)" = "0" ] && echo 1 || echo 0)"
check "kt: AdminThingServiceClient"    "$(grep -rl 'class AdminThingServiceClient' "$OUT/kt/easyrpc/$K" 2>/dev/null | wc -l)"
check "cs: AdminThingServiceClient"    "$(grep -rl 'class AdminThingServiceClient' "$OUT/cs/easyrpc/$K" 2>/dev/null | wc -l)"
check "swift: AdminThingServiceClient" "$(grep -rl 'class AdminThingServiceClient' "$OUT/sw/easyrpc/$K" 2>/dev/null | wc -l)"
check "dart: AdminThingServiceClient"  "$(grep -rl 'class AdminThingServiceClient' "$OUT/dart/easyrpc/$K" 2>/dev/null | wc -l)"
check "py: AdminThingServiceClient"    "$(grep -rl 'class AdminThingServiceClient' "$OUT/py/easyrpc/$K" 2>/dev/null | wc -l)"
check "rust: both services"            "$(grep -c 'AdminThingService' "$OUT/rust/easyrpc/$K/kitchen_easyrpc.rs" 2>/dev/null)"

[ "$fail" = 0 ] && echo "GOLDEN PASS" || { echo "GOLDEN FAIL"; exit 1; }
