#!/usr/bin/python3 -I
"""Reads scripts/engines.manifest.json (+ scripts/engines.lock for the download facts). No dependencies (Python 3.9).

  engines.py validate                 checks the manifest against itself and engines.lock (exit 1 + reasons)
  engines.py tier-for-ram <GB>        the tier a Mac with that much RAM gets (base / medium / pro)
  engines.py need-gb <tier|id> [--detail]  free disk the installer asks for on that tier (its installs + margin), or for
                                      one entry (install.sh --only), whole GB; --detail: "<need> <installs GB> <margin GB>"
  engines.py disk <tier>              the same, itemised
  engines.py steps <id>               the manual / first-use steps of an entry, one per line
  engines.py name <id>                the human name of an entry
  engines.py size <id>                its disk footprint in bytes (empty when unknown)
  engines.py field <id> <key>         one manifest field of an entry (empty when absent), e.g. licence, licenceUrl
  engines.py comfy-bytes              the disk ComfyUI and its model families take (set up by hand, Pro tier)
  engines.py others <id,id,...>       names of the available entries not in the list (doctor: "not checked")
  engines.py scripts <id>             the helper scripts of an entry (relative to the engines folder), one per line
  engines.py install-info <id>        method|step|formula|artifact ids (comma)|files (comma)|tier|status (install.sh --only)
  engines.py ids                      every entry id, one per line
  engines.py docs [--check] [--out F] writes docs/reference/engines.md (or F); --check exits 1 when the committed file is
                                      stale (scripts/reference-docs.sh runs it with --out, with the rest of the reference)
"""
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
MANIFEST = os.environ.get("REGISTA_MANIFEST", os.path.join(HERE, "engines.manifest.json"))
LOCK = os.environ.get("REGISTA_LOCK", os.path.join(HERE, "engines.lock"))
DOCS = os.path.join(REPO, "docs", "reference", "engines.md")
METHODS = ("installer", "homebrew", "system", "firstUse", "manual", "cloud")


def die(msg):
    sys.stderr.write("engines.py: %s\n" % msg)
    sys.exit(1)


def load_lock():
    rows = {}
    with open(LOCK) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            cols = line.split(" | ")
            if len(cols) < 7:
                continue
            rows[cols[0]] = dict(zip(("id", "version", "released", "pinned", "sha256", "size", "url"), cols))
    return rows


def load():
    try:
        with open(MANIFEST) as f:
            m = json.load(f)
    except ValueError as e:
        die("%s is not valid JSON: %s" % (MANIFEST, e))
    return m, load_lock()


def artifact_ids(entry, lock):
    out = []
    for a in entry.get("artifacts", []):
        if a.endswith(":"):
            out += [k for k in lock if k.startswith(a)]
        else:
            out.append(a)
    return out


def disk_bytes(entry, lock):
    """Installed footprint: diskBytes when present (None = unknown), else the sum of the artifacts' download sizes."""
    if "diskBytes" in entry:
        return entry["diskBytes"]
    ids = artifact_ids(entry, lock)
    if not ids:
        return None
    total = 0
    for a in ids:
        size = lock.get(a, {}).get("size", "-")
        if not size.isdigit():
            return None
        total += int(size)
    return total


def tier_of(entry, m):
    """The lowest tier whose RAM covers minRamGB (None = planned)."""
    ram = entry.get("minRamGB")
    if ram is None:
        return None
    best = None
    for t in m["tiers"]:
        if t["ramGB"] <= ram:
            best = t["id"]
    return best


def rank(tier, m):
    return [t["id"] for t in m["tiers"]].index(tier)


def tier_for_ram(gb, m):
    best = m["tiers"][0]["id"]
    for t in m["tiers"]:
        if gb >= t["detectFromGB"]:
            best = t["id"]
    return best


def installed_by_installer(entry, tier, m):
    """What scripts/install.sh installs without asking on that tier (optional apps are asked, not counted)."""
    t = tier_of(entry, m)
    return (entry.get("status") == "available" and not entry.get("optional")
            and entry["install"]["method"] in ("installer", "homebrew")
            and t is not None and rank(t, m) <= rank(tier, m))


def tier_items(tier, m, lock):
    return [(e, disk_bytes(e, lock)) for e in m["engines"] if installed_by_installer(e, tier, m)]


def need_gb(tier, m, lock):
    total = sum(b or 0 for _, b in tier_items(tier, m, lock))
    return int(math.ceil(total / 1e9 + m["diskMarginGB"]))


def gb(b):
    if b is None:
        return "?"
    if b == 0:
        return "–"
    if b < 1e8:
        return "%.0f MB" % (b / 1e6)
    return "%.2f GB" % (b / 1e9)


def validate(m, lock):
    errs = []
    ids = [e.get("id") for e in m.get("engines", [])]
    tiers = [t.get("id") for t in m.get("tiers", [])]
    if tiers != ["base", "medium", "pro"]:
        errs.append("tiers must be base, medium, pro in that order (got %s)" % tiers)
    for d in sorted(set(i for i in ids if ids.count(i) > 1)):
        errs.append("id %s appears twice" % d)
    for e in m.get("engines", []):
        i = e.get("id", "?")
        for k in ("id", "name", "role", "unlocks", "minRamGB", "licence", "nonCommercial", "install", "optional", "dependsOn", "status"):
            if k not in e:
                errs.append("%s: missing %s" % (i, k))
        if e.get("status") not in ("available", "planned"):
            errs.append("%s: status must be available or planned" % i)
        if e.get("minRamGB") is None and e.get("status") != "planned":
            errs.append("%s: minRamGB null is only allowed for planned entries" % i)
        if e.get("minRamGB") is not None and e["minRamGB"] < m["tiers"][0]["ramGB"]:
            errs.append("%s: minRamGB below the base tier" % i)
        if e.get("install", {}).get("method") not in METHODS:
            errs.append("%s: install.method must be one of %s" % (i, ", ".join(METHODS)))
        if e.get("install", {}).get("method") in ("manual", "firstUse", "cloud") and not e["install"].get("steps"):
            errs.append("%s: a %s entry needs install.steps" % (i, e["install"]["method"]))
        if not str(e.get("licence") or "").strip():
            errs.append("%s: no licence" % i)
        lic = str(e.get("licence") or "")
        if "NC" in lic.replace("-", " ").split() or "non-commercial" in lic.lower():
            if e.get("nonCommercial") is not True:
                errs.append("%s: licence %s is non-commercial but nonCommercial is not true" % (i, lic))
        for a in e.get("artifacts", []):
            if not artifact_ids({"artifacts": [a]}, lock) or (not a.endswith(":") and a not in lock):
                errs.append("%s: artifact %s is not in engines.lock" % (i, a))
        for d in e.get("dependsOn", []):
            if d not in ids:
                errs.append("%s: dependsOn %s is not in the manifest" % (i, d))
        for f in e.get("files", []):
            if not isinstance(f, str) or not f or f.startswith("/") or ".." in f.split("/"):
                errs.append("%s: files must be paths relative to the engines folder (got %r)" % (i, f))
        for f in e.get("scripts", []):
            if not isinstance(f, str) or not f or f.startswith("/") or ".." in f.split("/"):
                errs.append("%s: scripts must be paths relative to the engines folder (got %r)" % (i, f))
            elif not any(f == g or f.startswith(g + "/") for g in e.get("files", [])):
                errs.append("%s: script %s is not among its files" % (i, f))
            elif not os.path.isfile(os.path.join(REPO, "engines", f)):
                errs.append("%s: script %s is not in engines/" % (i, f))
        if "shipped" in e:
            sh = e["shipped"]
            if not isinstance(sh, dict) or set(sh) != {"licence", "bytes"}:
                errs.append("%s: shipped must be {\"licence\": …, \"bytes\": …}" % i)
            else:
                if not isinstance(sh["licence"], str) or not sh["licence"].strip():
                    errs.append("%s: shipped.licence is empty" % i)
                if not isinstance(sh["bytes"], int) or isinstance(sh["bytes"], bool) or sh["bytes"] <= 0:
                    errs.append("%s: shipped.bytes must be a positive whole number" % i)
        if e.get("artifacts") and "version" in e:
            errs.append("%s: version comes from engines.lock when artifacts are named; drop it" % i)
    named = set(a for e in m.get("engines", []) for a in artifact_ids(e, lock))
    for k in lock:
        if k not in named:
            errs.append("engines.lock row %s is not named by any manifest entry" % k)
    return errs


def docs(m, lock):
    L = []
    w = L.append
    w("# Engines by RAM")
    w("")
    w("<!-- Generated by scripts/reference-docs.sh (scripts/engines.py docs) from scripts/engines.manifest.json and "
      "scripts/engines.lock. Do not edit by hand: change the manifest and run scripts/reference-docs.sh (the pre-commit hook "
      "fails when this file is stale). -->")
    w("")
    w("Regista picks a tier from the Mac's memory (force it with `scripts/install.sh --tier base|medium|pro`). Each tier")
    w("adds to the one before. **Installer** = installed by `scripts/install.sh` on that tier; **asked** = optional, the")
    w("installer asks; **Homebrew** = installed with Homebrew by the installer; **first use** = downloaded by the engine")
    w("the first time it is needed; **manual** = set up by hand; **macOS** = part of the system; **cloud** = a paid web")
    w("service. Disk is the installed size (`?` = not known yet).")
    w("")
    w("**What it unlocks** is what needs the engine: while it is missing (or the Mac's tier is too low) the app keeps those")
    w("features visible but greyed, with the reason, and Settings › Engines lists every engine with its state and installs")
    w("the ones the installer can add.")
    w("The `id` is the one engines.status and `scripts/install.sh --only <id>` use.")
    w("")
    w("| Tier | RAM | Installer installs | Disk they take | Free disk the installer asks for | Everything on this tier, optional and manual included |")
    w("|---|---|---|---|---|---|")
    for t in m["tiers"]:
        items = tier_items(t["id"], m, lock)
        total = sum(b or 0 for _, b in items)
        every = [e for e in m["engines"] if e["status"] == "available" and tier_of(e, m) is not None
                 and rank(tier_of(e, m), m) <= rank(t["id"], m)]
        every_total = sum(disk_bytes(e, lock) or 0 for e in every)
        unknown = [e["name"] for e in every if disk_bytes(e, lock) is None]
        w("| %s | %d GB | %d items | %s | %d GB | %d items, %s%s |" % (
            t["name"], t["ramGB"], len(items), gb(total), need_gb(t["id"], m, lock), len(every), gb(every_total),
            " + unknown: " + ", ".join(unknown) if unknown else ""))
    w("")
    w("The free disk asked for = what the installer installs on that tier + a margin of %d GB (%s)." % (
        m["diskMarginGB"], m["diskMarginNote"]))
    w("")
    method_label = {"installer": "installer", "homebrew": "Homebrew", "system": "macOS", "firstUse": "first use",
                    "manual": "manual", "cloud": "cloud"}
    for t in m["tiers"]:
        rows = [e for e in m["engines"] if e["status"] == "available" and tier_of(e, m) == t["id"]]
        w("## %s · %d GB%s" % (t["name"], t["ramGB"], "" if t["id"] == "base" else " and more"))
        w("")
        w("| Engine | What it unlocks | RAM while running | Disk | Licence | How it is installed | Id |")
        w("|---|---|---|---|---|---|---|")
        for e in rows:
            how = method_label[e["install"]["method"]]
            if e.get("optional") and e["install"]["method"] == "installer":
                how += ", asked"
            elif e.get("optional"):
                how += ", optional"
            lic = e["licence"] + (" — **non-commercial**" if e["nonCommercial"] else "")
            if e.get("paid"):
                lic += " — **paid**"
            ram = "%g GB" % e["ramInUseGB"] if e.get("ramInUseGB") else "–"
            w("| %s | %s | %s | %s | %s | %s | `%s` |" % (e["name"], "; ".join(e["unlocks"]), ram, gb(disk_bytes(e, lock)), lic, how,
                                                       e["id"]))
        w("")
    shipped = [e for e in m["engines"] if "shipped" in e]
    if shipped:
        w("## Shipped inside a release build")
        w("")
        w("A release build (`scripts/release.sh`) ships these in `Regista.app/Contents/Helpers`, built by")
        w("`scripts/build-engines.sh` (see THIRD-PARTY-LICENSES.md): Settings › Engines and engines.status then show the")
        w("shipped build's licence and size below, not the installable one's above.")
        w("")
        w("| Engine | Shipped licence | Shipped size | Id |")
        w("|---|---|---|---|")
        for e in shipped:
            w("| %s | %s | %s | `%s` |" % (e["name"], e["shipped"]["licence"], gb(e["shipped"]["bytes"]), e["id"]))
        w("")
    planned = [e for e in m["engines"] if e["status"] == "planned"]
    if planned:
        w("## Planned, not built")
        w("")
        for e in planned:
            w("- **%s** (`%s`) — %s (%s)." % (e["name"], e["id"], e["role"], e["licence"]))
        w("")
    manual = [e for e in m["engines"] if e["install"]["method"] in ("manual", "firstUse") and e["status"] == "available"]
    w("## Set up outside the installer")
    w("")
    for e in manual:
        w("- **%s**: %s" % (e["name"], " ".join(e["install"]["steps"])))
    w("")
    return "\n".join(L)


def main(argv):
    if len(argv) < 2:
        die(__doc__)
    m, lock = load()
    cmd, args = argv[1], argv[2:]
    by_id = {e["id"]: e for e in m["engines"]}

    def entry(i):
        if i not in by_id:
            die("no entry %r in %s" % (i, MANIFEST))
        return by_id[i]

    def tier_arg(t):
        if t not in [x["id"] for x in m["tiers"]]:
            die("unknown tier %r" % t)
        return t

    if cmd == "validate":
        errs = validate(m, lock)
        for e in errs:
            print("✗ " + e)
        return 1 if errs else 0
    if cmd == "tier-for-ram":
        print(tier_for_ram(float(args[0]), m))
    elif cmd == "need-gb":
        if args[0] in by_id:
            print(int(math.ceil((disk_bytes(by_id[args[0]], lock) or 0) / 1e9 + m["diskMarginGB"])))
        elif args[1:2] == ["--detail"]:
            t = tier_arg(args[0])
            installs = sum(b or 0 for _, b in tier_items(t, m, lock)) / 1e9
            print("%d %.1f %g" % (need_gb(t, m, lock), installs, m["diskMarginGB"]))
        else:
            print(need_gb(tier_arg(args[0]), m, lock))
    elif cmd == "disk":
        t = tier_arg(args[0])
        for e, b in tier_items(t, m, lock):
            print("%-28s %s" % (e["id"], gb(b)))
        print("%-28s %d GB margin" % ("+", m["diskMarginGB"]))
        print("%-28s %d GB" % ("= need", need_gb(t, m, lock)))
    elif cmd == "steps":
        for s in entry(args[0])["install"].get("steps", []):
            print(s)
    elif cmd == "name":
        print(entry(args[0])["name"])
    elif cmd == "size":
        b = disk_bytes(entry(args[0]), lock)
        print("" if b is None else b)
    elif cmd == "field":
        v = entry(args[0]).get(args[1])
        print("" if v is None else v)
    elif cmd == "comfy-bytes":
        print(sum(disk_bytes(e, lock) or 0 for e in m["engines"] if e["id"] == "comfyui" or "comfyui" in e.get("dependsOn", [])))
    elif cmd == "others":
        known = set(args[0].split(",")) if args else set()
        print(", ".join(e["name"] for e in m["engines"] if e["status"] == "available" and e["id"] not in known))
    elif cmd == "scripts":
        for f in entry(args[0]).get("scripts", []):
            print(f)
    elif cmd == "install-info":
        e = entry(args[0])
        i = e["install"]
        print("|".join([i["method"], i.get("step", ""), i.get("formula", ""), ",".join(artifact_ids(e, lock)),
                        ",".join(e.get("files", [])), tier_of(e, m) or "", e["status"]]))
    elif cmd == "ids":
        for e in m["engines"]:
            print(e["id"])
    elif cmd == "docs":
        text = docs(m, lock) + "\n"
        out = args[args.index("--out") + 1] if "--out" in args else DOCS
        if "--check" in args:
            try:
                with open(out) as f:
                    current = f.read()
            except FileNotFoundError:
                current = None
            if current != text:
                die("%s is out of date with scripts/engines.manifest.json: run scripts/reference-docs.sh" % os.path.relpath(out, REPO))
            return 0
        os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
        with open(out, "w") as f:
            f.write(text)
        print(out)
    else:
        die("unknown command %r\n%s" % (cmd, __doc__))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
