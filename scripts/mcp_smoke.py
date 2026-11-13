#!/usr/bin/env python3
"""Smoke checks for scripts/install.sh and scripts/doctor.sh (stdlib only; run with /usr/bin/python3 -I).

  mcp_smoke.py mcp <regista-mcp>   initialize + tools/list + tools/call engines_status over stdio (headless:
                                   REGISTA_ENGINE=local, so it never attaches to a running app). Prints the tool
                                   count, the tier and every engine; exit 1 if the server does not answer.
  mcp_smoke.py socket <engine.sock>  hello on the app's live-attach socket: exit 0 = the app is listening,
                                   2 = no socket file, 3 = a stale socket (app not running), 1 = bad reply.
"""
import json
import os
import socket
import subprocess
import sys


def mcp(binary):
    env = dict(os.environ, REGISTA_ENGINE="local")
    p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         env=env, text=True)

    def call(rid, method, params=None):
        msg = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            msg["params"] = params
        p.stdin.write(json.dumps(msg) + "\n")
        p.stdin.flush()
        while True:
            line = p.stdout.readline()
            if not line:
                raise RuntimeError(f"regista-mcp closed the pipe during {method}")
            reply = json.loads(line)
            if reply.get("id") == rid:
                if "error" in reply:
                    raise RuntimeError(f"{method}: {reply['error']}")
                return reply["result"]

    try:
        init = call(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                      "clientInfo": {"name": "regista-install", "version": "1"}})
        p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        p.stdin.flush()
        tools = call(2, "tools/list", {})["tools"]
        res = call(3, "tools/call", {"name": "engines_status", "arguments": {}})
        text = next(c["text"] for c in res["content"] if c.get("type") == "text")
        status = json.loads(text)
        status = status.get("result", status)
    except Exception as e:  # noqa: BLE001 — report any failure as a failed smoke check
        print(f"MCP smoke check failed: {e}")
        return 1
    finally:
        p.stdin.close()
        p.wait(timeout=10)

    server = init.get("serverInfo", {})
    print(f"server {server.get('name', '?')} {server.get('version', '')} · protocol {init.get('protocolVersion')}")
    print(f"tools {len(tools)} · tier {status.get('tier')} ({status.get('memoryGB')} GB RAM) · "
          f"transcription {status.get('defaults', {}).get('transcription')}")
    print(f"config {status.get('configFile')} (loaded: {status.get('configLoaded')})")
    if status.get("configWarning"):
        print(f"config warning: {status['configWarning']}")
    ranks = {"base": 0, "medium": 1, "pro": 2}
    tier = ranks.get(status.get("tier"), 0)
    for e in status.get("engines", []):
        mark = "✓" if e.get("enabled") else "✗"
        note = ""
        if ranks.get(e.get("minimumTier"), 0) > tier:
            mark, note = "·", f" (needs the {e.get('minimumTier')} tier)"
        elif not e.get("available"):
            note = f" — {e.get('reason', 'not found')}"
        if e.get("verified") is False:
            note += " — CHECKSUM MISMATCH"
        print(f"  {mark} {e.get('id')}{note}")
    return 0


def sock(path):
    if not os.path.exists(path):
        return 2
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    try:
        s.connect(path)
    except OSError:
        return 3
    try:
        s.sendall(b'{"op": "hello", "client": "regista-doctor"}\n')
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        reply = json.loads(buf)
        print(f"app listening, {len(reply.get('commands', []))} commands")
        return 0 if reply.get("ok") else 1
    except (OSError, ValueError):
        return 1
    finally:
        s.close()


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("mcp", "socket"):
        print(__doc__)
        sys.exit(64)
    sys.exit(mcp(sys.argv[2]) if sys.argv[1] == "mcp" else sock(sys.argv[2]))
