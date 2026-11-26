#!/usr/bin/env python3
"""Counts what the exchange server delivers to one market-feed connection, at each lab setting the measurements use.

Why it exists: the app records one tickToApp sample for every frame of the market feed, and a frame carries the newest
quote of every symbol that changed since the previous frame (the server merges the ticks of a connection). The app's
count is therefore a count of frames, not of symbol updates. This client counts both, so that a run's "ticks per second"
can be set against what a connection really receives.

Usage (the server must be running: `make server`):
    python3 -I docs/results/feed-probe.py [seconds per setting]

For every lab setting listed in SETTINGS it sets the lab, reads the settings back from the server (which clamps what it
is given), waits two seconds, opens a WebSocket to /ws/market, subscribes to every symbol, ignores the first second (the
full states a subscription queues are not the steady feed) and then counts frames and symbol updates for the given number
of seconds (10 when not given). The results are printed and written to feed-probe.json next to this file. The lab is put
back to its defaults whenever the script ends, also after a failure.

Python 3 standard library only. The frames are protobuf messages and are decoded by hand, which is enough for counting:
MarketFrame { int64 server_send_ns = 1; uint64 frame_seq = 2; repeated SymbolUpdate updates = 3; }
(Packages/TradeKit/Proto/market.proto). A frame without updates is a heartbeat.
"""
import base64
import json
import os
import socket
import struct
import sys
import time
import urllib.request

HOST, PORT = "127.0.0.1", 18080
BASE = "http://%s:%d" % (HOST, PORT)

DEFAULTS = {"rateMultiplier": 1, "stress": False, "extraLatencyMs": 0, "jitterMs": 0, "dropUpdates": False}

# The lab settings the measurements use (Scripts/measure.sh asks for these five fields every time).
SETTINGS = [
    dict(DEFAULTS),
    dict(DEFAULTS, rateMultiplier=4.2),
    dict(DEFAULTS, rateMultiplier=10),
    dict(DEFAULTS, stress=True),
    dict(DEFAULTS, extraLatencyMs=200),
]

SETTLE_SECONDS = 2.0
SKIP_SECONDS = 1.0
OUTPUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "feed-probe.json")


def post_lab(lab):
    request = urllib.request.Request(
        BASE + "/v1/admin/lab", data=json.dumps(lab).encode(), headers={"Content-Type": "application/json"}, method="POST"
    )
    urllib.request.urlopen(request, timeout=5).read()


def get_json(path):
    with urllib.request.urlopen(BASE + path, timeout=5) as response:
        return json.load(response)


def read_exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise EOFError("the server closed the connection")
        data += chunk
    return data


def send_text(sock, text):
    """One masked text frame (a client must mask what it sends)."""
    payload = text.encode()
    mask = os.urandom(4)
    header = bytearray([0x81])
    if len(payload) < 126:
        header.append(0x80 | len(payload))
    else:
        header.append(0x80 | 126)
        header += struct.pack(">H", len(payload))
    masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    sock.sendall(bytes(header) + mask + masked)


def read_message(sock):
    """The next data message as (opcode, payload): fragments are put together and pings are answered."""
    opcode, buffer = None, b""
    while True:
        first, second = read_exact(sock, 2)
        final, code = first & 0x80, first & 0x0F
        length = second & 0x7F
        if length == 126:
            length = struct.unpack(">H", read_exact(sock, 2))[0]
        elif length == 127:
            length = struct.unpack(">Q", read_exact(sock, 8))[0]
        payload = read_exact(sock, length)  # what a server sends is not masked
        if code == 0x9:  # ping: answer with a masked pong
            mask = os.urandom(4)
            masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
            sock.sendall(bytes([0x8A, 0x80 | len(payload)]) + mask + masked)
            continue
        if code == 0xA:  # pong
            continue
        if code in (0x1, 0x2):
            opcode = code
        buffer += payload
        if final:
            return opcode, buffer


def varint(data, position):
    shift, value = 0, 0
    while True:
        byte = data[position]
        position += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, position
        shift += 7


def count_updates(frame):
    """How many SymbolUpdate messages (field 3) a serialised MarketFrame holds."""
    position, updates = 0, 0
    while position < len(frame):
        key, position = varint(frame, position)
        field, wire = key >> 3, key & 7
        if wire == 0:
            _, position = varint(frame, position)
        elif wire == 2:
            length, position = varint(frame, position)
            position += length
            if field == 3:
                updates += 1
        elif wire == 1:
            position += 8
        elif wire == 5:
            position += 4
        else:
            raise ValueError("unexpected protobuf wire type %d" % wire)
    return updates


def connect(symbols):
    sock = socket.create_connection((HOST, PORT), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall(
        (
            "GET /ws/market HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (HOST, PORT, key)
        ).encode()
    )
    response = b""
    while b"\r\n\r\n" not in response:
        response += sock.recv(1)
    status_line = response.split(b"\r\n")[0]
    if b" 101 " not in status_line:
        raise RuntimeError("the WebSocket upgrade was refused: %r" % status_line)
    send_text(sock, json.dumps({"op": "subscribe", "symbols": symbols}))
    return sock


def probe(symbols, seconds):
    """Frames and symbol updates one connection receives in `seconds`, after the first second has been ignored."""
    sock = connect(symbols)
    try:
        opened = time.time()
        frames = updates = heartbeats = 0
        window_start = window_end = None
        while True:
            opcode, payload = read_message(sock)
            now = time.time()
            if opcode != 0x2 or now - opened < SKIP_SECONDS:
                continue
            if window_start is None:
                window_start = now  # this frame only opens the window and is not counted
                continue
            if now - window_start > seconds:
                break  # nor is the first frame after the window
            count = count_updates(payload)
            frames += 1
            updates += count
            heartbeats += 1 if count == 0 else 0
            window_end = now
    finally:
        sock.close()
    elapsed = (window_end - window_start) if window_end else 0.0
    return {
        "seconds": round(elapsed, 2),
        "frames": frames,
        "updates": updates,
        "heartbeats": heartbeats,
        "framesPerSecond": round(frames / elapsed, 1) if elapsed else None,
        "updatesPerSecond": round(updates / elapsed, 1) if elapsed else None,
        "updatesPerFrame": round(updates / frames, 2) if frames else None,
    }


def main():
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 10.0
    symbols = [item["ticker"] for item in get_json("/v1/symbols")]
    results = []
    try:
        for setting in SETTINGS:
            post_lab(setting)
            held = get_json("/v1/admin/lab")
            time.sleep(SETTLE_SECONDS)
            result = {"lab": held, "symbols": len(symbols)}
            result.update(probe(symbols, seconds))
            print(json.dumps(result, sort_keys=True))
            results.append(result)
    finally:
        post_lab(DEFAULTS)
    with open(OUTPUT, "w", encoding="utf-8") as handle:
        json.dump(results, handle, indent=2, sort_keys=True)
        handle.write("\n")


if __name__ == "__main__":
    main()
