#!/usr/bin/env python3
"""Exercise the real CLI's stdio framing; only status is queried, never activity contents."""
import argparse
import json
import select
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("cli")
args = parser.parse_args()
process = subprocess.Popen([args.cli, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def receive():
    ready, _, _ = select.select([process.stdout], [], [], 10)
    assert ready, "MCP response timeout"
    line = process.stdout.readline()
    assert line, "MCP terminated without response"
    return json.loads(line)


def send(value):
    process.stdin.write(json.dumps(value, separators=(",", ":")).encode() + b"\n")
    process.stdin.flush()


try:
    send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "Dayreed wire test", "version": "1"}}})
    assert receive()["result"]["protocolVersion"] == "2025-11-25"
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    send({"jsonrpc": "2.0", "id": "tools", "method": "tools/list"})
    tools = receive()["result"]["tools"]
    assert [tool["name"] for tool in tools] == ["dayreed_status", "dayreed_timeline", "dayreed_report"]
    assert all(tool["annotations"]["readOnlyHint"] for tool in tools)
    send({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "dayreed_status", "arguments": {}}})
    status = receive()["result"]
    assert not status["isError"] and status["structuredContent"]["rawContentIncluded"] is False
    send({"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {
        "name": "dayreed_timeline", "arguments": {"date": "2026-09-06", "raw": True}}})
    assert receive()["error"]["code"] == -32602
    process.stdin.write(b"{broken\n")
    process.stdin.flush()
    assert receive()["error"]["code"] == -32700
    process.stdin.write(b"a" * (1_048_576 + 1) + b"\n")
    process.stdin.flush()
    assert receive()["error"]["code"] == -32700
    send({"jsonrpc": "2.0", "id": 5, "method": "ping"})
    assert receive() == {"jsonrpc": "2.0", "id": 5, "result": {}}
    process.stdin.close()
    assert process.wait(timeout=10) == 0
    assert process.stderr.read() == b"", "Unexpected MCP diagnostics"
    print("PASS: real stdio handshake, read-only tools, status, raw rejection, malformed/oversized recovery and clean EOF")
finally:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
