# Call Assistant

A self-hosted call assistant for the Mac (an iPhone app comes later). It
listens to both sides of a call, transcribes them live on the Mac, and saves
each call as a Markdown transcript. Live answers from Claude, playbooks, a
phone companion app and codebase lookups are planned next.

**Status:** Phase 1 (Mac audio capture and live transcript) is built. See
[docs/plans/2026-10-20-phase-1-mac-core.md](docs/plans/2026-10-20-phase-1-mac-core.md)
for the plan, what was measured, and the phases after it.

## What it does now

- **Both sides of the call, kept apart.**
  - Your microphone is "Me".
  - The Mac's own audio output (the call app, through a Core Audio process tap) is "Them".
- **Live transcription on the Mac.**
  - It uses Apple's built-in speech recognizer (`SpeechAnalyzer`, macOS 26+).
  - No audio leaves the Mac, and macOS manages the speech model.
- **Echo handling for speakers.** When you're not on headphones, the mic hears the other side, so three things deal with it:
  - WebRTC's AEC3 echo canceller removes the speakers' sound from the mic, using the system audio as the reference. It doesn't turn the call down.
  - A text filter drops any "Me" line that repeats what "Them" just said, as a backup.
  - Apple's own voice processing is available but off, because it turns other audio down.
- **The window.**
  - Start/Stop, the live transcript with each side's text in progress, and a status bar.
  - Copy Transcript, Open Sessions Folder, and Keep on Top (it floats above the call app by default).
- **Saved transcripts.** One Markdown file per call in `~/Library/Application Support/CallAssistant/Sessions/`, written line by line as the call goes.

## Requirements

- An Apple Silicon Mac with macOS 26 or later. It has been tested on macOS 27.0.1.
- Xcode 27 (Swift 6.4).
- An Apple Development signing identity in your keychain. The build signs the app with it so that macOS remembers the microphone and system-audio permissions between builds.
- `meson` and `ninja` to build WebRTC's echo canceller: `brew install meson ninja`.

## Build and run

```bash
scripts/build_mac_app.sh
```

This builds WebRTC's audio processing library the first time (into
`mac/Vendor/`, not committed; it downloads the library's source and abseil),
then builds, bundles and signs `mac/dist/CallAssistant.app`.

```bash
open mac/dist/CallAssistant.app
```

On the first Start, macOS asks for **Microphone** and **System Audio Recording**
access for Call Assistant. Allow both.

## Developer checks

The app has command-line probes that test one layer at a time without the
window. Launch them through `open` so macOS asks for permissions on Call
Assistant's behalf:

```bash
open mac/dist/CallAssistant.app --stdout /tmp/ca.log --stderr /tmp/ca.log --args --probe-live 30
```

- `--probe-audio N`: mic and system-audio levels once a second. Add `--apple-voice-processing` to use Apple's voice processing.
- `--probe-transcribe <file>`: transcribes an audio file as if it were live.
- `--probe-live N`: a whole call without the window. The flags `--no-echo-canceller`, `--no-echo-filter` and `--apple-voice-processing` turn each echo method on or off.

Unit tests: `cd mac && swift test`.

## Third-party code

Audio capture is adapted from [OpenOats](https://github.com/yazinsai/OpenOats)
(MIT). The echo canceller is WebRTC's audio processing module (BSD-3) with
abseil (Apache-2.0). Details are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
