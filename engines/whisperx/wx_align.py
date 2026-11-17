#!/usr/bin/env python3
"""WhisperX on a raw take: faster-whisper large-v3-turbo (CPU int8, converted from openai/whisper-large-v3-turbo)
+ pyannote VAD (bundled with whisperx) + wav2vec2 forced alignment -> word timings.
usage: python -I wx_align.py <audio16k.wav> <out.json> [--lang it] [--align-model NAME] [--align-device cpu|mps]
       [--chunk 8] [--compute int8] [--threads 12]
       [--transcript prev.json]  # re-align an existing transcript (whisperx JSON with asr_segments/segments), skip ASR
Numbers are spelled out in the take's language (Italian, French) before alignment (the aligner has no digits).
Aligners = the WhisperX defaults, pinned in scripts/engines.lock and installed by scripts/install.sh, never downloaded
here: torchaudio WAV2VEC2_ASR_BASE_960H for "en" and, on request only (CC BY-NC 4.0), VOXPOPULI_ASR_BASE_10K_IT / _FR for
"it" / "fr" (models/torchaudio); jonatasgrosman/wav2vec2-large-xlsr-53-portuguese for "pt", loaded as a local folder
(models/wav2vec2-large-xlsr-53-portuguese). A language whose aligner is missing exits 3 with the reason."""
import argparse, json, os, time, warnings

warnings.filterwarnings("ignore")
HERE = os.path.dirname(os.path.abspath(__file__))
import sys; sys.path.insert(0, HERE)  # -I drops the script dir; textnorm lives next to this file
ap = argparse.ArgumentParser()
ap.add_argument("audio"); ap.add_argument("out")
ap.add_argument("--lang", default="it")
ap.add_argument("--model", default=os.path.join(HERE, "models", "ct2-whisper-large-v3-turbo"))
ap.add_argument("--align-model", default=None)
ap.add_argument("--align-device", default="cpu")
ap.add_argument("--transcript", default=None)
ap.add_argument("--compute", default="int8", help="ctranslate2 compute type on CPU: int8 | float32")
ap.add_argument("--threads", type=int, default=12)
ap.add_argument("--chunk", type=int, default=8, help="max VAD chunk seconds (30 = whisperx default; long chunks make Whisper drop repeated takes)")
a = ap.parse_args()

# The pinned aligner of each language: (file that must exist, model_name for whisperx.load_align_model).
MODELS = os.path.join(HERE, "models")
ALIGNERS = {
    "en": (os.path.join(MODELS, "torchaudio", "wav2vec2_fairseq_base_ls960_asr_ls960.pth"), None),
    "it": (os.path.join(MODELS, "torchaudio", "wav2vec2_voxpopuli_base_10k_asr_it.pt"), None),
    "fr": (os.path.join(MODELS, "torchaudio", "wav2vec2_voxpopuli_base_10k_asr_fr.pt"), None),
    "pt": (os.path.join(MODELS, "wav2vec2-large-xlsr-53-portuguese", "pytorch_model.bin"),
           os.path.join(MODELS, "wav2vec2-large-xlsr-53-portuguese")),
}
if a.align_model is None:
    if a.lang not in ALIGNERS:
        print(f"no pinned aligner for language {a.lang!r} (pinned: {', '.join(sorted(ALIGNERS))})", file=sys.stderr); sys.exit(3)
    need, local = ALIGNERS[a.lang]
    if not os.path.isfile(need):
        print(f"the {a.lang} aligner is not installed ({need}): scripts/install.sh --only aligner-{a.lang}", file=sys.stderr); sys.exit(3)
    a.align_model = local   # None = the torchaudio default, found in models/torchaudio without a download
os.environ["HF_HUB_OFFLINE"] = "1"   # nothing from the Hub at run time: every model is a local, pinned file

import torch, whisperx  # noqa: E402  (heavy imports after argparse so --help is instant)

audio = whisperx.load_audio(a.audio)
t = {}
if a.transcript:
    tj = json.load(open(a.transcript))
    segs = tj.get("asr_segments") or tj["segments"]
    t["transcribe_s"] = 0.0
else:
    t0 = time.time()
    model = whisperx.load_model(a.model, "cpu", compute_type=a.compute, language=a.lang, vad_method="pyannote", threads=a.threads,
                                asr_options={"beam_size": 5, "condition_on_previous_text": False})
    t["load_asr_s"] = round(time.time() - t0, 2); t0 = time.time()
    # print_progress: WhisperX's own "Progress: N%..." after each batch it transcribed (Regista's job reads it).
    res = model.transcribe(audio, batch_size=8, language=a.lang, chunk_size=a.chunk, print_progress=True)
    segs = res["segments"]
    t["transcribe_s"] = round(time.time() - t0, 2)
    del model
from textnorm import numbers_to_words  # noqa: E402
asr_segments = [{"start": s["start"], "end": s["end"], "text": s["text"]} for s in segs]
segs = [{**s, "text": numbers_to_words(s["text"], a.lang)} for s in asr_segments]  # aligner vocab has no digits
t0 = time.time()
am, meta = whisperx.load_align_model(a.lang, a.align_device, model_name=a.align_model,
                                     model_dir=os.path.join(HERE, "models", "torchaudio"))
t["load_align_s"] = round(time.time() - t0, 2); t0 = time.time()
al = whisperx.align(segs, am, meta, audio, a.align_device, return_char_alignments=False)
t["align_s"] = round(time.time() - t0, 2)
words = [{"w": w["word"], "s": w.get("start"), "e": w.get("end"), "p": w.get("score")}
         for s in al["segments"] for w in s.get("words", [])]
json.dump({"audio": os.path.abspath(a.audio), "align_model": a.align_model or "default:" + a.lang,
           "align_device": a.align_device, "timing": t, "duration": len(audio) / 16000,
           "asr_segments": asr_segments,
           "segments": [{"start": s.get("start"), "end": s.get("end"), "text": s["text"]} for s in al["segments"]],
           "words": words}, open(a.out, "w"), ensure_ascii=False, indent=1)
print(json.dumps(t), f"{len(words)} words, {sum(w['s'] is None for w in words)} unaligned")
