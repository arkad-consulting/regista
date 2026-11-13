"""Render text in a cloned voice with VoxCPM2 (PyTorch, MPS) for Regista.

uv run --frozen --project <this folder> python -I vox_say.py '<request JSON>'

Request (built by VoxCPMProvider in Sources/RegistaCore/Generation/Voice.swift):
  {"model": "<VoxCPM2 weights folder>", "lora": "<LoRA step folder>" | null,
   "ref": {"wav": "<reference clip>", "text": "<its exact transcript>"},
   "items": [{"text": "<text for the model>", "seed": 0, "out": "<output .wav>"}]}

The text arrives ready for the model: the pronunciation lexicon and the tone tag are applied by Regista. One model
load for all items; every WAV is mono at the model rate (48 kHz) and loudness-matched to the reference clip. The last
stdout line is the result: {"files", "seconds", "texts", "model", "sample_rate", "wall_seconds"}.
"""

import json
import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
from voxcpm import VoxCPM
from voxcpm.model.voxcpm import LoRAConfig


def rms(audio: np.ndarray) -> float:
    return float(np.sqrt(np.mean(np.square(audio, dtype=np.float64))))


def main() -> None:
    start = time.monotonic()
    req = json.loads(sys.argv[1])
    lora = req.get("lora")
    lora_config = None
    if lora:
        lora_config = LoRAConfig(**json.loads((Path(lora) / "lora_config.json").read_text())["lora_config"])
    # The denoiser is never loaded (it downloads its own model and the references are clean recordings).
    model = VoxCPM.from_pretrained(req["model"], load_denoiser=False, optimize=False, local_files_only=True,
                                   lora_config=lora_config, lora_weights_path=lora)
    sr = model.tts_model.sample_rate
    ref = req["ref"]
    ref_audio, _ = sf.read(ref["wav"])
    ref_rms = rms(ref_audio if ref_audio.ndim == 1 else ref_audio.mean(axis=1))
    # Ultimate cloning: the reference clip as prompt (with its transcript) and as timbre reference.
    prompt = dict(prompt_wav_path=ref["wav"], prompt_text=ref["text"], reference_wav_path=ref["wav"])

    files, seconds, texts = [], [], []
    for item in req["items"]:
        torch.manual_seed(int(item.get("seed", 0)))
        wav = np.asarray(model.generate(text=item["text"], **prompt), dtype=np.float64)
        level = rms(wav)
        if level > 0:
            wav = wav * ref_rms / level
        peak = float(np.max(np.abs(wav))) if wav.size else 0.0
        if peak > 0.98:  # never clip after the gain
            wav = wav * 0.98 / peak
        out = str(Path(item["out"]).resolve())
        sf.write(out, wav.astype(np.float32), sr)
        files.append(out)
        seconds.append(round(len(wav) / sr, 3))
        texts.append(item["text"])
        print(f"{Path(out).name}: {seconds[-1]} s", file=sys.stderr)

    print(json.dumps({"files": files, "seconds": seconds, "texts": texts, "model": "voxcpm2", "sample_rate": sr,
                      "wall_seconds": round(time.monotonic() - start, 1)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
