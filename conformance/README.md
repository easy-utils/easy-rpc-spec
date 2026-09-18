# easy-rpc conformance

Language-neutral conformance assets, consumed verbatim by every implementation.

| File | Purpose |
|------|---------|
| `wire-vectors.json` | **Protocol oracle.** Byte-level frames + semantic JSON payloads + trailer mux/demux + code table. Every language vendors a copy into its test data and asserts its protocol layer reproduces it. Generated/verified from the TS reference by `scripts/gen-wire-vectors.mjs`. |
| `checklist.json` | **Interop checklist (v2).** The single source of truth for the cross-language cases (client cases + serverMatrix: 16 codes, stream boundaries, unexpected/malformed requests, limits, metadata, HTTP-version, cancellation) so no language silently omits a case. |

## Why two levels

A shared bug in two implementations passes unless an implementation-independent
oracle exists. That oracle is:

1. `wire-vectors.json` (no transport; pure protocol bytes),
2. `cli/raw-wire.sh` (only `curl`; the real HTTP wire), and
3. `cli/h2-concurrent.py` (only the `h2` library; same-connection multiplexing).

`cli/matrix/run-matrix.sh` then exercises every (client × transport) against
every server, so transport-specific bugs (e.g. an h2c status-code loss) surface.

## Executable server oracles

The `serverMatrix` in `checklist.json` is enforced language-independently:

```bash
bash cli/raw-wire.sh http://127.0.0.1:18888 h1,h2c   # all 16 codes, boundaries, malformed, ...
python3 cli/h2-concurrent.py 127.0.0.1 18888          # concurrent streams on one h2c connection
```

`raw-wire.sh` takes a second argument listing the server's supported HTTP
versions (`h1,h2c` for Go/Rust/Python, `h1` for the Node server, which cannot
mux h1+h2c on one socket). `cli/ci/run-all.sh rawwire h2` runs both against the
supervisor-managed fixtures.

## Official ConnectRPC suite

In addition to our own oracle, every server implementation is validated against
the **official** `connectconformance` runner (vendored protos + config under
`conformance/official/`). The server command reads a size-prefixed
`ServerCompatRequest` from stdin, starts an ephemeral server implementing the
official `connectrpc.conformance.v1.ConformanceService`, and replies with a
size-prefixed `ServerCompatResponse`.

```bash
# Build the runner once:
git clone --depth 1 https://github.com/connectrpc/conformance /tmp/cconf
( cd /tmp/cconf && go build -o /tmp/opencode/bin/connectconformance ./cmd/connectconformance )

bash conformance/official/run-official.sh ts       # or: go | rust | python
```

All four server implementations currently pass **292/292** official cases
(h1 + h2c, connect + proto, identity + gzip, unary + server-stream). Client /
bidi streaming are intentionally out of scope for easy-rpc and are excluded by
`configs/easy-rpc-server.yaml`.

## Regenerating the vectors

```bash
cd easy-rpc-ts && npm run build
node ../easy-rpc-spec/scripts/gen-wire-vectors.mjs
```

Then sync the file into each language's test data:

```bash
for d in easy-rpc-go/testdata easy-rpc-rust/testdata easy-rpc-python/tests/testdata \
         easy-rpc-kotlin/src/test/resources easy-rpc-csharp/tests \
         easy-rpc-dart/test/testdata easy-rpc-swift/Tests/easyRpcTests/Resources; do
  cp easy-rpc-spec/conformance/wire-vectors.json "$d/wire-vectors.json"
done
```
