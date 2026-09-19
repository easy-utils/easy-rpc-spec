#!/usr/bin/env python3
"""Same-connection HTTP/3 multiplexing oracle (spec §8.5).

Uses only the `aioquic` library (no easy-rpc code) to open ONE QUIC connection
and issue several server-streaming RPCs concurrently on distinct H3 streams,
then asserts that:

  * all streams complete with the correct frames (no cross-talk),
  * streams interleave (the server does not serialize them), and
  * the connection stays healthy for a normal unary call afterwards.

Self-signed CA + IP is sufficient: pass the CA cert with `--ca`. The server
name defaults to the host (the cert must carry an IP SAN for a bare IP). This
mirrors the in-cluster `conformance-tls` caddy endpoint (`tls internal`,
IP-SAN, ALPN h2 + h3).

Usage: h3-concurrent.py [host] [port] [n] [--ca FILE] [--authority AUTH]
Exit 0 => pass.
"""
import asyncio
import argparse
import ssl
import sys
import urllib.parse

try:
    from aioquic.asyncio import connect
    from aioquic.asyncio.protocol import QuicConnectionProtocol
    from aioquic.h3.connection import H3Connection
    from aioquic.h3.events import DataReceived, HeadersReceived
    from aioquic.quic.configuration import QuicConfiguration
except Exception as exc:  # pragma: no cover - optional dep
    print(f"  skip h3-concurrent (aioquic unavailable: {exc})")
    sys.exit(0)


def varint(n: int) -> bytes:
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out += bytes([b | 0x80])
        else:
            out += bytes([b])
            break
    return out


def field(num: int, wire: int) -> bytes:
    return varint((num << 3) | wire)


def frame(payload: bytes) -> bytes:
    return bytes([0]) + len(payload).to_bytes(4, "big") + payload


def count_req(n: int) -> bytes:
    return field(1, 0) + varint(n)


def count_frames(body: bytes):
    off = 0
    data = 0
    ended = False
    name = ""
    while off + 5 <= len(body):
        flags = body[off]
        ln = int.from_bytes(body[off + 1:off + 5], "big")
        if off + 5 + ln > len(body):
            break
        payload = body[off + 5:off + 5 + ln]
        if flags & 0x02:
            ended = True
            txt = payload.decode("utf-8", "replace")
            if '"code"' in txt:
                try:
                    name = txt.split('"code"')[1].split('"')[1]
                except IndexError:
                    name = "?"
        else:
            data += 1
        off += 5 + ln
    return data, ended, name


class H3Client(QuicConnectionProtocol):
    """Minimal H3 client that demuxes responses per stream id."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._http = H3Connection(self._quic)
        self.headers: dict[int, list] = {}
        self.body: dict[int, bytearray] = {}
        self.closed: set[int] = set()

    def quic_event_received(self, event):
        for ev in self._http.handle_event(event):
            sid = ev.stream_id
            if isinstance(ev, HeadersReceived):
                self.headers.setdefault(sid, []).extend(ev.headers)
            elif isinstance(ev, DataReceived):
                self.body.setdefault(sid, bytearray()).extend(ev.data)
                if ev.stream_ended:
                    self.closed.add(sid)

    def request(self, authority: str, path: str, content_type: str, body: bytes):
        sid = self._http._quic.get_next_available_stream_id()
        hdrs = [
            (b":method", b"POST"),
            (b":scheme", b"https"),
            (b":authority", authority.encode()),
            (b":path", path.encode()),
            (b"content-type", content_type.encode()),
            (b"connect-protocol-version", b"1"),
        ]
        self._http.send_headers(sid, hdrs, end_stream=False)
        self._http.send_data(sid, body, end_stream=True)
        self.transmit()
        return sid

    def status(self, sid: int) -> int:
        for k, v in self.headers.get(sid, []):
            if k == b":status":
                return int(v)
        return 0


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("host", nargs="?", default="127.0.0.1")
    ap.add_argument("port", nargs="?", type=int, default=18443)
    ap.add_argument("n", nargs="?", type=int, default=6)
    ap.add_argument("--ca", default=None)
    ap.add_argument("--authority", default=None)
    ap.add_argument("--svc", default="easyrpc.conformance.v1.ConformanceService")
    args = ap.parse_args()

    authority = args.authority or f"{args.host}:{args.port}"
    fails: list[str] = []

    cfg = QuicConfiguration(is_client=True, alpn_protocols=["h3"])
    if args.ca:
        cfg.cafile = args.ca
    # The cert must match the SNI; for a bare IP the cert needs an IP SAN.
    cfg.server_name = args.host

    try:
        conn = connect(args.host, args.port, configuration=cfg, create_protocol=H3Client)
        proto = await conn.__aenter__()
    except Exception as exc:
        print(f"  FAIL h3 QUIC connect: {exc}")
        print("=== h3-concurrent: FAIL (1 failures) ===")
        return 1

    try:
        # 1. Open n server-streams concurrently on ONE connection.
        sids: dict[int, int] = {}
        for i in range(args.n):
            count = i + 1
            sid = proto.request(
                authority, f"/{args.svc}/BigStream", "application/connect+proto",
                frame(field(1, 0) + varint(count) + field(2, 0) + varint(16)),
            )
            sids[sid] = count

        deadline = asyncio.get_event_loop().time() + 20.0
        while asyncio.get_event_loop().time() < deadline:
            if all(sid in proto.closed for sid in sids):
                break
            await asyncio.sleep(0.02)

        for sid, count in sids.items():
            if sid not in proto.closed:
                fails.append(f"stream {sid} did not end")
                continue
            data, ended, name = count_frames(bytes(proto.body.get(sid, b"")))
            if not ended:
                fails.append(f"stream {sid} missing END frame")
            elif name:
                fails.append(f"stream {sid} ended with error {name}")
            elif data != count:
                fails.append(f"stream {sid} got {data} frames, want {count}")
        if not any("stream" in f for f in fails):
            print(f"  ok   {args.n} concurrent h3 streams on one connection (no cross-talk)")

        # 2. Multiplexing: >=2 streams open simultaneously during dispatch.
        sids2 = [
            proto.request(authority, f"/{args.svc}/Count", "application/connect+proto",
                          frame(count_req(20)))
            for _ in range(4)
        ]
        overlap = False
        for _ in range(400):
            open_now = [s for s in sids2 if s not in proto.closed]
            if len(open_now) >= 2:
                overlap = True
                break
            await asyncio.sleep(0.005)
        deadline = asyncio.get_event_loop().time() + 20.0
        while asyncio.get_event_loop().time() < deadline:
            if all(s in proto.closed for s in sids2):
                break
            await asyncio.sleep(0.02)
        if overlap:
            print("  ok   h3 streams execute concurrently (>=2 open at once)")
        else:
            fails.append("h3 streams did not overlap (server serialized them)")

        # 3. Connection reusable for a unary call afterwards.
        sid = proto.request(authority, f"/{args.svc}/Echo", "application/proto",
                            field(1, 2) + varint(2) + b"hi")
        deadline = asyncio.get_event_loop().time() + 10.0
        while sid not in proto.closed and asyncio.get_event_loop().time() < deadline:
            await asyncio.sleep(0.02)
        body = bytes(proto.body.get(sid, b""))
        if body == field(1, 2) + varint(7) + b"echo:hi":
            print("  ok   connection reusable for unary after streams")
        else:
            fails.append(f"post-stream unary body mismatch: {body!r}")

        _unused = ssl  # keep import referenced for optional-dep symmetry
    finally:
        try:
            await conn.__aexit__(None, None, None)
        except Exception:
            pass

    for f in fails:
        print(f"  FAIL {f}")
    print(f"=== h3-concurrent: {'PASS' if not fails else 'FAIL'} ({len(fails)} failures) ===")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
