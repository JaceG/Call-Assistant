# Call Assistant

A self-hosted call assistant for the Mac. It listens to both sides of a
call, transcribes them live on the Mac, answers the other person's questions
with Claude as the call goes (using folders and files you pick, such as a
project's code or your resume), and saves each call as a Markdown transcript.

**Status:**
- **Phase 1**, Mac audio capture and live transcript, is built. See [docs/plans/2026-10-20-phase-1-mac-core.md](docs/plans/2026-10-20-phase-1-mac-core.md) for its plan, what was measured, and the phases after it.
- **Phase 2**, Claude answers and playbooks, is built. See [docs/plans/2026-10-20-phase-2-answers.md](docs/plans/2026-10-20-phase-2-answers.md).
- **Phase 3**, folders and files for a call, is built. See [docs/plans/2026-10-20-phase-3-files.md](docs/plans/2026-10-20-phase-3-files.md). It's the last phase: the iPhone app, remote access, screen capture and headless mode were dropped.

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
- **Answers from Claude** (`claude-sonnet-5-5`), shown under the transcript as they're written. There are four ways to ask:
  - **Auto-Answer** (the lightning-bolt button): when the other side asks something, Claude answers once they pause. It answers every question it spots, small talk included, so turn it off during chit-chat.
  - **Answer Now** (the sparkles button, or **⌃⌥A** from any app): Claude helps you respond to what they just said.
  - **Ask Claude…**: type a question under the answers and press Return. This works without a call too.
  - **Quick-action buttons** above Ask Claude send a saved prompt in one click: **Shorter**, **Simpler**, **Example**, **Ask them** (a question to ask them now) and **Recap**. The slider button at the end of the row opens an editor to rename them, change their prompts, drag them into a new order, add your own or restore the starters.

  A new Answer Now, typed question or quick action stops an answer that's still being written.

  Every answer sees the whole call so far, including Claude's own earlier answers, so you can type "make that shorter" or "say it more casually". Your own latest words count straight away, even while they're still being checked for echo.
- **Playbooks and call notes.** These are instructions Claude follows in every answer:
  - **A playbook** is a Markdown file per kind of call (an interview, a client check-in), picked from the **Playbook** menu.
  - **Call Notes** are for this one call (who it's with, what it's about).
- **Files** (the books button): folders and files Claude uses in its answers, such as a project's code for a technical call or your resume for an interview. See [Files](#files).
- **Always instructions** (**Playbook** menu > **Edit Always Instructions…**): instructions Claude follows on every call, whatever playbook you pick, such as facts about you or how long answers should be.
- **A live summary** (the **Summary** button, top right): a running document of the call in a side panel. The pop-out button opens it in its own window. It holds:
  - a short summary and key points
  - their questions with what was said back
  - quotes, decisions and action items
  - open questions, and names and numbers mentioned
  - where the conversation could go next

  It updates at most once a minute, only when something new was said. Items new since the last update are highlighted until the next one. While your pointer is over the summary, a new version waits and an **Update Now** button appears. It's saved beside the call's transcript as `<day> <time> summary.md`, and **Copy** copies it as Markdown.
- **Suggestions after each call.** When you press Stop, Claude reviews how you used the app: what you asked to shorten, what you typed, and what you actually said. After about 10 seconds the status bar shows **Review N Suggestions**. It opens a sheet with:
  - lines to add to your Always instructions
  - new quick-action buttons
  - feature ideas for the app, which you can keep in `Feature Ideas.md` for a developer, or copy

  Nothing changes until you click **Add** or **Keep**. Every choice is logged in `Learning.md`, so a skipped suggestion isn't made again.

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

**What gets sent:** for each answer, the call's transcript so far, the playbook, the call notes and the picked files go to Anthropic's API (all of their text, or only the parts Claude searches for and reads; see [Files](#files)). Audio never leaves the Mac.

**Cost** (an estimate, at Sonnet 5.5's list price of $2 / $10 per million input / output tokens):
- Well under 1 cent for an answer early in a call.
- Late in an hour-long call, up to about 3–4 cents for an answer that can't use the cache.
- Prompt caching re-reads earlier parts of the transcript at a tenth of the price, which brings a late answer to about 1 cent. In a test with a 120-line transcript, every answer after the first read 5,289 cached tokens.
- Picked files add to this; [Files](#files) has the figures.
- The live summary costs about 1 cent per update, so about 60 cents for an hour-long call (an estimate). The review after a call is a few cents.

### Playbooks

Playbooks live in `~/Library/Application Support/CallAssistant/Playbooks/`, one `.md` file each. The file name is the playbook's name in the menu. The app creates a starter `General.md`.

Write instructions as you'd brief an assistant, for example:

```markdown
I'm interviewing for a senior iOS role. Answer as me, in the first person.
My background: 8 years of Swift, SwiftUI since 2020, offline-first apps.
Keep answers to two sentences I can say out loud, then up to three bullets.
```

Write only instructions in the file: Claude reads all of it. New or edited files show up in the menu when you switch back to the app.

### Files

Click the **Files** button (books) and **Add Folders or Files…**. Your picks stay until you remove them, for every call, like the playbook. They're read again when you press Start, so edits since you picked them count.

**What's read:**
- Text and code files, and the text of PDFs and Word (`.docx`, `.doc`), `.rtf` and `.odt` documents.
- In a folder that's a git repository, the files git lists, so `.gitignore` applies. Elsewhere, everything except hidden files and folders like `node_modules`, `build`, `dist`, `.build`, `DerivedData` and `Pods`.

**What's skipped,** listed under "skipped" in the popover with the reason:
- **Secrets files are never read or sent, even if you pick one:** `.env*`, `.npmrc`, `.netrc`, `.pypirc`, keys and certificates (`.pem`, `.key`, `.p12`, `.p8`…), and SSH keys (`id_rsa`…).
- Lockfiles, minified or bundled files, source maps, images, audio, video, archives and other binaries, and any file with over 1 MB of text.

**How Claude uses them:** the popover says which way it is.
- **Up to about 150,000 tokens** (about 375 KB of text, a mid-size project): Claude gets all of it with every answer. It's cached for an hour, and the cache is filled when you press Start, so answers start about as fast as without files.
  - Measured with this repository (143,219 tokens): about 1 s to the first words, 2 s to fill the cache.
- **More than that:** Claude gets the list of files, and searches and reads them when a question needs it. The answer shows what it's looking at ("Searching the files for "terminal"…").
  - Measured with a 925-file website project: the answer appears about 3.5–4.5 s after asking, all at once rather than word by word. Questions that don't need the files still answer as fast as usual.

**Cost** (estimates from the measured token counts, at Sonnet 5.5's prices):
- **Whole, 143,000 tokens:** about 57 cents to fill the cache at the start of a call (once an hour), then about 3 cents per answer. Smaller picks cost proportionally less.
- **Searched:** about 15 cents to cache the file list for a 925-file project, then about 3 cents for an answer that looks something up.

macOS may ask whether Call Assistant can use files in Documents, Desktop or Downloads the first time it reads picks from those folders.

## Developer checks

The app has command-line probes that test one layer at a time without the
window. Launch them through `open` so macOS asks for permissions on Call
Assistant's behalf:

```bash
open mac/dist/CallAssistant.app --stdout /tmp/ca.log --stderr /tmp/ca.log --args --probe-live 30
```

- `--probe-audio N`: mic and system-audio levels once a second. Add `--apple-voice-processing` to use Apple's voice processing.
- `--probe-transcribe <file>`: transcribes an audio file as if it were live.
- `--probe-live N`: a whole call without the window. The flags `--no-echo-canceller`, `--no-echo-filter` and `--apple-voice-processing` turn each echo method on or off. Add `--auto-answer` to have Claude answer the questions it spots, with timings. Each live summary is printed as it arrives.
- `--probe-answer "<question>"`: asks Claude and prints the time to the first words, the token counts (including cache reads) and the answer. Options:
  - `--runs N`
  - `--transcript <call.md>`
  - `--playbook <name>`
  - `--notes "<text>"`
  - `--effort low|medium|high`
  - `--thinking-off`
  - `--files <folder or file>` (repeatable): answer with these picked, as a call would.
  - `--warm`: fill the cache first and print how long that took.
  - `--detected` or `--answer-now`: ask the way Auto-Answer or Answer Now does, instead of as a typed question.
- `--probe-follow-up "<question>" "<follow-up>"...`: types each question in turn, waiting for each answer, so later ones can refer to earlier answers ("Make that shorter").
- `--probe-detect <call.md>`: replays a saved call and lists the lines Auto-Answer would answer. It makes no API call.
- `--probe-summary <call.md>`: summarizes the first 60% of a saved call, then all of it building on the first version, and prints both.
- `--probe-review <call.md>`: reviews a saved call as the app would after Stop and prints the suggestions. It writes nothing.
- `--probe-files <folder or file>...`: reads picks as a call would and prints the file count, the size, whole or search, the largest files and what was skipped. It makes no API call.

Unit tests: `cd mac && swift test`.

## Third-party code

Audio capture is adapted from [OpenOats](https://github.com/yazinsai/OpenOats)
(MIT). The echo canceller is WebRTC's audio processing module (BSD-3) with
abseil (Apache-2.0). Details are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
