#!/bin/bash
# Renders every screen of the running Regista app (ui.screenshot over the engine socket, offscreen: what the user
# looks at does not change) at 1920×1050 into <outdir>/<workspace>.png and prints the paths. Used to review each node
# of the manual-interface work (issues #45–#64).
# Usage: scripts/ui-shots.sh <outdir> [--lang it|en|fr|pt | --private-lang it|en|fr|pt] [--size WxH] [--real] [workspace …]
#   --real captures the real window as it is on screen instead, native title bar and traffic lights included
#   (ui.screenshot real: ScreenCaptureKit, needs Regista's Screen Recording permission, never asks), into
#   <outdir>/real-window.png, and prints its geometry (window and title-row height, traffic lights, content top).
#   --lang en relaunches the app in that language (-AppleLanguages) for the renders, then relaunches it as before.
#   --private-lang fr never touches a running Regista: it copies build/Regista.app (or $REGISTA_PRIVATE_APP) to a temporary
#   folder under its own bundle id (its own user defaults: no restored tabs, no recent projects of the owner's), signs the
#   copy ad hoc, starts it in that language on a private engine socket, renders, and stops that process only (by its pid).
#   Workspaces default to every screen of the window shell (S1 #75): each activity (home, record, media, texts, audio,
#   voice, graphics, generate, export), the editor at both levels (edit-pro, edit-semplice), the right panel's three tabs
#   (panel-prompter, panel-claude, panel-inspector) and settings; edit-tabs (the Pro editor with three project tabs: the
#   active one and two sample tabs, S2 #76 — no other project is opened); then the Registra states (issue #50):
#   record-screen-only, record-screen-face, record-face, record-voice (the four presets as the permissions really are),
#   record-open-screen, record-open-camera (screen + face with that row's choices open, as if macOS allowed everything),
#   record-displays (screen only with the display picker drawn for four sample displays);
#   inspector-<video|audio|overlay|multi|none> (E1 #53) on a synthetic project; inspector-screen (R2 #51: the Schermo
#   section of a synthetic screen + camera session, framed bubble, drawn cursor, key badges and zoom on, 2200 px tall so the
#   whole section shows), inspector-screen-<split|stack|face|cutout|screen> (one project per face layout; stack in 9:16)
#   and inspector-screen-clip (the screen clip selected: Schermo beside the clip's own sections and the picture fades);
#   and the voice screens from sample data (V1 #61, V2 #62): voice-<state> (the Voce tab: engine-missing, no-profile,
#   no-voice, ready, rendering, placed, lexicon), voice-setup-<step> (the recording flow: profile, language, consent,
#   record, check-good, check-poor, train, train-low-ram, training) and settings-voice (Settings › Profilo e voce);
#   then the steps from a clip to captions from sample data (E2 #54): texts-<state> (Testi e sottotitoli › Passi: fresh,
#   transcribing, transcribed, cut, keywords, captions, stale, doall, failed), jobs (the status bar's jobs list open over the
#   Pro editor, sample jobs in two tabs) and jobs-closed (the compact jobs item only);
#   then Impostazioni (M2 #59), each tab at the window's own size: settings-general, settings-engines, settings-claude,
#   settings-shortcuts (settings-voice above), and settings-engines-<base|medium|pro> (Motori with the Mac's real engine
#   states drawn as on that tier, for the render only: engines.json is never touched);
#   then music, sound effects and level (E3 #55) on synthetic projects made here in a temporary folder: audio-empty (the mix,
#   no music yet), audio-music (music added by audio.addMusic, ducked, its clip in the Ispettore, a sample "ducking OK"),
#   audio-sfx (the sound-effect browser, the Whoosh group open, one sound playing) and audio-loud (a sample level too loud).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:?usage: scripts/ui-shots.sh <outdir> [--lang it|en] [--size WxH] [--real] [workspace …]}"
shift
LANG_ARG="" PRIVATE_LANG="" W=1920 H=1050 LIST=() REAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --lang) LANG_ARG="${2:?--lang it|en|fr|pt}"; shift 2 ;;
    --private-lang) PRIVATE_LANG="${2:?--private-lang it|en|fr|pt}"; shift 2 ;;
    --size) W="${2%x*}"; H="${2#*x}"; shift 2 ;;
    --real) REAL=1; shift ;;
    *) LIST+=("$1"); shift ;;
  esac
done
[ ${#LIST[@]} -gt 0 ] || LIST=(home record media texts audio voice graphics generate export edit-pro edit-semplice edit-tabs settings
                               panel-prompter panel-claude panel-inspector
                               record-screen-only record-screen-face record-face record-voice record-open-screen
                               record-open-camera record-displays effects-filters effects-adjust effects-effects effects-styles
                               brand-inspector brandkits brandkit-editor teleprompter teleprompter-mirror
                               voice-engine-missing voice-no-profile voice-no-voice voice-ready voice-rendering voice-placed voice-lexicon
                               voice-setup-profile voice-setup-language voice-setup-consent voice-setup-record voice-setup-check-good
                               voice-setup-check-poor voice-setup-train voice-setup-train-low-ram voice-setup-training settings-voice
                               inspector-video inspector-audio inspector-overlay inspector-multi inspector-none
                               inspector-screen inspector-screen-split inspector-screen-stack inspector-screen-face
                               inspector-screen-cutout inspector-screen-screen inspector-screen-clip
                               texts-fresh texts-transcribing texts-transcribed texts-cut texts-keywords texts-captions texts-stale
                               texts-doall texts-failed jobs jobs-closed
                               settings-general settings-engines settings-claude settings-shortcuts
                               settings-engines-base settings-engines-medium settings-engines-pro
                               audio-empty audio-music audio-sfx audio-loud)
SOCK="${REGISTA_ENGINE_SOCKET:-$HOME/Library/Application Support/Regista/engine.sock}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

app_path() {   # the running copy, else the installed one
  local pid; pid="$(pgrep -x Regista | head -1)"
  if [ -n "$pid" ]; then ps -o comm= -p "$pid" | sed 's#/Contents/MacOS/Regista$##'; return; fi
  for d in /Applications "$HOME/Applications"; do [ -d "$d/Regista.app" ] && { echo "$d/Regista.app"; return; }; done
}
socket_call() {   # socket_call <command> [json params] → the reply line
  local params="${2:-}"; [ -n "$params" ] || params='{}'
  python3 -I - "$SOCK" "$1" "$params" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile('rwb')
f.write((json.dumps({'op': 'execute', 'command': sys.argv[2], 'params': json.loads(sys.argv[3])}) + '\n').encode()); f.flush()
print(f.readline().decode().strip())
PY
}
wait_socket() {   # until the app answers on its socket (60 s)
  for _ in $(seq 1 120); do
    python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])' "$SOCK" 2>/dev/null && return 0
    sleep 0.5
  done
  echo "Regista did not come up on $SOCK" >&2; exit 1
}
relaunch() {   # relaunch [args…]: quit the running app politely, open it again with these arguments
  # Never kill: a quit that does not finish (a dialog open, a save prompt) stops the script instead (#83).
  local app n; app="$(app_path)"
  [ -n "$app" ] || { echo "Regista.app not found" >&2; exit 1; }
  n="$(pgrep -x Regista | wc -l | tr -d ' ')"
  if [ "$n" -gt 1 ]; then
    echo "more than one Regista is running: --lang quits none of them (close the extra copies first)" >&2; exit 1
  fi
  if [ "$n" = 1 ]; then
    osascript -e 'tell application id "com.arkad.regista" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 80); do pgrep -x Regista >/dev/null || break; sleep 0.25; done
    if pgrep -x Regista >/dev/null; then
      echo "Regista did not quit (a dialog may be open): close it and run again" >&2; exit 1
    fi
  fi
  open -n "$app" --args "$@"
  sleep 1
  wait_socket
}

if [ -n "$LANG_ARG" ]; then
  # --lang quits and reopens the app on the default socket: with a private socket it would act on someone else's app.
  if [ -n "${REGISTA_ENGINE_SOCKET:-}" ] && [ "$REGISTA_ENGINE_SOCKET" != "$HOME/Library/Application Support/Regista/engine.sock" ]; then
    echo "--lang works only on the app of the default socket; with REGISTA_ENGINE_SOCKET set, launch your own copy with -AppleLanguages instead" >&2
    exit 1
  fi
  # Never throw away the user's work: a relaunch would close an unsaved project (any tab).
  if [ -S "$SOCK" ] && { socket_call project.list | grep -Eq '"dirty": ?true' || socket_call project.state | grep -Eq '"dirty": ?true'; }; then
    echo "an open project has unsaved changes: save it (⌘S) before --lang relaunches the app" >&2; exit 1
  fi
  relaunch -AppleLanguages "($LANG_ARG)"
  trap 'relaunch' EXIT
fi
if [ -n "$PRIVATE_LANG" ]; then
  [ -z "$LANG_ARG" ] || { echo "--lang and --private-lang exclude each other" >&2; exit 1; }
  SRC_APP="${REGISTA_PRIVATE_APP:-build/Regista.app}"
  [ -x "$SRC_APP/Contents/MacOS/Regista" ] || { echo "no app at $SRC_APP: run scripts/build-app.sh --no-open first" >&2; exit 1; }
  PRIV="$(mktemp -d -t regista-private)"
  PRIV_ID="com.arkad.regista.render"
  cp -R "$SRC_APP" "$PRIV/Regista.app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $PRIV_ID" "$PRIV/Regista.app/Contents/Info.plist"
  codesign --force --deep --sign - "$PRIV/Regista.app" >/dev/null 2>&1
  SOCK="$PRIV/engine.sock"
  REGISTA_ENGINE_SOCKET="$SOCK" "$PRIV/Regista.app/Contents/MacOS/Regista" -AppleLanguages "($PRIVATE_LANG)" >"$PRIV/app.log" 2>&1 &
  PRIV_PID=$!
  stop_private() {   # stops the copy this script started (that pid, and only if it still is that copy), then cleans up
    if ps -p "$PRIV_PID" -o command= 2>/dev/null | grep -qF "$PRIV/Regista.app"; then
      kill "$PRIV_PID" 2>/dev/null || true
      for _ in $(seq 1 40); do ps -p "$PRIV_PID" >/dev/null 2>&1 || break; sleep 0.25; done
    fi
    defaults delete "$PRIV_ID" >/dev/null 2>&1 || true
    rm -rf "$PRIV"
  }
  trap stop_private EXIT
  wait_socket
fi
[ -S "$SOCK" ] || { echo "Regista is not running (no socket at $SOCK): open the app first" >&2; exit 1; }

if [ "$REAL" = 1 ]; then
  reply="$(socket_call ui.screenshot "{\"real\": true, \"path\": \"$OUT/real-window.png\"}")"
  python3 -I -c '
import json, sys
r = json.loads(sys.argv[1])
if not r.get("ok"): sys.exit("ui.screenshot real: " + str(r.get("error")))
res = r["result"]
print(res["path"], "%dx%d px" % (res["width"], res["height"]))
print(json.dumps(res["shown"], indent=1))' "$reply"
  exit
fi

# The inspector renders use a synthetic project made here by the headless engine (never the owner's projects).
DEMO="" SCREEN_DEMO=""
if printf '%s\n' "${LIST[@]}" | grep -q '^inspector-screen'; then
  # A synthetic screen + camera session (recording.synthesize, a synthetic talking head as the camera), one project per
  # face layout, saved in a temporary folder.
  SCREEN_DEMO="$(mktemp -d -t regista-screen)"
  swift build --product regista-engine >/dev/null
  ENGINE="$(swift build --show-bin-path)/regista-engine"
  layout_steps() {   # layout_steps <layout> <width> <height> [extra steps json]
    printf '%s' ",{\"command\": \"project.new\", \"params\": {\"name\": \"schermo-$1\", \"directory\": \"$SCREEN_DEMO\", \"width\": $2, \"height\": $3}},
 {\"command\": \"recording.import\", \"params\": {\"path\": \"$SCREEN_DEMO/session\", \"layout\": \"$1\"}}${4:-},
 {\"command\": \"project.save\"}"
  }
  cat > "$SCREEN_DEMO/demo.json" <<JSON
{"name": "inspector-screen-demo", "steps": [
 {"command": "project.new", "params": {"name": "camera-take"}},
 {"command": "media.synthesize", "params": {"path": "$SCREEN_DEMO/talking-head.mov", "duration": 9}},
 {"command": "recording.synthesize", "params": {"directory": "$SCREEN_DEMO/session", "camera": "$SCREEN_DEMO/talking-head.mov",
  "sources": ["screen", "camera"], "duration": 8, "cursor": false}}
 $(layout_steps bubble 1920 1080 ',{"command": "layout.apply", "params": {"preset": "bubble", "background": "dusk", "padding": 0.07}},
  {"command": "cursor.style", "params": {"scale": 2}}, {"command": "keys.overlay", "params": {"allKeys": true}},
  {"command": "edit.autoZoom", "params": {"zoom": 1.8}}, {"command": "clip.set", "params": {"trackId": "t1", "pictureFadeIn": 0.5}}')
 $(layout_steps split 1920 1080 ',{"command": "layout.apply", "params": {"preset": "split", "side": "left"}}')
 $(layout_steps stack 1080 1920)
 $(layout_steps face 1920 1080)
 $(layout_steps cutout 1920 1080)
 $(layout_steps screen 1920 1080 ',{"command": "layout.apply", "params": {"preset": "screen", "background": "sand"}}')
]}
JSON
  "$ENGINE" run "$SCREEN_DEMO/demo.json" --work "$SCREEN_DEMO" >/dev/null || { echo "could not build the screen inspector demo projects" >&2; exit 1; }
fi
if printf '%s\n' "${LIST[@]}" | grep -q '^inspector-'; then
  DEMO_DIR="$(mktemp -d -t regista-inspector)"
  swift build --product regista-engine >/dev/null
  ENGINE="$(swift build --show-bin-path)/regista-engine"
  ffmpeg -v error -f lavfi -i "sine=frequency=220:duration=8" -ar 48000 -y "$DEMO_DIR/tone.wav"
  cat > "$DEMO_DIR/demo.json" <<JSON
{"name": "inspector-demo", "steps": [
 {"command": "project.new", "params": {"name": "ispettore-demo", "directory": "$DEMO_DIR"}},
 {"command": "media.synthesize", "params": {"path": "$DEMO_DIR/talking-head.mov", "duration": 8}, "capture": {"cam": "result.asset.id"}},
 {"command": "track.add", "params": {"kind": "video"}, "capture": {"v1": "result.track.id"}},
 {"command": "timeline.place", "params": {"assetId": "\${cam}", "trackId": "\${v1}", "sourceOut": 4}, "capture": {"c1": "result.clip.id"}},
 {"command": "timeline.place", "params": {"assetId": "\${cam}", "trackId": "\${v1}", "sourceIn": 4, "sourceOut": 8}},
 {"command": "media.import", "params": {"path": "$DEMO_DIR/tone.wav"}, "capture": {"tone": "result.asset.id"}},
 {"command": "track.add", "params": {"kind": "audio"}, "capture": {"a1": "result.track.id"}},
 {"command": "timeline.place", "params": {"assetId": "\${tone}", "trackId": "\${a1}", "sourceOut": 4, "linkTo": "\${c1}"}, "capture": {"s1": "result.clip.id"}},
 {"command": "clip.set", "params": {"clipId": "\${s1}", "gain": -3, "fadeIn": 0.2, "fadeOut": 0.4}},
 {"command": "clip.set", "params": {"clipId": "\${c1}", "brightness": 0.03, "contrast": 1.06, "saturation": 1.1, "scale": 1.08}},
 {"command": "look.apply", "params": {"look": "film", "amount": 0.6, "clipId": "\${c1}"}},
 {"command": "effect.add", "params": {"clipId": "\${c1}", "kind": "vignette", "amount": 0.5}},
 {"command": "track.add", "params": {"kind": "overlay"}, "capture": {"v2": "result.track.id"}},
 {"command": "overlay.add", "params": {"path": "$PWD/Tests/Fixtures/overlay-card.png", "start": 1, "duration": 5, "fit": "contain", "trackId": "\${v2}"}},
 {"command": "title.add", "params": {"text": "Il sito sicuro non esiste", "start": 4, "duration": 3}},
 {"command": "project.save"}
]}
JSON
  "$ENGINE" run "$DEMO_DIR/demo.json" --work "$DEMO_DIR" >/dev/null || { echo "could not build the inspector demo project" >&2; exit 1; }
  for d in "$DEMO_DIR"/*.regista; do DEMO="$d"; done
fi

# The Audio renders use two synthetic projects made here (never the owner's projects): a talking head with a voice in two
# pieces and one sound effect, and the same with music laid by audio.addMusic (ducked under the voice).
AUDIO_DEMO=""
if printf '%s\n' "${LIST[@]}" | grep -q '^audio-'; then
  AUDIO_DEMO="$(mktemp -d -t regista-audio)"
  swift build --product regista-engine >/dev/null
  ENGINE="$(swift build --show-bin-path)/regista-engine"
  ffmpeg -v error -f lavfi -i "sine=frequency=220:duration=8" -af "volume='0.5+0.5*sin(2*PI*4*t)':eval=frame" -ar 48000 -y "$AUDIO_DEMO/voice.wav"
  ffmpeg -v error -f lavfi -i "sine=frequency=262:duration=12" -f lavfi -i "sine=frequency=330:duration=12" -filter_complex amix=inputs=2 \
    -ar 48000 -y "$AUDIO_DEMO/music-bed.wav"
  WHOOSH="$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1]))["sounds"]; print(sorted(k for k in d if d[k]["group"]=="whoosh")[0])' Resources/SFX/manifest.json)"
  audio_steps() {   # audio_steps <name> [extra steps json]
    printf '%s' "{\"command\": \"project.new\", \"params\": {\"name\": \"$1\", \"directory\": \"$AUDIO_DEMO\"}},
 {\"command\": \"media.synthesize\", \"params\": {\"path\": \"$AUDIO_DEMO/$1.mov\", \"duration\": 8}, \"capture\": {\"cam\": \"result.asset.id\"}},
 {\"command\": \"track.add\", \"params\": {\"kind\": \"video\"}, \"capture\": {\"v1\": \"result.track.id\"}},
 {\"command\": \"timeline.place\", \"params\": {\"assetId\": \"\${cam}\", \"trackId\": \"\${v1}\"}},
 {\"command\": \"media.import\", \"params\": {\"path\": \"$AUDIO_DEMO/voice.wav\"}, \"capture\": {\"voice\": \"result.asset.id\"}},
 {\"command\": \"track.add\", \"params\": {\"kind\": \"audio\"}, \"capture\": {\"a1\": \"result.track.id\"}},
 {\"command\": \"timeline.place\", \"params\": {\"assetId\": \"\${voice}\", \"trackId\": \"\${a1}\", \"start\": 0, \"sourceOut\": 3.5}},
 {\"command\": \"timeline.place\", \"params\": {\"assetId\": \"\${voice}\", \"trackId\": \"\${a1}\", \"start\": 5, \"sourceIn\": 5, \"sourceOut\": 8}},
 {\"command\": \"sfx.add\", \"params\": {\"name\": \"$WHOOSH\", \"at\": 4.2}}${2:-},
 {\"command\": \"project.save\"}"
  }
  cat > "$AUDIO_DEMO/demo.json" <<JSON
{"name": "audio-demo", "steps": [
 $(audio_steps voce),
 $(audio_steps musica ',{"command": "audio.addMusic", "params": {"path": "'"$AUDIO_DEMO"'/music-bed.wav"}}')
]}
JSON
  "$ENGINE" run "$AUDIO_DEMO/demo.json" --work "$AUDIO_DEMO" >/dev/null || { echo "could not build the audio demo projects" >&2; exit 1; }
fi

python3 -I - "$SOCK" "$OUT" "$W" "$H" "$DEMO" "$SCREEN_DEMO" "$AUDIO_DEMO" "${LIST[@]}" <<'PY'
import json, socket, sys
sock, out, w, h, demo, screen_demo, audio_demo, names = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8:]
s = socket.socket(socket.AF_UNIX)
s.connect(sock)
f = s.makefile('rwb')
failed = 0
for name in names:
    path = f'{out}/{name}.png'
    params = {'workspace': name, 'size': [w, h], 'path': path}
    if name == 'edit-tabs':
        params.update(workspace='edit-pro', tabs=3)
    elif name == 'record-displays':
        params.update(workspace='record', record={'preset': 'screen-only', 'displays': 4, 'permissions': 'granted'})
    elif name.startswith('record-open-'):
        params.update(workspace='record', record={'preset': 'screen-face', 'open': name[len('record-open-'):], 'permissions': 'granted'})
    elif name.startswith('record-'):
        params.update(workspace='record', record={'preset': name[len('record-'):]})
    elif name.startswith('voice-setup-'):
        params.update(workspace='voice-setup', voice={'state': name[len('voice-setup-'):]})
        del params['size']   # the sheet's own size
    elif name == 'settings-voice':
        params.update(voice={'state': 'ready'})
        del params['size']
    elif name == 'settings' or name.startswith('settings-'):
        del params['size']   # the Settings window's own size
    elif name.startswith('inspector-screen'):
        layout = name[len('inspector-screen-'):] if name.startswith('inspector-screen-') else 'bubble'
        select = 'first-video' if layout == 'clip' else 'none'
        layout = 'bubble' if layout == 'clip' else layout
        params.update(workspace='edit-pro', size=[w, max(h, 2200)],
                      inspector={'select': select, 'project': f'{screen_demo}/schermo-{layout}.regista'})
    elif name.startswith('inspector-'):
        select = {'video': 'first-video', 'audio': 'first-audio', 'overlay': 'first-overlay'}.get(name[10:], name[10:])
        params.update(workspace='edit-pro', inspector={'select': select, 'project': demo})
    elif name.startswith('texts-'):
        params.update(workspace='texts', texts={'state': name[len('texts-'):]})
    elif name in ('jobs', 'jobs-closed'):
        params.update(workspace='edit-pro', jobs={'open': name == 'jobs'})
    elif name.startswith('voice-'):
        params.update(workspace='voice', voice={'state': name[len('voice-'):]})
    elif name.startswith('audio-'):
        state = name[len('audio-'):]
        music = state in ('music', 'loud')
        project = f'{audio_demo}/{"musica" if music else "voce"}.regista'
        audio = {'tab': 'sfx' if state == 'sfx' else 'mix',
                 'loudness': {'empty': [-15.3, -2.4], 'music': [-14.8, -1.9], 'sfx': [-15.3, -2.4], 'loud': [-11.2, -0.3]}[state]}
        if state == 'music':
            audio['check'] = {'pass': True, 'underDB': 19.4, 'minUnder': 15}
        if state == 'sfx':
            audio.update(group='whoosh', playing='whoosh_fast/heavy')
        params.update(workspace='audio', audio=audio, inspector={'select': 'first-music' if music else 'none', 'project': project})
    req = {'op': 'execute', 'command': 'ui.screenshot', 'params': params}
    f.write((json.dumps(req) + '\n').encode()); f.flush()
    reply = json.loads(f.readline())
    if reply.get('ok'):
        shown = (reply.get('result') or {}).get('shown', {})
        rec, insp = shown.get('record'), shown.get('inspector')
        print(path + (f"  preset={rec.get('preset')} canRecord={rec.get('canRecord')}" if rec else '')
              + (f"  kind={insp.get('kind')} sections={','.join(insp.get('sections', []))}" if insp else ''))
    else:
        failed += 1
        print(f'{name}: {reply.get("error")}', file=sys.stderr)
sys.exit(1 if failed else 0)
PY
