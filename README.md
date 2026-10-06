# Minutes

A native macOS menu-bar app that takes notes of your calls — Zoom, Google Meet (Chrome, Arc, Safari…),
Slack huddles, Discord, Teams, WhatsApp, Telegram, FaceTime — without bots or browser extensions.

- **Records both sides**: everything apps play (the other participants) through a Core Audio process tap,
  and your microphone, as two separate tracks.
- **Starts by itself** when a call begins and stops when it ends. Per app: start automatically, ask first, or ignore.
- **Knows when you're muted** by reading the meeting app's own mute button, and leaves what you say while
  muted out of the transcript.
- **Transcribes and writes notes with OpenRouter**: Gemini 3.8 Flash for speech (the most accurate of the models
  tested on real accented, mixed-language meetings, ~$0.08 per hour per track on Google's flex tier) and GPT-6
  Luna for notes: summary, key points, decisions, action items, open questions.
- **Personal notes**: tell it who you are (Settings › AI › About you) and key points, decisions, action items and
  open questions are written for your role, your own tasks first; the summary stays a general overview.
- **Knows who's talking**: on-device speaker recognition labels every voice consistently through the meeting;
  name a voice once (click it in the transcript) and Minutes recognises that person in later meetings.
- **Removes echo**: when the call plays through laptop speakers, the mic's copy of it is detected and silenced
  before transcription.
- **Leaves out invented lines**: text the speech model writes where the recording is (nearly) silent is dropped.
- **History** of every meeting; download any of them as Markdown.

Built for personal use on macOS 26+ (developed on macOS 27, Apple Silicon).

## Build and install

Requires Xcode (Swift 6.2+) and an *Apple Development* signing identity (so macOS remembers the app's
permissions across rebuilds).

```sh
scripts/build-app.sh           # release build → ~/Applications/Minutes.app, then launches it
scripts/build-app.sh debug     # faster builds while developing
```

Set `MINUTES_SIGN_IDENTITY` to pick a specific signing identity.

On first launch, click the menu-bar icon → **Finish setup…** to grant permissions, add your
[OpenRouter API key](https://openrouter.ai/keys) (stored in the Keychain) and run a short audio check.

## Using it

| | |
|---|---|
| **⌃⌥⌘N** | Start / stop taking notes (works for any call, even unsupported apps) |
| **⌃⌥⌘M** | Leave your mic out of the transcript until pressed again (when mute can't be detected) |
| Menu-bar icon | Status, level meters, mute state, recent meetings, History, Settings |

Shortcuts can be changed in Settings › General.

When a call ends, the notes appear in **History** (and as a notification). Use **Download .md** to save
them, with or without the transcript. **More › Re-transcribe** runs a meeting again with the current model, and
**Regenerate Notes** rewrites its notes (e.g. after filling in *About you*). Filler-only lines ("Mm", "Okay")
are hidden from transcripts and exports by default.

If the same call drops and comes back within 3 minutes (30 s for apps without a meeting code), the recording
continues in the same meeting.

Laptop speakers leak the call into your mic; Minutes removes those echoed lines, but headphones avoid them.

## How it works

```
Core Audio process list ──► CallDetector ──► SessionController ──► Recorder ──► ~5-min FLAC chunks
(who holds the mic)          (+ Zoom menu,        │                  (tap + mic,      │
                              Slack huddle,       │                   aligned,        ▼
                              Meet tab/title)     ▼                   watchdog)   ProcessingCenter
                                             MuteMonitor ──► mute timeline ──►  (silences muted
                                             (Accessibility)                     speech) ─► OpenRouter
                                                                                 transcription per chunk
                                                                                 ─► merged transcript
                                                                                 ─► notes model
```

- **Meeting audio**: a global, unmuted Core Audio process tap (macOS 14.2+) on a private tap-only
  aggregate device, excluding Minutes itself and music players. A watchdog rebuilds it when the output
  device changes (e.g. AirPods switching to call mode), when Core Audio restarts, or when it stays silent
  while apps are playing.
- **Your voice**: the default input through a plain `AVAudioEngine` (no voice processing — it would duck
  other apps).
- **Call detection**: Core Audio's per-process objects say which app holds the mic (no permission needed);
  helper processes are mapped to their app. A meeting is confirmed by Zoom's "Meeting" menu, Slack's
  "Leave huddle" control, or a browser window titled "Meet - …" / a meet.google.com tab.
- **Mute detection**: Accessibility reads the app's own control ("Mute audio"/"Unmute audio" in Zoom's
  menu, "Turn off/on microphone" in Meet, "Mute/Unmute microphone" in Slack, Discord's Mute/Deafen
  switches). If the app isn't using the mic at all, you count as muted. Unknown → your mic is included.
  Rules live in `Sources/Minutes/Detection/AppCatalog.swift`; Settings › Diagnostics can save an app's
  accessibility tree to adjust them after an app update.
- **Privacy**: muted stretches are silenced before audio leaves the Mac. Requests go to OpenRouter with
  `provider: {zdr: true, data_collection: "deny"}` (endpoints that don't store or train on data). Audio is
  kept locally for 30 days by default (Settings › Privacy & Storage).

### Files

Each meeting is a folder in `~/Library/Application Support/Minutes/meetings/`:
`meeting.json` (metadata, chunk states, mute timeline, cost), `transcript.json`, `notes.json`, `notes.md`,
`raw/` (per-chunk model output) and `audio/` (FLAC chunks). Logs: `~/Library/Logs/Minutes/`.

If Minutes quits or crashes mid-call, the recording is recovered and processed on next launch.

## Model bench

To compare transcription and notes models on your own audio:

```sh
scripts/make-bench-audio.py                         # synthetic EN / ID / MS / code-switching clips → bench/samples
~/Applications/Minutes.app/Contents/MacOS/Minutes --bench bench/samples \
    [--models a,b] [--notes-models x,y] [--urgent] [--no-zdr]
```

It reports word error rate, start-time error, words invented during silence, cost and latency per model,
and writes each notes model's output to `bench/samples/output/` for side-by-side reading. Drop real
recordings (FLAC + reference `.txt`) into the folder to test with your own voice and languages.

## Acknowledgements

- Speaker recognition uses [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0) and its
  speaker-diarization CoreML models (CC-BY-4.0, [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml),
  derived from pyannote and WeSpeaker), downloaded once (~22 MB) to `~/Library/Application Support/FluidAudio`.
- Echo detection and the notes structure follow ideas from [OpenWhispr](https://github.com/OpenWhispr/openwhispr) (MIT).

## Permissions

| Permission | Why |
|---|---|
| Microphone | your side of the call |
| System Audio Recording Only | the other participants (Privacy & Security › Screen & System Audio Recording) |
| Accessibility | mute state, Zoom/Slack call confirmation, browser window titles |
| Automation (per browser) | reading tab URLs to find a Meet call that isn't the front tab |
| Notifications | "notes ready", and asking before recording "ask first" apps |
