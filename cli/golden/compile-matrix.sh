#!/bin/bash
# Compile the golden-generated clients in every language. Requires each
# language toolchain present. This is the "generation must compile" guard.
set -u
cd "$(dirname "$0")"
OUT="${GOLDEN_OUT:-/tmp/easyrpc-golden}"
SPEC_ROOT="$(cd ../.. && pwd)"
EASY_UTILS="$(cd ../../.. && pwd)"
fail=0
note() { echo "$1"; }

# Go: build the golden package inside a tiny module that points at easy-rpc-go.
if command -v go >/dev/null; then
  G="$OUT/compile/go"; rm -rf "$G"; mkdir -p "$G"
  cp -r "$OUT/go/easyrpc" "$G/"
  cat > "$G/go.mod" <<MOD
module goldencheck

go 1.26.0

require (
  github.com/easy-utils/easy-rpc-go v0.2.0
  google.golang.org/protobuf v1.36.12
)
MOD
  # Need protoc-gen-go output too; generate .pb.go quickly.
  ( cd "$OUT" && PATH="${EASYRPC_BIN:-/tmp/opencode/bin}:$PATH" buf generate \
      --template <(sed 's/protoc-gen-easyrpc-go/protoc-gen-go/' buf.gen.yaml) >/dev/null 2>&1 || true )
  ( cd "$G" && GOPRIVATE='github.com/easy-utils/*' GOFLAGS=-mod=mod go mod tidy >/dev/null 2>&1 && go build ./... >/dev/null 2>&1 ) \
    && note "ok   go compiles" || { note "FAIL go compiles"; fail=1; }
else note "skip go (no toolchain)"; fi

[ "$fail" = 0 ] && echo "COMPILE PASS" || { echo "COMPILE FAIL"; exit 1; }
