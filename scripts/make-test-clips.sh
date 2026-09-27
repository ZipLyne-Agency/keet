#!/bin/bash
# Generates the spoken test clips used by `keet-bench lastword` and `keet-bench tail`:
# twelve sentences in ten built-in macOS voices, 16 kHz mono, each with a .txt of
# what was said.
#   scripts/make-test-clips.sh ~/keet-clips
set -euo pipefail
OUT="${1:?usage: make-test-clips.sh <output directory>}"
mkdir -p "$OUT"

VOICES=("Samantha" "Daniel" "Karen" "Moira" "Reed (English (US))" "Flo (English (US))"
        "Rishi" "Tessa" "Eddy (English (US))" "Shelley (English (UK))")
SENTENCES=(
  "Can you send me the latest numbers before the meeting this afternoon"
  "I think we should ship the fix today and test it tomorrow"
  "Let's move the standup to ten thirty and skip the retro"
  "Please remind me to call the accountant about the invoice"
  "The deploy failed because the database migration timed out"
  "Add a note that the client wants the blue version instead of the green one"
  "Honestly the new design looks great but the spacing feels off"
  "We need to rotate the keys and update the webhook secret"
  "Book a table for four people at seven"
  "Thanks so much for the quick turnaround on this"
  "Make sure the tests pass before you merge it"
  "Grab the milk"
)

for i in "${!SENTENCES[@]}"; do
  voice="${VOICES[$((i % ${#VOICES[@]}))]}"
  name="$(printf %02d "$i")"
  say -v "$voice" -o "$OUT/$name.wav" --data-format=LEF32@16000 "${SENTENCES[$i]}"
  echo "${SENTENCES[$i]}" > "$OUT/$name.txt"
done
echo "wrote ${#SENTENCES[@]} clips to $OUT"
