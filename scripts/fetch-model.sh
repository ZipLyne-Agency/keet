#!/bin/bash
# Downloads the exact Core ML models Keet uses into FluidAudio's model cache, pinned to
# one Hugging Face revision each and checked against SHA-256.
#
# Keet can also download them itself (the speech model on first launch, the Dictionary's
# model when you add your first word). This script exists because it's resumable and
# parallel: on slow or throttled connections big files arrive in eight ranges, each
# resuming where it stopped.
#
#   scripts/fetch-model.sh                 # the speech model
#   scripts/fetch-model.sh --dictionary    # plus the Dictionary's word-spotting model
set -euo pipefail

MODELS="$HOME/Library/Application Support/FluidAudio/Models"
PARTS="${KEET_FETCH_PARTS:-8}"

# Speech: Parakeet Unified 0.6B (English), offline int8 encoder.
SPEECH_REPO="FluidInference/parakeet-unified-en-0.6b-coreml"
SPEECH_REVISION="d32e972dd4315f1dc3f6be28fb2aab0ab3e80358"
SPEECH_DEST="${KEET_MODEL_DIR:-$MODELS/parakeet-unified-en-0.6b}"
# sha256  size  path
SPEECH_FILES=(
  "e1a7bff4f5df133c0f4ad47b8e43c96f6bf1865d99126a4c4725ef51d0108bec 15088 vocab.json"
  "2b26a96b76fe1f7a04d3e867f50c75d6ce5dd1650d0dbcd4c35b591b22305f0e 1046 metadata.json"
  "6cbe6c76445410c5c6debf3d44c8c3b75e9966bf09bba5cd138c2378c62120f6 1355 config.json"
  "ce99c4488840fc463d59f8d4d6d2a9e8ceae8138ead51e3c265dde4d2ba4a0e9 560 parakeet_unified_decoder.mlmodelc/coremldata.bin"
  "6e60965b89c93943aa2be2d991c2461108145851fde05e1d048223a32d4cb20d 13102 parakeet_unified_decoder.mlmodelc/model.mil"
  "9ae70f6559989f88b856b326e59315798f9f0d08207a19fcc2dd3287a30088a5 243 parakeet_unified_decoder.mlmodelc/analytics/coremldata.bin"
  "96f990461a5986d5e7309ad1a0f36084fbf0f4b28aec35948f8b8d0dcbf8599e 14429952 parakeet_unified_decoder.mlmodelc/weights/weight.bin"
  "68a081570a48b52ec9379e153bd56748a5408a50be16767601563f231eaeff03 556 parakeet_unified_joint_decision_single_step.mlmodelc/coremldata.bin"
  "03c21096090bcd0b71c896c5ae0eb815db31a91c6676f572a7868eee4299abe3 9611 parakeet_unified_joint_decision_single_step.mlmodelc/model.mil"
  "163877ad14af97ec4107cd854fd1c6d336ee5d40ad25a657cc764fb763f452f5 243 parakeet_unified_joint_decision_single_step.mlmodelc/analytics/coremldata.bin"
  "06831afa6d1beb0c0b10350ebf7886bc37638e951d14e738d7e06fbd2a05012f 3446978 parakeet_unified_joint_decision_single_step.mlmodelc/weights/weight.bin"
  "54f533d30343d5e62b324a0691e4c262a6768b07b6e88e7aa14c617a2baba8a3 492 parakeet_unified_encoder_int8.mlmodelc/coremldata.bin"
  "c1c5d71c6cbf4d35bba08458746bde3640da7b1b444e1229a269393a58222c10 1110902 parakeet_unified_encoder_int8.mlmodelc/model.mil"
  "57e116a9d5765e39c0cdf754137ab744ddae34d9c6d68a5fdcad6600ae3a7b6b 243 parakeet_unified_encoder_int8.mlmodelc/analytics/coremldata.bin"
  "f984b81590a4deae041ae20fbab8981c2d2a5b528b2ac81fae81c432633535c6 595051904 parakeet_unified_encoder_int8.mlmodelc/weights/weight.bin"
)

# Dictionary: Parakeet CTC 110M, which spots your custom words in the audio.
CTC_REPO="FluidInference/parakeet-ctc-110m-coreml"
CTC_REVISION="accdafd8cf8a2ff1cabe3c11e54416b405d409aa"
CTC_DEST="${KEET_CTC_DIR:-$MODELS/parakeet-ctc-110m-coreml}"
CTC_FILES=(
  "319d386eead79aadc80df9c3ecc8340d1a727efb7c02a8847eb940380dd61e1f 16086 vocab.json"
  "9f7c517c0bf644b1b690ab037bab4d4c53aecd38e047e7154d011013ab9160db 360106 tokenizer.json"
  "7a29ed0fec88768d8666d65be8dc00ae41a60c4b7758c4df99a912108e62a23a 632 tokenizer_config.json"
  "af8c98917af6cb493513e5f1f8a35efdc28fa82cac15b2bb5f065d64f8bc904d 279 special_tokens_map.json"
  "1fd77c83ea89285c242608d95a7992f146867481adc3938be730a064f3a63305 121 config.json"
  "3a32ec67c76aa0aa2faef518413c311493e89aeb7fa11289fa4b8653ab8a160c 330 MelSpectrogram.mlmodelc/coremldata.bin"
  "0a7cb5693b39667295218bac5c7c09053f6bcd4b32699a83d06ac35d14ac6b79 12584 MelSpectrogram.mlmodelc/model.mil"
  "5e11d21a65c02bcfc37db43e941978e5d60d59e0efeadfda08e41f33b4f835d3 1962 MelSpectrogram.mlmodelc/metadata.json"
  "22f2a8cba1de25c984050566b534a1d8caf22a82f9fe6c1c6f3149a0dd7e8ae3 243 MelSpectrogram.mlmodelc/analytics/coremldata.bin"
  "0a89c055bfde9022029d3cc59a23e949385e063974460d8eaec3a7614c3eaaa8 567712 MelSpectrogram.mlmodelc/weights/weight.bin"
  "a88b002b58193b4c31211754cdfdf220a85f9651dc61caf336ab84400cbc191a 505 AudioEncoder.mlmodelc/coremldata.bin"
  "2f84ef93a69115e55f3b5d8ce695b3c937de1833d4d229620634fae967cd587e 1060924 AudioEncoder.mlmodelc/model.mil"
  "4f288bfe5cbe867ef1e592cdae33578b2fe59ada69182fc12209879558f985c2 3456 AudioEncoder.mlmodelc/metadata.json"
  "8906c823e9bb3bf6b16d9f0308f98cd70573526333ad85dd767dc3f9ae6b25fa 243 AudioEncoder.mlmodelc/analytics/coremldata.bin"
  "af0734b4a5d7465ad9e8bb170f0c53c5e6b91ebb75a9bdf88d3f59ae4ad6aebd 100778304 AudioEncoder.mlmodelc/weights/weight.bin"
)

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

is_good() { # file size sha
  [[ -f "$1" ]] && [[ "$(stat -f %z "$1")" == "$2" ]] && [[ "$(sha_of "$1")" == "$3" ]]
}

# Hugging Face redirects large files to a signed CDN URL that expires, so every
# attempt resolves a fresh one.
cdn_url() {
  curl -sSI "$BASE/$1" | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r'
}

# Fetches bytes start..end into part, resuming from the part's current size. curl's
# own --retry restarts a range from the top, which would duplicate bytes here.
fetch_range() { # path part start end
  local path="$1" part="$2" start="$3" end="$4" have url
  while :; do
    have=0; [[ -f "$part" ]] && have=$(stat -f %z "$part")
    (( start + have > end )) && return 0
    url="$(cdn_url "$path")"
    curl -sSf --connect-timeout 20 --speed-limit 1024 --speed-time 30 \
      -r "$(( start + have ))-$end" "${url:-$BASE/$path}" >> "$part" || sleep 2
  done
}

fetch_small() { # path
  mkdir -p "$(dirname "$DEST/$1")"
  curl -sSfL --retry 5 --connect-timeout 20 -o "$DEST/$1.partial" "$BASE/$1"
  mv "$DEST/$1.partial" "$DEST/$1"
}

fetch_big() { # path size
  local path="$1" size="$2" out="$DEST/$1"
  local parts="$out.parts"
  mkdir -p "$parts"
  local chunk=$(( (size + PARTS - 1) / PARTS )) pids=()
  for ((i = 0; i < PARTS; i++)); do
    local start=$(( i * chunk )) end=$(( (i + 1) * chunk - 1 ))
    (( end >= size )) && end=$(( size - 1 ))
    (( start > end )) && continue
    fetch_range "$path" "$parts/part.$(printf %03d $i)" "$start" "$end" &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
  cat "$parts"/part.* > "$out.partial"
  mv "$out.partial" "$out"
  find "$parts" -mindepth 1 -maxdepth 1 -name 'part.*' -delete
  rmdir "$parts"
}

fetch_set() { # repo revision dest entries...
  local repo="$1" revision="$2"
  DEST="$3"
  BASE="https://huggingface.co/$repo/resolve/$revision"
  shift 3
  mkdir -p "$DEST"
  for entry in "$@"; do
    read -r sha size path <<< "$entry"
    if is_good "$DEST/$path" "$size" "$sha"; then
      echo "ok (cached) $path"
      continue
    fi
    if (( size > 50000000 )); then
      echo "downloading $path ($(( size / 1000000 )) MB, $PARTS parallel ranges)"
      fetch_big "$path" "$size"
    else
      fetch_small "$path"
    fi
    if ! is_good "$DEST/$path" "$size" "$sha"; then
      echo "checksum mismatch: $path" >&2
      rm -f "${DEST:?}/$path"
      exit 1
    fi
    echo "ok $path"
  done
  echo "ready: $DEST"
}

fetch_set "$SPEECH_REPO" "$SPEECH_REVISION" "$SPEECH_DEST" "${SPEECH_FILES[@]}"
if [[ "${1:-}" == "--dictionary" ]]; then
  fetch_set "$CTC_REPO" "$CTC_REVISION" "$CTC_DEST" "${CTC_FILES[@]}"
fi
