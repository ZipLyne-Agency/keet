# Keet

Push-to-talk dictation for the Mac that runs entirely on your machine. Hold **Left
Option**, talk, let go, and the text appears wherever your cursor is. Nothing you say
leaves the Mac.

Keet transcribes with NVIDIA's **Parakeet Unified 0.6B** (English) on the Apple Neural
Engine, through [FluidAudio](https://github.com/FluidInference/FluidAudio). Transcribing a
few seconds of speech takes 30 to 70 ms on an M5 Max, and capture starts within about
30 ms of pressing the key.

- **Hold to talk.** A small waveform pill at the bottom of the screen shows it's listening.
- **The last word always makes it.** Keet keeps listening for a moment after you let go,
  but only while you're still finishing a word. See [how](docs/REMAKE.md#the-tail-why-the-last-word-never-gets-cut).
- **No text field? No lost words.** If nothing can take text, a card shows what you said with a Copy button.
- **Everything you've said, in one place.** The Keet window keeps your history with search,
  copy, paste-into-the-last-app, and export.
- **Your choice of microphone**, with a live level test.

## Requirements

- A Mac with Apple Silicon (M1 or later) on macOS 15 Sequoia or later
- Xcode 26 or later to build it
- About 615 MB of disk for the speech model

Built and measured on a MacBook Pro with M5 Max running macOS 27 and Xcode 27.

## Install

```bash
git clone https://github.com/ZipLyne-Agency/keet.git
cd keet
scripts/fetch-model.sh           # optional: Keet also downloads the model on first launch
scripts/build-app.sh --install   # builds, signs, copies to /Applications
open /Applications/Keet.app
```

On first launch macOS asks for two permissions. **Microphone** lets Keet hear you
while you hold the key. **Accessibility** lets it see the key and paste the text.
The Keet window shows whether both are granted.

If you have an Apple Developer ID or Apple Development certificate, `build-app.sh`
signs with it, and macOS remembers the permissions across rebuilds. Without one it
signs ad hoc, and macOS asks again after every rebuild.

## Using it

| Action | What happens |
|---|---|
| Hold Left Option and talk | The pill appears and follows your voice |
| Let go | The text is pasted where your cursor is |
| Escape while holding | Cancels |
| Option + another key, or a click | Treated as a normal shortcut, never a dictation |
| Let go with no text field focused | A card shows the text with a Copy button |

Open the window from the menu bar icon (or launch Keet again) to see your history and
change the dictation key, microphone, and settings. Your clipboard is restored after
each paste.

## Privacy

Audio is never written to disk and never leaves the Mac. Transcripts are kept in
`~/Library/Application Support/Keet/history.json` so you can find them later; turn off
**Keep history on this Mac** in Settings to keep them only until Keet quits. Logs record
timings and levels, never what you said.

## Documentation

- **[docs/REMAKE.md](docs/REMAKE.md)**: the full rebuild guide. What you need, the exact
  model and files, how a dictation flows, every design decision with the measurements
  behind it, and troubleshooting.
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md): dependency and model licenses.

## License

Keet is MIT licensed. The speech model is not part of this repository and has its own
licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
