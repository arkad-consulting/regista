#!/bin/bash
# G0 golden test (issue #10): a fresh headless Claude Code session with ONLY the regista MCP tools (no shell,
# no file tools) edits a raw talking-head take into a captioned 9:16 reel; then the golden checks run on what
# it exported and <outdir>/g0-report.md is written.
#
#   scripts/g0.sh <raw.mov> <script.md> <outdir> [--smoke] [--checks-only] [--model opus] [--effort high]
#                 [--max-budget-usd N] [--reference-dir DIR]
#
#   <outdir>/media/      fresh media root: a clone of the take + the script (the session's only footage)
#   <outdir>/work/       output directory: the agent's project and exports (regista-mcp's working directory)
#   <outdir>/mcp.json    the generated MCP config (absolute paths, release binary)
#   <outdir>/session.jsonl, session.err   the session (stream-json)
#   <outdir>/checks/     raw JSON of every check;  <outdir>/g0-report.md   the report
#
# --smoke         a ~1 minute wiring check: the session only lists the tools/files and looks at one contact sheet.
# --checks-only   skip the session, re-run the checks and the report on an existing <outdir>.
# --reference-dir where reel-v1.mp4 and work/{segments,keywords}.json live (default: the parent of the raw's folder).
#
# The session ignores user settings (hooks, plugins, CLAUDE.md): --setting-sources project,local and a working
# directory without project settings, so it starts as fresh as Claude Code allows with OAuth.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 3 ] || usage
RAW="$1"; SCRIPT="$2"; OUT="$3"; shift 3
SMOKE=0; CHECKS_ONLY=0; MODEL=opus; EFFORT=high; BUDGET=""; REFDIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --smoke) SMOKE=1 ;;
    --checks-only) CHECKS_ONLY=1 ;;
    --model) MODEL="$2"; shift ;;
    --effort) EFFORT="$2"; shift ;;
    --max-budget-usd) BUDGET="$2"; shift ;;
    --reference-dir) REFDIR="$2"; shift ;;
    *) usage ;;
  esac
  shift
done

abs() { python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$1"; }
RAW="$(abs "$RAW")"; SCRIPT="$(abs "$SCRIPT")"; OUT="$(abs "$OUT")"
[ -f "$RAW" ] || { echo "g0: no take at $RAW" >&2; exit 1; }
[ -f "$SCRIPT" ] || { echo "g0: no script at $SCRIPT" >&2; exit 1; }
REFDIR="$(abs "${REFDIR:-$(dirname "$(dirname "$RAW")")}")"
case "$OUT/" in "$(dirname "$RAW")/"*) echo "g0: <outdir> must not be inside the footage folder $(dirname "$RAW")" >&2; exit 1 ;; esac

MEDIA="$OUT/media"; WORK="$OUT/work"; CHECKS="$OUT/checks"
if [ "$CHECKS_ONLY" = 0 ]; then
  [ ! -e "$OUT/session.jsonl" ] || { echo "g0: $OUT already has a session — use a new <outdir> or --checks-only" >&2; exit 1; }
  mkdir -p "$MEDIA" "$WORK"
  # APFS clone (instant, independent of the original); plain copy elsewhere. Never a link to the footage.
  for f in "$RAW" "$SCRIPT"; do
    [ -e "$MEDIA/$(basename "$f")" ] || cp -c "$f" "$MEDIA/" 2>/dev/null || cp "$f" "$MEDIA/"
  done
fi
mkdir -p "$CHECKS"

echo "g0: building the release binaries…" >&2
MCP_BIN="$("$REPO/scripts/build-mcp.sh")"
ENGINE_BIN="$(dirname "$MCP_BIN")/regista-engine"

python3 -I - "$OUT/mcp.json" "$MCP_BIN" "$MEDIA" "$WORK" <<'PY'
import json, sys
path, binary, media, work = sys.argv[1:]
json.dump({"mcpServers": {"regista": {"type": "stdio", "command": binary,
                                      "args": ["--media-root", media, "--output-dir", work], "env": {}}}},
          open(path, "w"), indent=2)
PY

if [ "$SMOKE" = 1 ]; then
  TASK="Questo è solo un test di collegamento. Chiama engines_status e media_list. Poi crea un progetto nella outputDirectory, \
importa il video, aggiungi una traccia video, metti sulla traccia i primi 10 secondi del video (timeline_place) e chiama \
frame_contactSheet con count 4. Rispondi in due righe: quanti strumenti regista hai, e cosa vedi nell'immagine. Non fare altro."
else
  TASK="Monta questo girato come reel talking head per WeSites: scegli le riprese migliori, togli le pause, voce pulita, \
zoom alternati, sottotitoli nello stile approvato con le parole chiave giuste. Guarda il risultato e correggi quello che \
non va. Esporta 9:16, srt e progetto Shotcut."
fi
printf '%s\n' "$TASK" > "$OUT/task.txt"

if [ "$CHECKS_ONLY" = 0 ]; then
  echo "g0: session started $(date '+%H:%M:%S') (model $MODEL, effort $EFFORT) → $OUT/session.jsonl" >&2
  extra=()
  [ -n "$BUDGET" ] && extra+=(--max-budget-usd "$BUDGET")
  start=$(date +%s)
  # Unset the variables of an enclosing Claude Code session so this one starts on its own.
  set +e
  (cd "$WORK" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION \
      -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_PID \
      -u CLAUDE_AGENT_SDK_VERSION -u AI_AGENT \
      MAX_MCP_OUTPUT_TOKENS=60000 MCP_TOOL_TIMEOUT=1800000 \
    claude -p "$TASK" \
      --mcp-config "$OUT/mcp.json" --strict-mcp-config \
      --tools "" \
      --allowedTools "mcp__regista" \
      --disallowedTools "Bash,Read,Write,Edit,MultiEdit,NotebookEdit,Glob,Grep,WebFetch,WebSearch,Task,Agent,Skill" \
      --permission-mode dontAsk \
      --setting-sources project,local --disable-slash-commands \
      --model "$MODEL" --effort "$EFFORT" \
      --output-format stream-json --verbose \
      ${extra[@]+"${extra[@]}"} \
      < /dev/null > "$OUT/session.jsonl" 2> "$OUT/session.err")
  status=$?
  set -e
  echo "$(( $(date +%s) - start ))" > "$OUT/session.seconds"
  echo "g0: session ended $(date '+%H:%M:%S') with exit $status after $(cat "$OUT/session.seconds") s" >&2
fi

# The checks run on what the session left behind: the exported mp4 (the last successful export_render) and the
# saved project (needed by the source-aligned compare, takes.compare, caption timing and sync).
python3 -I - "$OUT" "$ENGINE_BIN" "$REFDIR" "$SMOKE" <<'PY'
import json, os, re, subprocess, sys, glob

out, engine, refdir, smoke = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
checks_dir = os.path.join(out, "checks")

# --- the session -------------------------------------------------------------------------------------------
calls, results, final, init, images_seen = [], {}, None, None, 0
texts = []
for line in open(os.path.join(out, "session.jsonl"), errors="replace"):
    try: m = json.loads(line)
    except ValueError: continue
    if m.get("type") == "system" and m.get("subtype") == "init": init = m
    elif m.get("type") == "assistant":
        for b in m.get("message", {}).get("content", []):
            if b.get("type") == "tool_use": calls.append({"id": b["id"], "name": b["name"], "input": b.get("input", {})})
            elif b.get("type") == "text" and b.get("text", "").strip(): texts.append(b["text"].strip())
    elif m.get("type") == "user":
        content = m.get("message", {}).get("content", [])
        if not isinstance(content, list): continue
        for b in content:
            if b.get("type") != "tool_result": continue
            parts = b.get("content")
            text = parts if isinstance(parts, str) else "\n".join(p.get("text", "") for p in (parts or []) if p.get("type") == "text")
            n_img = 0 if isinstance(parts, str) else sum(1 for p in (parts or []) if p.get("type") == "image")
            images_seen += n_img
            results[b.get("tool_use_id")] = {"error": bool(b.get("is_error")), "text": text, "images": n_img}
    elif m.get("type") == "result": final = m

def short(name): return name.replace("mcp__regista__", "")
def parsed(c):
    r = results.get(c["id"])
    if not r or r["error"]: return None
    try: return json.loads(r["text"])
    except ValueError: return None
def ok_calls(name): return [c for c in calls if short(c["name"]) == name and c["id"] in results and not results[c["id"]]["error"]]

# --- what it produced ----------------------------------------------------------------------------------------
def last_path(tool):
    cs = ok_calls(tool)
    if not cs: return None
    p = (parsed(cs[-1]) or {}).get("path") or cs[-1]["input"].get("path")
    return p if p and os.path.isabs(p) else (os.path.join(out, "work", p) if p else None)
mp4, srt, mlt = last_path("export_render"), last_path("export_srt"), last_path("export_mlt")
project = None
for c in reversed(ok_calls("project_save")):
    project = (parsed(c) or {}).get("path"); break
if not project:
    found = sorted(glob.glob(os.path.join(out, "work", "**", "*.regista"), recursive=True), key=os.path.getmtime)
    project = found[-1] if found else None

def engine_exec(name, cmd, params, with_project=True):
    args = [engine, "exec", cmd, json.dumps(params)]
    if with_project:
        if not project: return {"skipped": "no saved project"}
        args += ["--project", project]
    p = subprocess.run(args, capture_output=True, text=True)
    r = json.loads(p.stdout) if p.returncode == 0 and p.stdout.strip().startswith("{") else {"error": (p.stderr or p.stdout).strip()[-800:]}
    json.dump(r, open(os.path.join(checks_dir, name + ".json"), "w"), indent=2)
    return r

ref_mp4 = os.path.join(refdir, "reel-v1.mp4")
ref_segments = os.path.join(refdir, "work", "segments.json")
ref_keywords = os.path.join(refdir, "work", "keywords.json")
c = {}
if not smoke and mp4 and os.path.exists(mp4):
    c["state"] = engine_exec("state", "project.state", {})
    c["probe"] = engine_exec("probe", "media.probe", {"path": mp4}, with_project=False)
    if os.path.exists(ref_mp4) and os.path.exists(ref_segments):
        c["compare"] = engine_exec("compare", "media.compare", {"candidate": mp4, "reference": ref_mp4, "align": "source",
                                                              "referenceSegments": ref_segments, "samples": 48})
        if "error" in c["compare"] or "skipped" in c["compare"]:
            c["compareTime"] = engine_exec("compare-time", "media.compare", {"candidate": mp4, "reference": ref_mp4, "samples": 48}, with_project=False)
    if os.path.exists(ref_segments):
        c["takes"] = engine_exec("takes-compare", "takes.compare", {"reference": ref_segments})
    c["timing"] = engine_exec("caption-timing", "captions.checkTiming", {"path": mp4, "preset": "9:16"})
    c["sync"] = engine_exec("sync", "media.checkSync", {"path": mp4})
    c["captions"] = engine_exec("captions", "captions.get", {})
    # Loudness of the file itself: EBU R128 with ffmpeg (the export result's own measurement is reported too).
    p = subprocess.run(["ffmpeg", "-nostats", "-i", mp4, "-af", "ebur128=peak=true", "-f", "null", "-"], capture_output=True, text=True)
    summary = p.stderr[p.stderr.rfind("Summary:"):]
    I = re.search(r"I:\s+(-?[\d.]+) LUFS", summary); P = re.search(r"Peak:\s+(-?[\d.]+) dBFS", summary)
    c["loudness"] = {"integrated": float(I.group(1)) if I else None, "truePeak": float(P.group(1)) if P else None}
    json.dump(c["loudness"], open(os.path.join(checks_dir, "loudness.json"), "w"))

# --- report --------------------------------------------------------------------------------------------------
def g(d, path, default=None):
    for k in path.split("."):
        if isinstance(d, dict): d = d.get(k)
        elif isinstance(d, list) and k.isdigit() and int(k) < len(d): d = d[int(k)]
        else: return default
    return default if d is None else d
def verdict(ok): return "PASS" if ok else ("—" if ok is None else "FAIL")

L = []
L.append(f"# G0 report — {'smoke' if smoke else 'talking-head reel via MCP only'}\n")
L.append(f"Task: «{open(os.path.join(out, 'task.txt')).read().strip()}»\n")
secs = open(os.path.join(out, "session.seconds")).read().strip() if os.path.exists(os.path.join(out, "session.seconds")) else "?"
if init:
    tools = init.get("tools", [])
    other = [t for t in tools if not t.startswith("mcp__regista__")]
    L.append(f"Session: model `{init.get('model')}`, {len(tools)} tools ({len(tools) - len(other)} regista"
             + (f", others: {', '.join(other)}" if other else ", no others") + f"), MCP servers: "
             + ", ".join(f"{s['name']} ({s['status']})" for s in init.get("mcp_servers", [])))
if final:
    L.append(f"Result: {final.get('subtype')}, {final.get('num_turns')} turns, {secs} s wall, "
             f"{round(final.get('duration_ms', 0) / 1000)} s session, cost ${final.get('total_cost_usd', 0):.2f}")
L.append(f"Images returned to the model: {images_seen}\n")

# Tools called
from collections import Counter
errors = [c_ for c_ in calls if results.get(c_["id"], {}).get("error")]
L.append(f"## Tools called ({len(calls)} calls, {len(errors)} errors)\n")
counts = Counter(short(c_["name"]) for c_ in calls)
L.append("| Tool | Calls |\n|---|---|")
for name, n in counts.most_common(): L.append(f"| {name} | {n} |")
L.append("\nOrder: " + " → ".join(short(c_["name"]) + ("✗" if results.get(c_["id"], {}).get("error") else "") for c_ in calls) + "\n")
if errors:
    L.append("Errors:\n")
    for e in errors[:15]: L.append(f"- `{short(e['name'])}` {json.dumps(e['input'], ensure_ascii=False)[:160]} → {results[e['id']]['text'][:200]}")
    L.append("")

if not smoke:
    L.append("## Outputs\n")
    for label, p in [("mp4", mp4), ("srt", srt), ("Shotcut", mlt), ("project", project)]:
        L.append(f"- {label}: {p or 'MISSING'}" + ("" if not p or os.path.exists(p) else " (not on disk)"))
    L.append("")

    # Takes
    L.append("## Takes chosen vs the manual edit\n")
    selects = [c_["input"] for c_ in ok_calls("takes_select")]
    if selects: L.append("takes_select calls: " + ", ".join(json.dumps(s) for s in selects) + "\n")
    tk = c.get("takes", {})
    if tk.get("lines"):
        sm = tk.get("summary", {})
        L.append(f"Same take: **{sm.get('sameTake')}/{sm.get('lines')}** lines; cut error median {sm.get('medianAbsErrMs')} ms, "
                 f"max {sm.get('maxAbsErrMs')} ms, {round(100 * (sm.get('within100ms') or 0))}% of {sm.get('boundaries')} boundaries ≤ 100 ms\n")
        L.append("| Line | Agent take | Manual take | Same | Agent in–out | Manual in–out | Err in / out ms |\n|---|---|---|---|---|---|---|")
        for r in tk["lines"]:
            L.append(f"| {r['line']} | {r.get('autoTake')} | {r.get('manualTake')} | {'yes' if r.get('sameTake') else 'NO'} | "
                     f"{r.get('autoIn')}–{r.get('autoOut')} | {r.get('manualIn')}–{r.get('manualOut')} | {r.get('inErrMs')} / {r.get('outErrMs')} |")
        L.append("")
    else:
        L.append(f"takes.compare: {json.dumps(tk)[:400]}\n")

    # Keywords
    L.append("## Caption keywords\n")
    caps = c.get("captions", {})
    chosen = caps.get("keywords") or []
    manual = json.load(open(ref_keywords)) if os.path.exists(ref_keywords) else {}
    mk = manual.get("keywords", [])
    L.append(f"- Agent ({len(chosen)}): {', '.join(chosen) or '—'}")
    L.append(f"- Agent fixes: {json.dumps(caps.get('fixes', {}), ensure_ascii=False)}")
    L.append(f"- Manual ({len(mk)}): {', '.join(mk)}; fixes {json.dumps(manual.get('fixes', {}), ensure_ascii=False)}")
    if mk: L.append(f"- Overlap: {len(set(chosen) & set(mk))}/{len(mk)} ({', '.join(sorted(set(chosen) & set(mk)))}); "
                    f"shown on screen: {caps.get('keywordsShown')}; chunks {caps.get('chunks')}, words {caps.get('words')}, stale {caps.get('stale')}")
    L.append("")

    # Numbers
    timeline = g(c, "state.duration")
    dur = g(c, "probe.duration")
    rows = []
    if dur is not None:
        ok = 35 <= dur <= 70 and (timeline is None or abs(dur - timeline) <= 0.067)
        rows.append(("duration", f"{dur:.3f} s, {g(c, 'probe.video.frames')} frames (timeline {timeline}; reel-v1 49.8 s)", "35–70 s, = timeline ±2 frames", verdict(ok)))
        fmt = f"{g(c,'probe.video.width')}×{g(c,'probe.video.height')} {g(c,'probe.video.codec')} {g(c,'probe.video.profile')} {g(c,'probe.video.pixFmt')} {g(c,'probe.video.fps')} faststart={g(c,'probe.faststart')}; {g(c,'probe.audio.codec')} {g(c,'probe.audio.sampleRate')}"
        rows.append(("format", fmt, "1080×1920 H.264 High yuv420p 30/1 faststart, AAC 48k",
                     verdict(g(c,'probe.video.width') == 1080 and g(c,'probe.video.height') == 1920 and g(c,'probe.video.profile') == 'High' and g(c,'probe.faststart') is True)))
    s = g(c, "compare.ssim.mean")
    if s is not None:
        rows.append(("SSIM vs reel-v1 (source-aligned)", f"mean {s} (min {g(c,'compare.ssim.min')}, {g(c,'compare.samples')} frames), PSNR {g(c,'compare.psnr.mean')}", "≥ 0.90", verdict(s >= 0.90)))
    elif g(c, "compareTime.ssim.mean") is not None:
        rows.append(("SSIM vs reel-v1 (same times)", f"mean {g(c,'compareTime.ssim.mean')}", "info (source-aligned failed)", "—"))
    elif "compare" in c:
        rows.append(("SSIM vs reel-v1", json.dumps(c["compare"])[:200], "≥ 0.90", "FAIL"))
    if "timing" in c:
        t = c["timing"]
        rows.append(("caption timing", f"pass={t.get('pass')}, max error {t.get('maxAbsError')} frames, {t.get('words')} words, undetected {t.get('undetected')}, band {g(t,'band.inkTop')}–{g(t,'band.inkBottom')} inside={g(t,'band.inside')}" if "error" not in t else t["error"][:200],
                     "±1 frame, inside the band", verdict(t.get("pass") is True and g(t, "band.inside") is True)))
    lo = c.get("loudness", {})
    if lo.get("integrated") is not None:
        export_lo = (parsed(ok_calls("export_render")[-1]) or {}).get("loudness", {}) if ok_calls("export_render") else {}
        rows.append(("loudness", f"{lo['integrated']} LUFS, true peak {lo['truePeak']} dBTP (export result: {export_lo.get('integrated')} / {export_lo.get('truePeak')})",
                     "−15 ±0.5, ≤ −1.5", verdict(abs(lo["integrated"] + 15) <= 0.5 and lo["truePeak"] <= -1.5)))
    if "sync" in c:
        sy = c["sync"]
        rows.append(("A/V sync", f"{sy.get('lagMs')} ms ({sy.get('lagFrames')} frames), correlation {sy.get('correlation')}" if "error" not in sy else sy["error"][:200],
                     "< 1 frame", verdict(sy.get("lagFrames") is not None and abs(sy["lagFrames"]) < 1)))
    L.append("## Numbers\n")
    if rows:
        L.append("| Check | Result | Gate | |\n|---|---|---|---|")
        for r in rows: L.append("| " + " | ".join(str(x) for x in r) + " |")
    else:
        L.append("No exported mp4 found: no checks ran.")
    L.append("\nRaw JSON: `checks/`.\n")

L.append("## The session's final message\n")
L.append((final or {}).get("result") or (texts[-1] if texts else "(none)"))
L.append("")
open(os.path.join(out, "g0-report.md"), "w").write("\n".join(L))
print(os.path.join(out, "g0-report.md"))
PY
