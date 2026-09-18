# easy-rpc conformance

Language-neutral conformance assets, consumed verbatim by every implementation.

| File | Purpose |
|------|---------|
| `wire-vectors.json` | **Protocol oracle.** Byte-level frames + semantic JSON payloads + trailer mux/demux + code table. Every language vendors a copy into its test data and asserts its protocol layer reproduces it. Generated/verified from the TS reference by `scripts/gen-wire-vectors.mjs`. |
| `checklist.json` | **Interop checklist.** The single source of truth for the cross-language cases (shapes + expectations) so no language silently omits a case. |

## Why two levels

A shared bug in two implementations passes unless an implementation-independent
oracle exists. That oracle is:

1. `wire-vectors.json` (no transport; pure protocol bytes), and
2. `cli/raw-wire.sh` (only `curl`; the real HTTP wire).

`cli/matrix/run-matrix.sh` then exercises every (client × transport) against
every server, so transport-specific bugs (e.g. an h2c status-code loss) surface.

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
