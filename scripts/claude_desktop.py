#!/usr/bin/env python3
"""The `regista` entry of Claude Desktop's config, for scripts/install.sh and scripts/doctor.sh
(stdlib only; run with /usr/bin/python3 -I).

  claude_desktop.py status <config> <regista-mcp> [KEY=VALUE ...]
      exit 0 = mcpServers.regista is exactly the entry `set` writes · 1 = no file or no regista entry ·
      2 = regista is something else (its command is printed) · 3 = the file is not valid JSON / not an object
  claude_desktop.py set <config> <regista-mcp> [KEY=VALUE ...]
      adds or replaces mcpServers.regista = {"command": <regista-mcp>, "args": [], "env": {KEY: VALUE}} and keeps
      every other key and server. An existing file is first copied to <config>.regista-backup-<timestamp>
      (printed); the new content is written to a temp file, read back and checked, then moved into place.
      Refuses (exit 3) a file that is not valid JSON, so nothing of the user's is ever lost.
"""
import json
import os
import shutil
import sys
import time


def load(path):
    """(config dict or None when the file is missing, error message or None)"""
    try:
        with open(path, encoding="utf-8") as f:
            cfg = json.load(f)
    except FileNotFoundError:
        return None, None
    except (OSError, ValueError) as e:
        return None, f"{path} is not valid JSON ({e})"
    if not isinstance(cfg, dict) or not isinstance(cfg.get("mcpServers", {}), dict):
        return None, f"{path}: expected a JSON object with an mcpServers object"
    return cfg, None


def expected(binary, env_pairs):
    entry = {"command": binary, "args": []}
    env = dict(p.split("=", 1) for p in env_pairs)
    if env:
        entry["env"] = env
    return entry


def status(path, binary, env_pairs):
    cfg, err = load(path)
    if err:
        print(err)
        return 3
    entry = (cfg or {}).get("mcpServers", {}).get("regista")
    if not isinstance(entry, dict):
        return 1
    if entry == expected(binary, env_pairs):
        return 0
    print(entry.get("command", "(no command)") + ("" if entry.get("command") != binary else " (other arguments or env)"))
    return 2


def set_entry(path, binary, env_pairs):
    cfg, err = load(path)
    if err:
        print(err)
        return 3
    entry = expected(binary, env_pairs)
    existed = cfg is not None
    cfg = cfg if existed else {}
    servers = cfg.setdefault("mcpServers", {})
    if servers.get("regista") == entry:
        print("unchanged")
        return 0
    before = {k: v for k, v in servers.items() if k != "regista"}
    old = servers.get("regista")
    servers["regista"] = entry

    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    if existed:
        backup = f"{path}.regista-backup-{time.strftime('%Y%m%d-%H%M%S')}"
        shutil.copy2(path, backup)
        print(f"backup {backup}")
    tmp = path + ".regista-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write("\n")
    with open(tmp, encoding="utf-8") as f:
        check = json.load(f)   # raises on anything malformed: the original stays in place
    others = {k: v for k, v in check["mcpServers"].items() if k != "regista"}
    if check["mcpServers"].get("regista") != entry or others != before:
        os.remove(tmp)
        print("the written file did not read back as expected: original left untouched")
        return 1
    os.replace(tmp, path)
    print(f"replaced {old.get('command') if isinstance(old, dict) else old}" if old is not None else "added")
    return 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) >= 3 and a[0] in ("status", "set") and all("=" in p for p in a[3:]):
        sys.exit((status if a[0] == "status" else set_entry)(a[1], a[2], a[3:]))
    print(__doc__)
    sys.exit(64)
