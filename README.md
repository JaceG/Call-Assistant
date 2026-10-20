# Call Assistant

A self-hosted call assistant for the Mac (an iPhone app comes later). It
listens to both sides of a call, transcribes them live on the Mac, answers
the other person's questions with Claude as the call goes, and saves each
call as a Markdown transcript. A phone companion app and codebase lookups are
planned next.

**Status:**
- **Phase 1**, Mac audio capture and live transcript, is built. See [docs/plans/2026-10-20-phase-1-mac-core.md](docs/plans/2026-10-20-phase-1-mac-core.md) for its plan, what was measured, and the phases after it.
- **Phase 2**, Claude answers and playbooks, is built. See [docs/plans/2026-10-20-phase-2-answers.md](docs/plans/2026-10-20-phase-2-answers.md).

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
- **Saved transcripts.** One Markdown file per call in `~/Library/Application Support/CallAssistant/Sessions/`, written line by line as the call goes. Claude's answers are saved in it too, as quotes.
- **Answers from Claude** (`claude-sonnet-5-5`), shown under the transcript as they're written. There are three ways to ask:
  - **Auto-Answer** (the lightning-bolt button): when the other side asks something, Claude answers once they pause. It answers every question it spots, small talk included, so turn it off during chit-chat.
  - **Answer Now** (the sparkles button, or **⌃⌥A** from any app): Claude helps you respond to what they just said.
  - **Ask Claude…**: type a question under the answers and press Return. This works without a call too.

  A new Answer Now or typed question stops an answer that's still being written.
- **Playbooks and call notes.** These are instructions Claude follows in every answer:
  - **A playbook** is a Markdown file per kind of call (an interview, a client check-in), picked from the **Playbook** menu.
  - **Call Notes** are for this one call (who it's with, what it's about).

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

### Claude API key

Answers need an Anthropic API key from [console.anthropic.com](https://console.anthropic.com). The API is billed separately from a Claude subscription. Save the key in your login Keychain:

```bash
security add-generic-password -U -s com.jaceg.callassistant -a anthropic-api-key -l "Call Assistant - Claude API key" -w
```

It asks for the key twice and doesn't show it. The first time the app reads it, macOS asks whether Call Assistant may use it. Click **Always Allow**.

**What gets sent:** for each answer, the call's transcript so far, the playbook and the call notes go to Anthropic's API. Audio never leaves the Mac.

**Cost** (an estimate, at Sonnet 5.5's list price of $2 / $10 per million input / output tokens):
- Well under 1 cent for an answer early in a call.
- Late in an hour-long call, up to about 3–4 cents for an answer that can't use the cache.
- Prompt caching re-reads earlier parts of the transcript at a tenth of the price, which brings a late answer to about 1 cent. In a test with a 120-line transcript, every answer after the first read 5,289 cached tokens.

### Playbooks

Playbooks live in `~/Library/Application Support/CallAssistant/Playbooks/`, one `.md` file each. The file name is the playbook's name in the menu. The app creates a starter `General.md`.

Write instructions as you'd brief an assistant, for example:

```markdown
I'm interviewing for a senior iOS role. Answer as me, in the first person.
My background: 8 years of Swift, SwiftUI since 2020, offline-first apps.
Keep answers to two sentences I can say out loud, then up to three bullets.
```

Write only instructions in the file: Claude reads all of it. New or edited files show up in the menu when you switch back to the app.

## Developer checks

The app has command-line probes that test one layer at a time without the
window. Launch them through `open` so macOS asks for permissions on Call
Assistant's behalf:

```bash
open mac/dist/CallAssistant.app --stdout /tmp/ca.log --stderr /tmp/ca.log --args --probe-live 30
```

- `--probe-audio N`: mic and system-audio levels once a second. Add `--apple-voice-processing` to use Apple's voice processing.
- `--probe-transcribe <file>`: transcribes an audio file as if it were live.
- `--probe-live N`: a whole call without the window. The flags `--no-echo-canceller`, `--no-echo-filter` and `--apple-voice-processing` turn each echo method on or off. Add `--auto-answer` to have Claude answer the questions it spots, with timings.
- `--probe-answer "<question>"`: asks Claude and prints the time to the first words, the token counts (including cache reads) and the answer. Options:
  - `--runs N`
  - `--transcript <call.md>`
  - `--playbook <name>`
  - `--notes "<text>"`
  - `--effort low|medium|high`
  - `--thinking-off`
- `--probe-detect <call.md>`: replays a saved call and lists the lines Auto-Answer would answer. It makes no API call.

Unit tests: `cd mac && swift test`.

## Third-party code

Audio capture is adapted from [OpenOats](https://github.com/yazinsai/OpenOats)
(MIT). The echo canceller is WebRTC's audio processing module (BSD-3) with
abseil (Apache-2.0). Details are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
