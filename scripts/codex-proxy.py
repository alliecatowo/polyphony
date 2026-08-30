#!/usr/bin/env python3
"""Bridge newline-delimited app-server JSON to Codex's Unix WebSocket socket."""

import base64
import hashlib
import os
import select
import socket
import struct
import sys


def send_all(sock: socket.socket, payload: bytes) -> None:
    view = memoryview(payload)
    while view:
        try:
            sent = sock.send(view)
        except BlockingIOError:
            _, writable, _ = select.select([], [sock], [], 5.0)
            if not writable:
                raise TimeoutError("timed out writing to Codex app-server")
            continue
        if sent == 0:
            raise ConnectionError("Codex app-server socket closed while writing")
        view = view[sent:]


def frame(payload: bytes) -> bytes:
    mask = os.urandom(4)
    masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    length = len(masked)
    if length < 126:
        header = bytes([0x81, 0x80 | length])
    elif length < 65536:
        header = bytes([0x81, 0xFE]) + struct.pack("!H", length)
    else:
        header = bytes([0x81, 0xFF]) + struct.pack("!Q", length)
    return header + mask + masked


def parse_frame(buffer: bytearray):
    if len(buffer) < 2:
        return None
    first, second = buffer[0], buffer[1]
    length = second & 0x7F
    offset = 2
    if length == 126:
        if len(buffer) < offset + 2:
            return None
        length = struct.unpack("!H", buffer[offset : offset + 2])[0]
        offset += 2
    elif length == 127:
        if len(buffer) < offset + 8:
            return None
        length = struct.unpack("!Q", buffer[offset : offset + 8])[0]
        offset += 8
    masked = second & 0x80
    if masked:
        if len(buffer) < offset + 4:
            return None
        mask = buffer[offset : offset + 4]
        offset += 4
    else:
        mask = None
    if len(buffer) < offset + length:
        return None
    payload = bytes(buffer[offset : offset + length])
    del buffer[: offset + length]
    if mask:
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return first & 0x0F, payload


def main() -> int:
    socket_path = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.codex/app-server-control/app-server-control.sock")
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(socket_path)
    sock.sendall(
        (
            "GET / HTTP/1.1\r\n"
            "Host: localhost\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        ).encode()
    )
    response = b""
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(4096)
        if not chunk:
            return 1
        response += chunk
    if not response.startswith(b"HTTP/1.1 101"):
        sys.stderr.write(response.decode(errors="replace"))
        return 1

    sock.setblocking(False)
    stdin = sys.stdin.buffer
    buffer = bytearray(response.split(b"\r\n\r\n", 1)[1])
    while True:
        readable, _, _ = select.select([sock, stdin], [], [], 0.5)
        if sock in readable:
            data = sock.recv(65536)
            if not data:
                return 1
            buffer.extend(data)
            while True:
                parsed = parse_frame(buffer)
                if parsed is None:
                    break
                opcode, payload = parsed
                if opcode == 0x1:
                    sys.stdout.buffer.write(payload + b"\n")
                    sys.stdout.buffer.flush()
                elif opcode == 0x8:
                    return 0
                elif opcode == 0x9:
                    send_all(sock, bytes([0x8A, len(payload)]) + payload)
        if stdin in readable:
            line = stdin.readline()
            if not line:
                return 0
            send_all(sock, frame(line.rstrip(b"\n")))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (BrokenPipeError, ConnectionError, OSError) as error:
        sys.stderr.write(f"codex proxy bridge failed: {error}\n")
        raise SystemExit(1)
