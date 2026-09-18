#!/usr/bin/env python3
"""Same-connection HTTP/2 multiplexing oracle (spec §8.5).

Uses only the `h2` library (no easy-rpc code) to open ONE h2c connection and
issue several server-streaming RPCs concurrently on distinct streams, then
asserts that:

  * all streams complete with the correct frames (no cross-talk),
  * streams interleave (the server does not serialize them into one),
  * the connection stays healthy for a normal unary call afterwards.

This catches per-connection state bugs (shared buffers, one-request-per-conn
assumptions) that per-request tests cannot.

Usage: h2-concurrent.py [base-host] [port] [n]
Exit 0 => pass.
"""
import socket
import struct
import sys
import threading
import time

from h2.connection import H2Connection
from h2.config import H2Configuration
from h2.events import DataReceived, ResponseReceived, StreamEnded, StreamReset


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
    """Return (data_frames, ended, error_name) for an enveloped stream body."""
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


HEADERS = [
    (":method", "POST"),
    (":scheme", "http"),
    (":authority", "127.0.0.1"),
    ("content-type", "application/connect+proto"),
    ("connect-protocol-version", "1"),
]


def req_headers(path: str, content_type: str):
    """Pseudo-headers MUST precede regular headers (h2 rule)."""
    return [
        (":method", "POST"),
        (":scheme", "http"),
        (":authority", "127.0.0.1"),
        (":path", path),
        ("content-type", content_type),
        ("connect-protocol-version", "1"),
    ]


class Client:
    def __init__(self, host: str, port: int):
        self.sock = socket.create_connection((host, port))
        self.conn = H2Connection(config=H2Configuration(client_side=True, header_encoding="utf-8"))
        self.conn.initiate_connection()
        self.sock.sendall(self.conn.data_to_send())
        self.responses: dict[int, list] = {}
        self.ended: set[int] = set()
        self.reset: set[int] = set()
        self.headers_seen: dict[int, list] = {}
        self.lock = threading.Lock()
        self.stop = False
        self.reader = threading.Thread(target=self._read_loop, daemon=True)
        self.reader.start()

    def _read_loop(self):
        while not self.stop:
            try:
                data = self.sock.recv(65535)
            except OSError:
                return
            if not data:
                return
            events = self.conn.receive_data(data)
            for ev in events:
                with self.lock:
                    if isinstance(ev, ResponseReceived):
                        self.headers_seen.setdefault(ev.stream_id, []).extend(ev.headers)
                    elif isinstance(ev, DataReceived):
                        self.responses.setdefault(ev.stream_id, bytearray()).extend(ev.data)
                    elif isinstance(ev, StreamEnded):
                        self.ended.add(ev.stream_id)
                    elif isinstance(ev, StreamReset):
                        self.reset.add(ev.stream_id)
            to_send = self.conn.data_to_send()
            if to_send:
                try:
                    self.sock.sendall(to_send)
                except OSError:
                    return

    def open_stream(self, path: str, body: bytes, content_type: str = "application/connect+proto") -> int:
        sid = self.conn.get_next_available_stream_id()
        self.conn.send_headers(sid, req_headers(path, content_type), end_stream=False)
        self.conn.send_data(sid, frame(body), end_stream=True)
        with self.lock:
            self.sock.sendall(self.conn.data_to_send())
        return sid

    def wait(self, sid: int, timeout: float = 10.0) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                if sid in self.ended or sid in self.reset:
                    return True
            time.sleep(0.02)
        return False

    def close(self):
        self.stop = True
        try:
            self.sock.close()
        except OSError:
            pass


def main() -> int:
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 18888
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 6

    svc = "easyrpc.conformance.v1.ConformanceService"
    c = Client(host, port)
    fails = []

    # 1. Open n server-streams concurrently on ONE connection.
    #    Use BigStream with a per-stream frame count so cross-talk is visible.
    sids = {}
    for i in range(n):
        count = i + 1
        sid = c.open_stream(f"/{svc}/BigStream", field(1, 0) + varint(count) + field(2, 0) + varint(16))
        sids[sid] = count

    for sid, count in sids.items():
        if not c.wait(sid, timeout=15.0):
            fails.append(f"stream {sid} did not end")
            continue
        with c.lock:
            body = bytes(c.responses.get(sid, b""))
        data, ended, name = count_frames(body)
        if sid in c.reset:
            fails.append(f"stream {sid} was reset")
        elif not ended:
            fails.append(f"stream {sid} missing END frame")
        elif name:
            fails.append(f"stream {sid} ended with error {name}")
        elif data != count:
            fails.append(f"stream {sid} got {data} frames, want {count}")

    if not fails:
        print(f"  ok   {n} concurrent h2 streams on one connection (no cross-talk)")

    # 2. Multiplexing: streams must share the connection concurrently, i.e.
    #    more than one stream is open (not ended) at the same moment during
    #    dispatch. Re-open a fresh connection and check overlap.
    c2 = Client(host, port)
    sids2 = [c2.open_stream(f"/{svc}/Count", count_req(20)) for _ in range(4)]
    # Poll until at least two are still open simultaneously.
    overlap = False
    for _ in range(200):
        with c2.lock:
            open_now = [s for s in sids2 if s not in c2.ended and s not in c2.reset]
        if len(open_now) >= 2:
            overlap = True
            break
        time.sleep(0.005)
    for sid in sids2:
        c2.wait(sid, timeout=15.0)
    if overlap:
        print("  ok   h2 streams execute concurrently (>=2 open at once)")
    else:
        fails.append("h2 streams did not overlap (server serialized them)")

    # 3. Connection remains usable for a unary call after the streams.
    import base64
    sid = c2.conn.get_next_available_stream_id()
    c2.conn.send_headers(sid, req_headers(f"/{svc}/Echo", "application/proto"), end_stream=False)
    c2.conn.send_data(sid, field(1, 2) + varint(2) + b"hi", end_stream=True)
    with c2.lock:
        c2.sock.sendall(c2.conn.data_to_send())
    if c2.wait(sid, timeout=10.0):
        with c2.lock:
            body = bytes(c2.responses.get(sid, b""))
        if body == field(1, 2) + varint(7) + b"echo:hi":
            print("  ok   connection reusable for unary after streams")
        else:
            fails.append(f"post-stream unary body mismatch: {body!r}")
    else:
        fails.append("post-stream unary did not complete")

    c.close()
    c2.close()

    for f in fails:
        print(f"  FAIL {f}")
    print(f"=== h2-concurrent: {'PASS' if not fails else 'FAIL'} ({len(fails)} failures) ===")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
