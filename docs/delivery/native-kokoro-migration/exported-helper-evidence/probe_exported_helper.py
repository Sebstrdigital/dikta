#!/usr/bin/env python3
"""Bounded protocol probe for the task-owned exported NativeKokoroHelper."""
import json
import struct
import subprocess
import sys
import time

MAGIC = b"NKP1"
KINDS = {1: "hello", 2: "ready", 6: "shutdown", 8: "failed", 9: "describe", 10: "layout", 14: "complete"}


def frame(kind, session, request=0, sequence=0, payload=b""):
    return MAGIC + struct.pack(">HHIQQI", 1, kind, len(payload), session, request, sequence) + payload


def read_exact(stream, count):
    result = b""
    while len(result) < count:
        part = stream.read(count - len(result))
        if not part:
            raise EOFError(f"EOF after {len(result)} of {count} bytes")
        result += part
    return result


def receive(stream):
    header = read_exact(stream, 32)
    if header[:4] != MAGIC:
        raise ValueError("bad magic")
    version, kind, size, session, request, sequence = struct.unpack(">HHIQQI", header[4:])
    if version != 1 or size > 1_048_576:
        raise ValueError("bad frame")
    payload = read_exact(stream, size)
    value = {"kind": KINDS.get(kind, kind), "session": session, "request": request, "sequence": sequence}
    if kind == 10:
        value["layout"] = json.loads(payload)
    elif payload:
        value["payload_hex"] = payload.hex()
    return value


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: probe_exported_helper.py /path/to/NativeKokoroHelper")
    helper = sys.argv[1]
    process = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    owned_pid = process.pid
    responses = []
    try:
        process.stdin.write(frame(1, 123))
        process.stdin.flush()
        responses.append(receive(process.stdout))
        process.stdin.write(frame(9, 123, 7, 0))
        process.stdin.flush()
        responses.append(receive(process.stdout))
        if responses[-1]["kind"] == "layout":
            responses.append(receive(process.stdout))
        process.stdin.write(frame(6, 123, 7, 1))
        process.stdin.flush()
        process.stdin.close()
        try:
            status = process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()  # only the directly owned task helper
            status = process.wait(timeout=3)
        print(json.dumps({"helper": helper, "owned_pid": owned_pid, "responses": responses,
                          "exit_status": status, "stderr_hex": process.stderr.read().hex()}, indent=2))
        expected = ["ready", "layout", "complete"]
        actual = [item["kind"] for item in responses]
        return 0 if actual == expected and status == 0 else 1
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()


if __name__ == "__main__":
    raise SystemExit(main())
