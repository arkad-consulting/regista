#!/bin/bash
# Refuses voice data in the repository (issue #41): recordings, LoRAs and profiles belong to one person and live in
# ~/Library/Application Support/Regista/profiles, never in git or the hand-off package (which is `git archive` of
# tracked files). Used by .githooks/pre-commit (staged files) and scripts/package.sh (HEAD).
#   scripts/check-voice-data.sh [--staged]
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${1:-}" = "--staged" ]; then files="$(git diff --cached --name-only --diff-filter=AM)"; else files="$(git ls-files)"; fi
bad="$(printf '%s\n' "$files" | grep -Ei '^profiles/|\.safetensors$|lora_weights|lora_config\.json$|(^|/)voice-clone/|(^|/)engines/voxcpm/.*\.(wav|m4a|mp3|flac)$|engines\.json$' || true)"
if [ -n "$bad" ]; then
  echo "voice data must not be in the repository (it belongs to a person's profile, #41):" >&2
  printf '  %s\n' $bad >&2
  exit 1
fi
