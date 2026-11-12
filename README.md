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
- **LLM polish before preview** — optionally fixes speech-recognition errors,
  grammar, and technical terms before preview. When an important ambiguity
  cannot be inferred safely, Whispr asks up to three short questions, then
  applies your answers in one final pass. Raw and polished versions remain
  available in the preview.
- **Written for coding agents** — the polish prompt assumes the reader is an
  agent such as Claude Code or Codex. It keeps what steers an agent exactly as
  you said it: how much freedom you gave ("just advise", "go ahead"), whether
  something was a question, your reasons, and every concrete detail. It
  resolves self-corrections, never adds requirements, and writes prose rather
  than fragments.
- **Project vocabulary** — Whispr works out which project the app you are
  dictating into has open and reads its type, function, file and dependency
  names. They are boosted during recognition and given to the polish model
  as known-correct spellings, so "app state dot swift" becomes
  `AppState.swift`.
- **Shows what polish changed, and learns** — names the polish step swapped in
  are listed above the preview and can be put back with a click. A name you
  type over something in the preview is remembered and used from then on.
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
- **Follows the microphone** — Bluetooth headsets renegotiate their format a
  moment after the mic opens; capture restarts instead of going silent.
- **API key in macOS Keychain**, local JSON history (last 100, can be
  disabled/cleared), mic-level meter, menu-bar only (no Dock icon).

## Requirements

- macOS 14+
- Xcode or Command Line Tools (build) — first run:
  `sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch`
- A [Deepgram](https://console.deepgram.com/signup) API key (pay-as-you-go
  credits work fine)
- An [OpenAI API key](https://platform.openai.com/api-keys) if you keep LLM
  Polish enabled (it is on by default)

## Build & run

```bash
make app        # builds .build/debug/Whispr and assembles Whispr.app
make run        # same, then launches it
make CONFIG=release run   # optimized build
```

First launch opens Settings: paste your Deepgram API key, click **Save**, then
**Test Connection**. For LLM polish, save a separate OpenAI-compatible API key
in **LLM Polish**. That section also configures the HTTPS base URL, model, and
reasoning effort (defaults: `https://api.openai.com/v1`, `gpt-5.6-terra`,
`low` — repairing a transcript is editing, and a low setting keeps the wait
before the preview short). Grant **Microphone** when prompted, and **Accessibility** (System
Settings → Privacy & Security → Accessibility) if you want direct pasting.

### One-time signing step (recommended)

Every rebuild changes the binary. macOS ties Keychain and Accessibility
grants to the code signature, so with ad-hoc signing you'll be re-prompted
after each rebuild. Create a persistent self-signed certificate once:

```bash
make cert
```

It creates the certificate, trusts it for code signing (macOS asks for your
login password) and signs a throwaway file to confirm it works. `make app`
then signs with the `Whispr Dev` identity automatically, and falls back to
ad-hoc signing if it is missing or unusable.

## Usage

| Action | How |
|---|---|
| Talk | Hold **Right ⌥**, speak, release |
| Hands-free | **⌃⌥Space** to start, again to stop |
| Insert transcript | **⌘↵** in the preview (or the Insert button) |
| Copy instead | **Copy** button |
| Discard | **Esc** |
| Abort mid-dictation | **✕** on the HUD |
| Cancel initial polish | **Esc** or **✕** on the Polishing panel |
| Re-copy old transcripts | menu bar → Recent, or History window |

If the preview warns *"No Accessibility — Insert copies instead"*, Insert
puts the text on your clipboard; paste manually with ⌘V.

### Vocabulary

Three lists feed recognition (as Nova-3 keyterms) and the polish glossary:

- **Vocabulary** in Settings — yours, always sent in full.
- **Learned from your corrections** — names you typed over something in the
  preview. Editable in Settings.
- **Project vocabulary** — read from the project the target app is working
  in. Whispr finds it from the focused window's document (terminals and
  editors publish it through Accessibility) and from the working directories
  of the app's child processes, such as a terminal's shells or the agent
  sessions a desktop app has started. Add folders in Settings to always
  include them, or turn the feature off there.

Deepgram caps keyterms at 500 tokens per connection, so learned and project
terms are admitted against a conservative budget; the polish glossary takes a
longer list. If Deepgram still refuses a connection, the session retries with
only your own Vocabulary.

Reading a project under Desktop, Documents or Downloads makes macOS ask once
whether Whispr may access that folder.

## Architecture

```
Sources/Whispr/
├── WhisprApp.swift            @main — menu-bar app, Settings & History scenes
├── AppState.swift             state machine: idle→connecting→recording→finishing→polishing→preview
├── Deepgram/
│   ├── DeepgramClient.swift   URLSessionWebSocketTask, ordered send pump, event stream
│   ├── DeepgramMessage.swift  frame decoding
│   └── TranscriptAssembler.swift  merges interim/final results without duplication
├── Polish/                    Chat Completions client, strict response parser, two-call flow
├── Audio/AudioCapture.swift   AVAudioEngine → resample to 16 kHz mono Int16 PCM
├── Hotkeys/HotkeyManager.swift  Carbon hotkey (toggle) + flagsChanged monitors (hold)
├── Insert/TextInserter.swift  clipboard swap + CGEvent ⌘V + clipboard restore
├── Vocabulary/                project detection, name harvesting, keyterm budget
├── Storage/                   KeychainStore, SettingsStore, HistoryStore
├── UI/                        HUDPanelController + SwiftUI views
└── Util/                      permissions, RMS level, word diff, string helpers
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
./Whispr.app/Contents/MacOS/Whispr --selftest-polish="fix the log in page"  # one production polish call
./Whispr.app/Contents/MacOS/Whispr --selftest-polish-mock  # deterministic unclear → resolution flow
./Whispr.app/Contents/MacOS/Whispr --selftest-vocab        # vocabulary for the frontmost app's project
./Whispr.app/Contents/MacOS/Whispr --selftest-vocab=~/code/app  # ...or for a given folder
```

`--selftest-file` runs the production session code (websocket, transcript
assembly, HUD, close, preview) — only the audio source is swapped from mic
to file. Generate test audio with `say -o /tmp/t.aiff "hello world"`.
`--selftest-polish` does not start hotkeys or open windows; it reports only a
well-formed outcome, never key material. The mock variant requires no network
or API key and verifies the two-call clarification limit. `--selftest-vocab`
prints the keyterms and glossary a dictation would use and needs neither.

## Tuning with your own dictations

Each history entry keeps three versions of a dictation — `raw` (what was
recognised), `polished` (what the model returned) and `text` (what you
inserted, after any edits) — plus `timings` for the wait between releasing
the key and seeing the preview. Where `polished` and `text` differ, the model
got something wrong; where `raw` and `polished` differ on a name, recognition
did. That file, `~/Library/Application Support/Whispr/history.json`, is the
evidence for judging a change to the prompt, the model, the reasoning effort
or the vocabulary.

## Notes & limitations

- English only (Nova-3 `en` default).
- No sandbox / notarization — personal-use build.
- Hotkeys are fixed (Right ⌥ hold, ⌃⌥Space toggle). Configurable bindings
  are a future item.
- Deepgram costs: streaming is billed per minute of audio; a dictation
  session only streams while you hold the key.
- **Privacy and cost:** LLM Polish is enabled by default. When enabled, each
  non-empty dictation and your vocabulary (your list, learned terms and
  project names) are sent to the configured HTTPS endpoint, which may bill
  for the request. Project vocabulary is on by default and also sends those
  names to Deepgram as keyterms. Only names leave your Mac: recent source
  files are scanned locally for declarations, and file contents are never
  sent. It can be turned off in Settings. Toggle **Polish before
  preview** off in the menu or Settings for zero LLM traffic. Both API keys
  are stored separately in the macOS Keychain, never in UserDefaults.

## License

MIT
