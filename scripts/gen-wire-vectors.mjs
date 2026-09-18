#!/usr/bin/env node
// Generate + verify easy-rpc wire-vectors.json from the TS protocol layer.
// The TS core is the reference implementation of the protocol; this script
// writes the byte-exact vectors that every language then asserts against.
//
// Usage (from easy-rpc-spec/):  node scripts/gen-wire-vectors.mjs
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const HERE = dirname(fileURLToPath(import.meta.url))
const OUT = resolve(HERE, '../conformance/wire-vectors.json')
const PROTOCOL = resolve(HERE, '../../easy-rpc-ts/dist/protocol.js')

const P = await import(PROTOCOL)
const hex = (b) => Buffer.from(b).toString('hex')
const bytes = (h) => new Uint8Array(Buffer.from(h, 'hex'))

const v = JSON.parse(readFileSync(OUT, 'utf8'))

for (const f of v.frames) {
  const raw = P.frame(bytes(f.encode.payloadHex), f.encode.end, 4 * 1024 * 1024, false)
  if (f.encode.compressed) raw[0] = (raw[0] ?? 0) | 0x01
  const got = hex(raw)
  if (got !== f.bytesHex) { console.error('frame mismatch', f.name, got, f.bytesHex); f.bytesHex = got }
}

for (const e of v.endStream) {
  const es = P.decodeEndStream(bytes(e.decode.bytesHex)) ?? { code: 0, message: '', metadata: undefined }
  const norm = (m) => (m && Object.keys(m).length ? m : null)
  if (es.code !== e.code || es.message !== e.message) console.error('endStream decode mismatch', e.name)
  if (e.metadata && JSON.stringify(norm(es.metadata)) !== JSON.stringify(e.metadata)) console.error('endStream metadata mismatch', e.name)
  if (e.encode && e.bytesHex) {
    const got = hex(P.encodeEndStream(e.encode.code, e.encode.message, undefined, e.encode.metadata))
    const semantic = (b) => JSON.stringify(Object.fromEntries(Object.entries(JSON.parse(new TextDecoder().decode(b))).sort()))
    if (semantic(bytes(got)) !== semantic(bytes(e.bytesHex))) { console.error('endStream encode mismatch', e.name, got); e.bytesHex = got }
  }
}

for (const u of v.unaryError) {
  const det = (u.encode.details ?? []).map((d) => ({ type: d.type, value: bytes(d.valueHex) }))
  const got = hex(P.encodeErrorJson(u.encode.code, u.encode.message, det.length ? det : undefined))
  const semantic = (h) => JSON.stringify(Object.fromEntries(Object.entries(JSON.parse(new TextDecoder().decode(bytes(h)))).sort()))
  if (semantic(got) !== semantic(u.bytesHex)) { console.error('unaryError mismatch', u.name, got); u.bytesHex = got }
}

for (const t of v.trailerHeaders) {
  if (t.demux) {
    const r = P.demuxTrailers(t.demux)
    if (JSON.stringify(r.headers) !== JSON.stringify(t.headers) || JSON.stringify(r.trailers) !== JSON.stringify(t.trailers)) console.error('demux mismatch', t.name)
  }
  if (t.mux) {
    const r = P.muxTrailers(t.mux.headers, t.mux.trailers)
    if (JSON.stringify(r) !== JSON.stringify(t.result)) console.error('mux mismatch', t.name)
  }
}

for (const c of v.codeNames) {
  if (P.codeToString(c.code) !== c.name || P.codeFromString(c.name) !== c.code) console.error('code map mismatch', c.code)
  if (c.code !== 0 && P.httpStatus(c.code) !== c.http) console.error('http map mismatch', c.code)
}

writeFileSync(OUT, JSON.stringify(v, null, 2) + '\n')
console.log('wire-vectors.json verified + rewritten ->', OUT)
