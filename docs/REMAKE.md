# Rebuilding Keet from scratch

This is everything needed to rebuild Keet and understand why it works the way it does:
the hardware and tools, the exact model files, how one dictation flows through the code,
and each design decision with the measurement behind it.

## What Keet does

Five behaviors define it. Everything else serves these.

1. **Hold a key to talk.** Left Option by default. Holding it alone starts recording.
   Option with another key, a click, or another modifier in the first 0.6 seconds is
   left alone as a normal shortcut. After that it's a dictation, and nothing but letting
   go (or Escape) ends it.
2. **Show that it's listening.** A pill at the bottom of the screen you're typing on,
   with a live waveform and the words as you say them.
3. **Put the text where the cursor is.** If nothing can take text, show it on a card with
   a Copy button instead of losing it.
4. **Never drop the last word.** Letting go of the key a moment before the last word ends
   must not cut it off.
5. **Feel instant.** Capture starts within tens of milliseconds of the key press, and
   the text lands shortly after the key comes up.
6. **Never lose a long dictation.** Four minutes of talking must survive a bumped key, a
   click, or even Escape.

## What you need

| | Used to build and measure Keet | Minimum |
|---|---|---|
| Mac | MacBook Pro, M5 Max, 128 GB | Any Apple Silicon Mac (M1 or later) |
| macOS | 27.0 | 15.0 Sequoia (the deployment target) |
| Xcode | 27.0, Swift 6.4 | 26, Swift 6.2 (what CI builds with) |
| Disk | | About 615 MB for the model, plus about 1 GB for the build folder |
| Memory | Keet uses 58 MB at rest (75 MB peak, measured with `footprint`) | |
| Network | Only to download the model once | |
| Apple developer certificate | Developer ID Application | Optional; without one the app is signed ad hoc |

Intel Macs are not supported. The model runs on the Neural Engine, and nothing here has
been tested on Intel.

## The model, exactly

### Where it comes from

Keet runs **Parakeet Unified 0.6B (English)** from NVIDIA, converted to Core ML by
FluidInference.

| | Value |
|---|---|
| Original model | [`nvidia/parakeet-unified-en-0.6b`](https://huggingface.co/nvidia/parakeet-unified-en-0.6b), revision `fe53cd885760c96b6a5f51a0bfd362cb4584a98b`, released 2026-04-07 |
| Architecture | FastConformer encoder (24 layers) with an RNN-T decoder, 600M parameters, trained jointly for offline and streaming use |
| Training data | Mostly the English part of NVIDIA's Granary set, about 250,000 hours of US English |
| Output | English letters, spaces and apostrophes, with punctuation and capitalization built in |
| License | NVIDIA Open Model License; the model card states it is ready for commercial and non-commercial use |
| Core ML conversion | [`FluidInference/parakeet-unified-en-0.6b-coreml`](https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml), revision `d32e972dd4315f1dc3f6be28fb2aab0ab3e80358`, listed as CC-BY-4.0 |
| Runtime | [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.17.4 (Apache-2.0), `UnifiedAsrManager` |

Parakeet was chosen over Whisper because it decodes the whole clip in one pass rather
than generating text word by word, which makes it much faster and means it doesn't
invent text during silence. The unified model was chosen over Parakeet TDT v2 and v3
because it is the most accurate of the English Parakeet models. It is English only.

### The files Keet uses

The conversion repository has many variants (streaming encoders for several latency
settings, fp16 encoders, a Core ML mel front end). Keet uses the **offline int8
encoder** and nothing streaming. `scripts/fetch-model.sh` downloads exactly these, from
the pinned revision, and checks each SHA-256.

| File | Size (bytes) | SHA-256 |
|---|---:|---|
| `parakeet_unified_encoder_int8.mlmodelc/weights/weight.bin` | 595,051,904 | `f984b81590a4deae041ae20fbab8981c2d2a5b528b2ac81fae81c432633535c6` |
| `parakeet_unified_encoder_int8.mlmodelc/model.mil` | 1,110,902 | `c1c5d71c6cbf4d35bba08458746bde3640da7b1b444e1229a269393a58222c10` |
| `parakeet_unified_encoder_int8.mlmodelc/coremldata.bin` | 492 | `54f533d30343d5e62b324a0691e4c262a6768b07b6e88e7aa14c617a2baba8a3` |
| `parakeet_unified_encoder_int8.mlmodelc/analytics/coremldata.bin` | 243 | `57e116a9d5765e39c0cdf754137ab744ddae34d9c6d68a5fdcad6600ae3a7b6b` |
| `parakeet_unified_decoder.mlmodelc/weights/weight.bin` | 14,429,952 | `96f990461a5986d5e7309ad1a0f36084fbf0f4b28aec35948f8b8d0dcbf8599e` |
| `parakeet_unified_decoder.mlmodelc/model.mil` | 13,102 | `6e60965b89c93943aa2be2d991c2461108145851fde05e1d048223a32d4cb20d` |
| `parakeet_unified_decoder.mlmodelc/coremldata.bin` | 560 | `ce99c4488840fc463d59f8d4d6d2a9e8ceae8138ead51e3c265dde4d2ba4a0e9` |
| `parakeet_unified_decoder.mlmodelc/analytics/coremldata.bin` | 243 | `9ae70f6559989f88b856b326e59315798f9f0d08207a19fcc2dd3287a30088a5` |
| `parakeet_unified_joint_decision_single_step.mlmodelc/weights/weight.bin` | 3,446,978 | `06831afa6d1beb0c0b10350ebf7886bc37638e951d14e738d7e06fbd2a05012f` |
| `parakeet_unified_joint_decision_single_step.mlmodelc/model.mil` | 9,611 | `03c21096090bcd0b71c896c5ae0eb815db31a91c6676f572a7868eee4299abe3` |
| `parakeet_unified_joint_decision_single_step.mlmodelc/coremldata.bin` | 556 | `68a081570a48b52ec9379e153bd56748a5408a50be16767601563f231eaeff03` |
| `parakeet_unified_joint_decision_single_step.mlmodelc/analytics/coremldata.bin` | 243 | `163877ad14af97ec4107cd854fd1c6d336ee5d40ad25a657cc764fb763f452f5` |
| `vocab.json` | 15,088 | `e1a7bff4f5df133c0f4ad47b8e43c96f6bf1865d99126a4c4725ef51d0108bec` |
| `metadata.json` | 1,046 | `2b26a96b76fe1f7a04d3e867f50c75d6ce5dd1650d0dbcd4c35b591b22305f0e` |
| `config.json` | 1,355 | `6cbe6c76445410c5c6debf3d44c8c3b75e9966bf09bba5cd138c2378c62120f6` |

They live in `~/Library/Application Support/FluidAudio/Models/parakeet-unified-en-0.6b/`,
which is where FluidAudio looks. If they're missing, Keet has FluidAudio download them
on first launch.

### How it runs

FluidAudio computes a 128-bin log-mel spectrogram in Swift, runs the int8 encoder on the
Neural Engine (`cpuAndNeuralEngine`; int8 weights must not go to the GPU), then decodes
greedily with the RNN-T decoder and joint network on the CPU. Frames are 80 ms. The
offline encoder takes a fixed 15-second window with full attention; longer dictations are
split into 15-second windows that overlap by 2 seconds and are merged.

| Measurement | Result |
|---|---|
| Word error rate, LibriSpeech test-clean (FluidAudio's benchmark, int8, batch) | 1.68% aggregate |
| Transcribing 1 to 6 seconds of speech (M5 Max) | 32 to 66 ms |
| Transcribing 4 minutes 11 seconds of speech in one pass (700 words) | 1.35 s, 1.4% word error rate |
| First load after installing or updating Keet (Core ML compiles for the Neural Engine) | 8.2 to 8.7 s |
| Every load after that (compiled plan is cached) | 0.11 to 0.14 s |

Keet runs one dummy transcription at launch so the first real dictation doesn't pay any
one-time setup cost.

## How one dictation flows

1. **Key down.** A listen-only event tap sees Left Option go down alone and tells the
   controller. The controller starts the audio engine on its audio queue and asks the
   frontmost app to build its accessibility tree (Electron and Chrome only do so when
   asked).
2. **Capture.** An `AVAudioSinkNode` receives every hardware cycle (about 10 ms) and copies
   channel 0 into a preallocated buffer, lock-free. Measured on real USB microphones, the
   first audio arrived 23 to 36 ms after the key press on the system default input and 60
   to 69 ms on a specifically chosen one.
3. **Pill.** 160 ms after the press, if the key is still down, the pill appears. A pump
   on the audio queue reads new audio every 10 ms, measures loudness in 10 ms frames,
   and feeds the waveform. From 600 ms in, the live preview starts putting words in the
   pill.
4. **Key up.** The recorder keeps going. Every 10 ms the tail rule checks whether the
   speaker has finished (next section). Typing or clicking also ends it at once.
5. **Transcribe.** The recording is resampled to 16 kHz mono and transcribed.
6. **Deliver.** Accessibility says whether a text field has focus. If it does, the text
   is pasted with Command-V through the clipboard, and the clipboard is restored half a
   second later. If not, the Copy card appears. Either way the dictation is added to
   history.

The code for each step: `HotkeyMonitor.swift` (1), `AudioRecorder.swift` (2),
`AppController.swift` and `Overlay.swift` (3, 4), `SpeechTail.swift` (4),
`Transcriber.swift` (5), `TextInserter.swift` (6).

## The decisions that matter

### The tail: why the last word never gets cut

Dictation tools drop the last word for two reasons, and Keet handles both.

**Audio stuck in flight.** An `AVAudioEngine` input tap delivers audio in blocks of at
least 100 ms (the documented range is 100 to 400 ms). Stop the engine and whatever sits
in the half-filled block is gone, and the end of the recording is exactly where the last
word lives. Keet records through `AVAudioSinkNode` instead, which is called for every
hardware cycle.

**Letting go too early.** People release the key while still finishing a word. Keet
measured what that costs by cutting spoken test clips at different points and
transcribing them (`keet-bench lastword`):

| Where the clip was cut | Trailing silence added | Last word correct (12 clips) |
|---|---|---|
| Exactly where the last word ends | none | 12 |
| Exactly where the last word ends | 150, 300 or 500 ms | 12 |
| 40 ms before the last word ends | none | 10 |
| 40 ms before the last word ends | 300 ms | 10 |

Cutting 40 ms early turned "the spacing feels off" into "the spacing feels", which is
the failure people notice. Adding silence to the end made no difference, so Keet
doesn't pad. The fix has to be capturing until the word actually ends.

So after the key comes up, Keet keeps recording and stops at the first of these:

- 150 ms of continuous quiet has been heard (never sooner than 40 ms after release, so
  audio already in flight lands)
- 600 ms has passed since release
- you press a key or click, which means you've moved on

"Quiet" means below a speech threshold computed per dictation from 10 ms loudness frames:

- **Room noise** is the lower of two estimates: the 15th percentile of every frame so far,
  and the median of the first 80 ms after the key went down, which is nearly always
  before you start talking.
- **The threshold** is room noise plus 9 dB, pulled down toward 18 dB below the loudest
  speech so soft endings still count, but never closer than 4 dB to the room noise.

- **Speech** means two or more loud frames in a row. A lone 10 ms spike is room noise
  and doesn't restart the quiet count.

The clamp and the two-frame rule came from real microphones. An earlier version let the
threshold fall below the noise when a recording held little speech, so the room never
read as quiet and the tail ran to its cap (700 ms tails). A quiet USB microphone, with
speech peaking around −36 dB over a −54 dB room, still hit the cap on some dictations
with the threshold only 4 dB above the noise, because noise spikes kept crossing it.

`keet-bench tail` checks the rule end to end: each clip gets room noise mixed in, the
key is released 40 ms before the last word ends, the tail rule decides where capture
stops, and the result is transcribed.

| Room | Last word kept | Tail after release |
|---|---|---|
| Quiet room, noise at −60 dB | 12 of 12 | about 190 ms (40 ms of word plus 150 ms of quiet) |
| Noisy room, noise at −48 dB | 11 of 12 | about 170 ms |
| Quiet microphone: speech 20 dB lower, noise at −54 dB | 10 of 12 | 40 to 170 ms |

Every miss above is either the robotic "Samantha" clip, which the model garbles in every
test, or "milk" heard as "mill" at the lowest level. In that case the capture ran past
the end of the word; the model simply didn't hear the faint "k" through the noise.

If you had already stopped talking when you let go, the quiet is already there and
capture stops 40 ms after release.

### Long dictations

Three rules keep a long dictation from being lost:

- **Shortcut detection only at the start.** Other keys, clicks and modifiers cancel only
  in the first 0.6 seconds, when they mean you were pressing an Option shortcut. After
  that they're ignored.
- **Escape keeps real speech.** Escape within the first 2 seconds cancels quietly. After
  that, Keet still transcribes what you said, shows it on the Copy card, and saves it in
  History marked "Cancelled", without pasting it.
- **A 30-minute buffer.** Memory is used only as audio arrives, about 11 MB a minute at
  48 kHz. If a recording reaches the limit, Keet transcribes it as if you'd let go.

The offline encoder sees 15 seconds at a time, so longer recordings are split into
15-second windows overlapping by 2 seconds and merged. A 4 minute 11 second recording of
700 spoken words came back with 10 word errors (1.4%) in 1.35 s, ending on the right
words. Including the robotic "Samantha" voice pushed a 4 minute 36 second run to 16.4%,
all of it from that voice.

### Words as you speak

While the key is down, Keet re-transcribes the most recent 14 seconds of audio about
three times a second and shows the result in the pill, which grows from a waveform into
a caption. It hugs short phrases, wraps to two lines, and drops the oldest words off
the front. The text you get when you let go still comes from one full pass over the
whole recording, so the preview doesn't change the final text. It's off by default:
the first user found watching words appear distracting and felt it made results worse.
Turn it on in Settings.

### Choosing a microphone

Keet lists every input device through CoreAudio and binds its engine to the one you pick
by setting `kAudioOutputUnitProperty_CurrentDevice` on the input node. When a specific
device is set this way, `AVAudioEngine` posts `AVAudioEngineConfigurationChange` about
145 ms after starting, while it keeps running and capturing normally (confirmed on three
USB and built-in microphones with the `KEET_MIC_PROBE` diagnostic). Treating that notice
as "the microphone went away" ended every dictation at 145 ms. Keet only reacts when the
engine has actually stopped. It also rebuilds the engine when devices come and go or
the input's audio format changed while idle.

### How loud you need to be

Most wrong words come from quiet audio, not the model. `keet-bench noise` plays the test
clips at different levels over −54 dB of room noise and scores the transcripts:

| Speech peak | Word errors as recorded | With the volume raised afterwards |
|---|---|---|
| −12 dB | 0% | 0% |
| −24 dB | 3% | 3% |
| −30 dB | 1% | 2% |
| −36 dB | 11% | 12% |
| −42 dB | 30% | 23% |

Raising the volume in software after recording doesn't help, because it raises the room
noise with it; what matters is how far the voice sits above the room. Raising the
microphone's own input volume doesn't reliably help either: on one USB microphone,
going from 37% to 100% raised the room noise from −54 to about −47 dB while the voice
rose less, and the gap shrank from 18 to about 15 dB.

macOS voice processing (`AVAudioInputNode.setVoiceProcessingEnabled`: noise
suppression, automatic gain, echo cancellation) looked like the fix: in a one-off
3-second recording on that microphone it lowered the room noise from −43 to −60 dB.
But inside the app, where the engine is prepared, started and stopped for every
dictation, the voice-processing unit failed (CoreAudio error −10877) and capture
stalled, so the app stopped listening. The code path is still there
(`AudioRecorder.voiceProcessing`, `KEET_PROBE_UID` in the mic probe), off, and not
offered in Settings until it works across the full start/stop cycle. The first real
user's dictations peaked at a median of −36 dB on a USB microphone set to 37% input
volume, right where errors climb. So Settings has an input volume slider for the
microphone in use (CoreAudio `kAudioDevicePropertyVolumeScalar`, input scope), a test
meter that shows the peak in dB, and a note when recent dictations have been quiet. Each
dictation's peak level is stored in History for that note. Aim for peaks between −20 and
−10 dB.

### The Dictionary

No speech model knows your company's name or your clients'. The Dictionary fixes that
with FluidAudio's CTC word spotting (NVIDIA NeMo's method, arXiv:2406.07096). A second,
small model, Parakeet CTC 110M ([`FluidInference/parakeet-ctc-110m-coreml`](https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml),
revision `accdafd8cf8a2ff1cabe3c11e54416b405d409aa`, about 102 MB, CC-BY-4.0), runs over the
same audio and scores how strongly each dictionary word is present. A transcript word is
replaced by a dictionary word only when the two look alike and the audio supports the
dictionary word better, so ordinary words aren't rewritten.

Each word has the spelling you want and, optionally, what the model tends to hear
instead ("ZipLyne", heard as "zip line"). Words need at least 3 letters. They're kept in
`~/Library/Application Support/Keet/dictionary.json`. The word-spotting model is
downloaded the first time you add a word (`scripts/fetch-model.sh --dictionary` fetches
it ahead of time) into `~/Library/Application Support/FluidAudio/Models/parakeet-ctc-110m-coreml`.
FluidAudio has no call to switch word spotting off, so emptying the dictionary reloads
the main model without it, which takes about a tenth of a second.

Measured on eight spoken sentences full of one person's product names, with a seven-word
dictionary:

| | Without the Dictionary | With it |
|---|---|---|
| "ZipLyne" | "zip lony" | ZipLyne |
| "HotLyne" | "hotline" | HotLyne |
| "MentionWell" | "Mention Well" | MentionWell |
| "WitzLyne" | "width line" | WitzLyne |
| "Keet" | "Keat" | Keet |

With FluidAudio's default similarity bar (about 0.5), two ordinary words were wrongly
replaced: "headline" became "HotLyne" through the alias "hotline", and a misheard
"HotLyne" became "ZipLyne". Requiring 0.7 similarity per word kept all five fixes and
removed both mistakes; 0.8 started losing real fixes. The same dictionary run over twelve
ordinary sentences changed nothing. It adds about 100 ms per dictation (the word spotter
runs over the audio), and loading it takes about 12 s the very first time (Core ML
compiling for the Neural Engine) and about 0.15 s after that.

`keet-bench vocab <clips> <words.txt>` transcribes clips without and then with a
dictionary, one word per line, optionally followed by `|` and comma-separated
"heard as" spellings. `KEET_VOCAB_MINSIM` overrides the similarity bar.

### Knowing it's listening

When a hold becomes a dictation (160 ms in, the same moment the pill appears), Keet
plays a soft two-note chime, D6 then G6, about 100 ms long, synthesized in code. Waiting
160 ms keeps Option shortcuts silent. The chime reaches the microphone, so it was tested:
mixed into spoken clips at −30 dB, louder than the speech it preceded, it added no words
to any transcript. It can be turned off in Settings.

### Starting fast

The engine is built and prepared at launch and prepared again after every stop, so a
key press only has to call `start()`. The model is loaded and warmed at launch. The pill
waits 160 ms before appearing, the same threshold below which a press counts as a stray
tap, so Option shortcuts never flash it.

### Knowing it's a dictation and not a shortcut

The hotkey monitor is a listen-only `CGEventTap`: it can never block or delay typing,
even if Keet hangs. Left and right Option are told apart with the device-dependent
modifier bits in the event flags (`0x20` left, `0x40` right). A press only counts if no
other modifier is held. Any key, click, or extra modifier while holding cancels,
including Escape. Keet ignores the key while macOS secure input is on (password fields).
The tap re-enables itself if macOS switches it off, and checks for a release it may have
missed while off.

### Where the text goes

Keet asks Accessibility for the frontmost app's focused element and decides:

- **Text roles** (`AXTextField`, `AXTextArea`, `AXComboBox`, `AXSearchField`), elements
  whose value is settable, and elements that advertise a caret (`AXSelectedTextRange`)
  get the text pasted.
- **Known terminals** always get it pasted.
- **Everything else** (the desktop, lists, buttons, a web page with nothing selected)
  gets the Copy card.

Only attributes the element *advertises* count. Finder's desktop is an `AXGroup` that
answers a direct query for `AXSelectedTextRange` with an empty range even though it can't
hold text, so querying alone sent dictations into nothing.

Electron and Chromium apps (Slack, VS Code, Notion, Chrome) don't expose their
accessibility tree until asked. Keet sets `AXManualAccessibility` on each app when it
comes to the front, so the tree exists by the time you dictate.

When the caret sits right after a word, Keet adds a leading space.

### Pasting without losing your clipboard

Keet saves every item on the clipboard, puts the text on it (marked with the
`org.nspasteboard.TransientType` and `AutoGeneratedType` markers so clipboard managers
skip it), posts Command-V, and restores the original clipboard half a second later
unless something else was copied in between. The synthetic keystrokes carry a tag so
Keet's own hotkey monitor ignores them.

### The indicator

The pill and card are a borderless, non-activating `NSPanel` at the screen-saver window
level that joins all Spaces and full-screen apps. A fresh panel is created each time it
appears, so it lands in the Space you're in now. It goes on the screen holding the
window you're typing into (found through Accessibility), falling back to the screen
under the pointer. The card is sized to fit its content so no invisible part of the
window blocks clicks.

### Signing and permissions

macOS ties the Microphone and Accessibility grants to the app's code signature. A
Developer ID or Apple Development signature stays the same across rebuilds, so the grants
survive. Ad hoc signing changes with every build, so macOS asks again.

The bundle needs `NSMicrophoneUsageDescription` in `Info.plist` (macOS kills an app that
touches the microphone without it), the `com.apple.security.device.audio-input`
entitlement under the hardened runtime, and `LSUIElement` so it lives in the menu bar
without a Dock icon. It shows a Dock icon only while its window is open.

### History

Dictations are stored in `~/Library/Application Support/Keet/history.json`: text, time,
the app it went to, recording length, key-release-to-text time, and whether it was
pasted, shown on the card, or cancelled with Escape. Up to 10,000 are kept. Turning off **Keep history on this Mac**
deletes the file and keeps entries in memory until Keet quits.

## Build it

```bash
git clone https://github.com/ZipLyne-Agency/keet.git
cd keet
scripts/fetch-model.sh            # about 615 MB, resumable, checksum-verified
swift test                        # tail rule tests
scripts/build-app.sh --install    # build, sign, copy to /Applications
open /Applications/Keet.app
```

`build-app.sh` builds with SwiftPM, assembles `Keet.app` (executable, `Info.plist`, an
icon drawn by `scripts/make-icon.swift`, FluidAudio's resource bundle), and signs it. Set
`KEET_SIGN_IDENTITY` to pick a certificate, or `-` for ad hoc.

If you fork Keet, change `CFBundleIdentifier` in `Resources/Info.plist`.

## Verify it

```bash
scripts/make-test-clips.sh ~/keet-clips      # 12 spoken sentences in 10 macOS voices
.build/release/keet-bench transcribe ~/keet-clips/*.wav
.build/release/keet-bench lastword ~/keet-clips
.build/release/keet-bench tail ~/keet-clips -60          # room noise dB, optional speech gain dB
.build/release/keet-bench mic 3              # needs microphone permission for your terminal
```

Expected, on Apple Silicon: transcription in tens of milliseconds, 12 of 12 last words
kept in `lastword` for clips cut at the end of speech, and 12 of 12 kept in `tail`. The
clip in the robotic "Samantha" voice reading "Make sure the tests pass before you merge
it" comes out garbled in every variant; that's the voice, not the pipeline.

Per-dictation timings are in the system log:

```bash
/usr/bin/log show --last 10m --predicate 'subsystem == "agency.ziplyne.keet"'
```

Each dictation logs when the first audio arrived, the tail length, room noise,
threshold and peak levels, transcription time, and key release to text. Transcripts are
never logged.

### Testing without talking

The app has switches for automated tests. They're environment variables, so they never
affect normal use:

| Variable | Effect |
|---|---|
| `KEET_TEST_AUDIO=<wav>` | Feed this file in real time instead of the microphone |
| `KEET_FAKE_TEXT=<text>` | Skip the model and insert this text |
| `KEET_SKIP_MODEL=1` | Don't load the model |
| `KEET_DEMO_CARD=<text>` | Show the Copy card at launch |
| `KEET_TEST_SCREEN=<n>` | Put the overlay on screen `n` |
| `KEET_SNAPSHOT=<dir>` | Render the window and the pill with sample data to PNGs and quit |
| `KEET_MIC_PROBE=<file>` | Record 3 seconds from every input device and write what the engine did (`KEET_PROBE_UID=<uid>` records one device with voice processing off, then on) |

`keet-bench noise <clips> [noise dB] [peak dB...]` gives word error rates by speech level.

`scripts/drive.swift` posts synthetic key events, for example
`swift scripts/drive.swift hold 61 2000` holds Right Option for two seconds. Test with a
key you aren't using for real dictation, and don't run synthetic keys while someone is
typing: the pasted text lands in whatever app has focus.

## Project layout

| Path | What it holds |
|---|---|
| `Sources/KeetCore/Transcriber.swift` | Loading, warming and running the model |
| `Sources/KeetCore/AudioRecorder.swift` | Sink-node capture, device selection, test injection |
| `Sources/KeetCore/AudioDevices.swift` | Listing input devices and watching for changes |
| `Sources/KeetCore/SpeechTail.swift` | Loudness tracking, noise floor, threshold, the tail rule |
| `Sources/Keet/AppController.swift` | One dictation from key press to delivered text |
| `Sources/Keet/HotkeyMonitor.swift` | The event tap and bare-key rules |
| `Sources/Keet/TextInserter.swift` | Focus detection, paste, clipboard restore |
| `Sources/Keet/Overlay.swift` | The pill and the Copy card |
| `Sources/Keet/MainWindow.swift` | The history and settings window |
| `Sources/Keet/HistoryStore.swift` | Saved dictations |
| `Sources/Keet/DictionaryStore.swift` | Your dictionary words |
| `Sources/Keet/StartSound.swift` | The start chime |
| `Sources/Keet/StatusMenu.swift` | The menu bar item |
| `Sources/keet-bench/` | Benchmarks and experiments |
| `Tests/KeetCoreTests/` | Tests for the tail rule |
| `scripts/` | Build, model download, icon, test clips, key driver |

## Troubleshooting

**Nothing happens when I hold the key.** Open the Keet window: the status chip and the
Permissions section show what's missing. Another app using the same key (Wispr Flow,
for example, also defaults to Option) will fire at the same time; quit it or pick a
different key in Settings.

**macOS keeps asking for permissions after I rebuild.** The build is signed ad hoc. Build
with a Developer ID or Apple Development certificate. To reset a stuck grant:
`tccutil reset Accessibility agency.ziplyne.keet` and `tccutil reset Microphone agency.ziplyne.keet`.

**The pill doesn't appear on one display.** If even other apps' floating windows are
hidden there, macOS's Spaces are out of sync, which can happen after displays are
disconnected and reconnected. Open Mission Control and remove extra desktops, or turn on
System Settings > Desktop & Dock > "Displays have separate Spaces" and log out and back in.

**The Copy card appears even though a text field had focus.** That app reports its text
field in a way Keet doesn't recognize. Open an issue with the app's name.

**The model download is slow.** Hugging Face's CDN throttles some networks.
`scripts/fetch-model.sh` fetches the big file in eight parallel, resumable pieces; run it
again to continue where it stopped.

**AirPods sound bad while I dictate.** Bluetooth headsets switch to call quality while
their microphone is in use. Pick the Mac's built-in or a USB microphone in Settings.

## Known limits

- English only.
- The live words are a preview of the last 14 seconds; the final text arrives when you
  let go. On a 4-minute dictation that final pass takes about 1.4 s.
- If you press Enter within a few hundred milliseconds of letting go, the Enter can reach
  the app before the paste does.
- Focus detection is a heuristic. It is tested in TextEdit, Finder and terminals; other
  apps rely on the rules above.
