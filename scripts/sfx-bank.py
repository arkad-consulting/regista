#!/usr/bin/env python3
"""Renders the sound-effect bank Regista ships (Resources/SFX) from earshot's bank of sounds made in code.

earshot (https://github.com/Leonxlnx/earshot, MIT) stores ~200 sound effects as code (render blocks: recipe, parameters,
seed), rendered by id with numpy / scipy, no models, no network. Regista does not run Python for sound effects: this
script renders each sound once, at its delivered take (the entry's own seed, sample peak -1 dBFS, 48 kHz), keeps only
the takes that pass earshot's model-free audit (clicks, cut tails, clipping, comb ring, rising synth whips), encodes
them as AAC 160 kb/s .m4a with macOS's afconvert (decoded by ffmpeg and AVFoundation sample-exact: same length, no
offset) and writes Resources/SFX/manifest.json: per sound its file, sha256, group, category, length, onset and peak
times, its place in the browser (order), cue kinds, earshot's description and, for the sounds fitted from CC0 recordings, the recording's credit.
scripts/engines.lock pins manifest.json's sha256 (repo: row), so the manifest pins every file.

Run with the Python of an earshot checkout at the pinned release (0.3.0, commit 0121eb6), never newer than two weeks:
  <earshot>/.venv/bin/python -I scripts/sfx-bank.py Resources/SFX
"""
import hashlib, json, os, shutil, subprocess, sys, tempfile, wave

import numpy as np
from earshot.forge import bank

RELEASE = {"name": "earshot", "version": "0.3.0", "commit": "0121eb67ee9bf599189a408909b9e37c1f26615a",
           "released": "2026-10-18", "url": "https://github.com/Leonxlnx/earshot", "licence": "MIT",
           "copyright": "Copyright (c) 2026 Leon Lin"}

# The browser's groups (the app names them in every language), from earshot's 36 categories.
GROUPS = [
    ("whoosh", ["whoosh_fast", "whoosh_big", "pro_whoosh_big", "swish", "swipe"]),
    ("ui", ["click", "pro_click", "hover_tick", "pro_hover_tick", "tap", "pro_tap", "toggle"]),
    ("pop", ["pop", "pro_pop", "pro_pop_in"]),
    ("impact", ["impact", "pro_impact", "sub_drop", "pro_sub_drop"]),
    ("rise", ["riser", "pro_riser", "downlifter", "pro_zip"]),
    ("chime", ["notify", "pro_notify", "shimmer", "pro_shimmer", "pluck"]),
    ("logo", ["logo_sting", "pro_logo_sting"]),
    ("glitch", ["glitch", "pro_glitch"]),
    ("typing", ["typing_key", "pro_typing_key", "pro_typing_run"]),
]
# Fitted sounds (fit/<role>/<name>) by role.
FIT_GROUPS = {"bell": "chime", "click": "ui", "hit": "impact", "key": "typing", "key.space": "typing",
              "land.light": "ui", "pop": "pop", "snap": "ui", "tick": "ui", "whoosh.short": "whoosh"}


def group_of(row):
    if row["category"] == "fit":
        return FIT_GROUPS[row["id"].split("/")[1]]
    for g, cats in GROUPS:
        if row["category"] in cats:
            return g
    raise SystemExit("no group for category %s: add it to GROUPS" % row["category"])


def order_of(row):
    """the browser's order inside a group: the categories as GROUPS lists them, the fitted sounds last"""
    for _, cats in GROUPS:
        if row["category"] in cats:
            return cats.index(row["category"])
    return 99


def write_wav(path, y):
    y = np.clip(np.asarray(y, np.float64), -1, 1)
    channels = 1 if y.ndim == 1 else y.shape[1]
    with wave.open(path, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(bank.SR)
        w.writeframes((y * 32767).round().astype("<i2").tobytes())


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    out = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "Resources/SFX")
    if not shutil.which("afconvert"):
        raise SystemExit("afconvert (macOS) not found")
    for name in os.listdir(out) if os.path.isdir(out) else []:
        p = os.path.join(out, name)
        if os.path.isdir(p):
            shutil.rmtree(p)   # the rendered sounds; LICENSE / CREDITS stay
    os.makedirs(out, exist_ok=True)
    sounds, skipped = {}, []
    with tempfile.TemporaryDirectory() as tmp:
        for row in bank.list_sounds():
            sid = row["id"]
            y, meta = bank.render(sid)
            if not meta["checks"]["ok"]:
                skipped.append((sid, meta["checks"]["summary"]))
                continue
            wav = os.path.join(tmp, "take.wav")
            write_wav(wav, y)
            rel = sid + ".m4a"
            dst = os.path.join(out, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "160000", "-q", "127", wav, dst], check=True)
            entry = {"file": rel, "sha256": sha256(dst), "group": group_of(row), "category": row["category"],
                     "member": row["member"], "order": order_of(row), "duration": round(len(y) / bank.SR, 4), "onset": meta["onset_s"],
                     "peak": meta["peak_s"], "kinds": row["kinds"], "description": row["notes"]}
            if row.get("source"):
                entry["credit"] = {k: row["source"][k] for k in ("title", "author", "license", "url")}
            sounds[sid] = entry
    doc = {"schema": 1, "source": dict(RELEASE, bank=bank.VERSION),
           "about": "Sound effects made in code by earshot (MIT; the fitted sounds come from CC0 recordings, credited per "
                    "sound). Rendered by scripts/sfx-bank.py: every take that passes earshot's audit, AAC 160 kb/s, "
                    "48 kHz, sample peak -1 dBFS.",
           "groups": [g for g, _ in GROUPS], "skipped": [s for s, _ in skipped], "sounds": sounds}
    with open(os.path.join(out, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1, ensure_ascii=False, sort_keys=True)
        f.write("\n")
    size = sum(os.path.getsize(os.path.join(d, n)) for d, _, ns in os.walk(out) for n in ns)
    print("%d sounds in %s (%.1f MB), %d left out by the audit:" % (len(sounds), out, size / 1e6, len(skipped)))
    for sid, why in skipped:
        print("  " + why)


if __name__ == "__main__":
    main()
