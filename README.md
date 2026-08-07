# Whispr

A private, developer-focused dictation app for macOS. Hold a key, speak,
review the transcript, then insert it into whatever app you were using.
Powered by Deepgram **Nova-3** streaming transcription with your own API key.

Built for people who want Wispr-Flow-style dictation without a subscription —
and with a **preview step** so nothing ever gets typed until you've seen it.

```
Hold Right ⌥  →  speak  →  release
                live transcript streams into the HUD
                editable preview appears
                ⌘↵ Insert  ·  Esc Cancel  ·  Copy
```

## Features

- **Preview-first flow** — dictation never types anything until you press
  Insert. Edit the transcript in place before it goes anywhere.
- **Two ways to talk**: hold-to-talk (Right ⌥) or hands-free toggle (⌃⌥Space).
- **Streaming Deepgram Nova-3** over WebSocket with smart formatting and
  tuned endpointing (`endpointing=800`, `utterance_end_ms=1000`) for
  continuous dictation instead of fragmented utterances.
- **Vocabulary boosting** — up to 100 Nova-3 *keyterms* (names, jargon,
  project terms) edited in Settings, one per line.
- **Safe insertion**: clipboard-swap + ⌘V into the app you were just using,
  then your old clipboard is restored. **Never presses Return** — terminal-safe
  by default.
- **Graceful degradation**: no Accessibility permission → copies to clipboard
  and tells you, instead of failing silently. Network drop mid-sentence →
  salvages the partial transcript into the preview.
- **API key in macOS Keychain**, local JSON history (last 100, can be
  disabled/cleared), mic-level meter, menu-bar only (no Dock icon).

## Requirements

- macOS 14+
- Xcode or Command Line Tools (build) — first run:
  `sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch`
- A [Deepgram](https://console.deepgram.com/signup) API key (pay-as-you-go
  credits work fine)

## Build & run

```bash
make app        # builds .build/debug/Whispr and assembles Whispr.app
make run        # same, then launches it
make CONFIG=release run   # optimized build
```

First launch opens Settings: paste your API key, click **Save**, then
**Test Connection**. Grant **Microphone** when prompted, and
**Accessibility** (System Settings → Privacy & Security → Accessibility) if
you want direct pasting.

### One-time signing step (recommended)

Every rebuild changes the binary. macOS ties Keychain and Accessibility
grants to the code signature, so with ad-hoc signing you'll be re-prompted
after each rebuild. Create a persistent self-signed certificate once:

```bash
make cert
```

`make app` automatically signs with the `Whispr Dev` identity when it exists.

## Usage

| Action | How |
|---|---|
| Talk | Hold **Right ⌥**, speak, release |
| Hands-free | **⌃⌥Space** to start, again to stop |
| Insert transcript | **⌘↵** in the preview (or the Insert button) |
| Copy instead | **Copy** button |
| Discard | **Esc** |
| Abort mid-dictation | **✕** on the HUD |
| Re-copy old transcripts | menu bar → Recent, or History window |

If the preview warns *"No Accessibility — Insert copies instead"*, Insert
puts the text on your clipboard; paste manually with ⌘V.

## Architecture

```
Sources/Whispr/
├── WhisprApp.swift            @main — menu-bar app, Settings & History scenes
├── AppState.swift             state machine: idle→connecting→recording→finishing→preview
├── Deepgram/
│   ├── DeepgramClient.swift   URLSessionWebSocketTask, ordered send pump, event stream
│   ├── DeepgramMessage.swift  frame decoding
│   └── TranscriptAssembler.swift  merges interim/final results without duplication
├── Audio/AudioCapture.swift   AVAudioEngine → resample to 16 kHz mono Int16 PCM
├── Hotkeys/HotkeyManager.swift  Carbon hotkey (toggle) + flagsChanged monitors (hold)
├── Insert/TextInserter.swift  clipboard swap + CGEvent ⌘V + clipboard restore
├── Storage/                   KeychainStore, SettingsStore, HistoryStore
├── UI/                        HUDPanelController + SwiftUI views
└── Util/                      permissions, RMS level, string helpers
```

Concurrency: Swift 6 strict mode. `AppState` is `@MainActor`; the audio tap
(realtime thread) only converts and yields into an `AsyncStream`;
`DeepgramClient` is sendable with a lock-guarded serial send pump so frames
arrive in order.

## Self-tests

The binary has CLI entry points that exercise the pipeline without hotkeys:

```bash
./Whispr.app/Contents/MacOS/Whispr --selftest-connection     # websocket + API key check
./Whispr.app/Contents/MacOS/Whispr --selftest-mic=4          # capture 4 s, report signal levels
./Whispr.app/Contents/MacOS/Whispr --selftest-file=audio.aiff  # stream a file through a real session → preview panel
```

`--selftest-file` runs the production session code (websocket, transcript
assembly, HUD, close, preview) — only the audio source is swapped from mic
to file. Generate test audio with `say -o /tmp/t.aiff "hello world"`.

## Notes & limitations

- English only (Nova-3 `en` default).
- No sandbox / notarization — personal-use build.
- Hotkeys are fixed (Right ⌥ hold, ⌃⌥Space toggle). Configurable bindings
  are a future item.
- Deepgram costs: streaming is billed per minute of audio; a dictation
  session only streams while you hold the key.

## License

MIT
