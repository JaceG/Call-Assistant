# Phase 1: Mac Core Plan

**Goal:** A signed macOS app that captures the call's audio (my mic and the system audio, as separate channels), transcribes both live on the Mac, shows a live "Me / Them" transcript in a window, and saves it to disk.
**Approach:**
- **Code:** a Swift package with a library (`CallCore`) and a thin SwiftUI app target. Audio capture and streaming transcription are copied from OpenOats (MIT) and trimmed. The transcript model, the session file writer and the session orchestration are new.
- **Build:** a script wraps the binary into a `.app` signed with the local Apple Development identity, so macOS permissions persist across rebuilds.
- **Testing:** each risky layer gets a command-line probe built into the app, so it can be checked without the UI.

**Stack:** Swift 6.4 (tools 6.2), SwiftUI, macOS 26+, Core Audio process taps, AVAudioEngine, FluidAudio 0.13.5 (Silero VAD + Parakeet TDT v2), Swift Testing.
**Spec:** `private/HANDOFF.md` (gitignored: decisions, requirements) and `cluely-alternative-fact-check.md` (research).

## Out of scope (later phases), but don't block them
Phase order (Jace, 2026-10-20): 1 Mac core → 2 Claude answers + playbooks → 3 phone server + iPhone app → 4 screen capture + call recording (Mac only) → 5 codebase index → 6 headless → 7 Tailscale/AWS. The iPhone app doesn't capture its own screen or record calls.
- Claude answers and playbooks (Phase 2): `CallCore` will hold the answer engine, so keep the transcript store observable and the session API small.
- The phone server and iPhone app (Phase 3), and headless mode (Phase 6): all session logic lives in `CallCore`, not in views, so a server and a windowless mode can drive it.
- Screen capture and call recording on the Mac (Phase 4).
- The codebase index (Phase 5). Remote access (Phase 7).
- WhisperKit: Parakeet v2 is English only. WhisperKit (multilingual) can be added behind the same `TranscriptionBackend` protocol later.
- Echo filtering by text similarity: see Risks in Task 5.

## File map

```
mac/
  Package.swift                     products: library CallCore, executable CallAssistant
  Sources/
    CallCore/
      ThirdParty/OpenOats/          copied from reference/OpenOats (commit ea405d8), each with a header naming the source and changes
        SystemAudioCapture.swift    process-tap system audio → AsyncStream<AVAudioPCMBuffer>
        MicCapture.swift            AVAudioEngine mic → AsyncStream<AVAudioPCMBuffer> (+ AudioLevel/Sync* helpers it defines)
        StreamingAudioConverter.swift  buffer → 16 kHz mono Float samples
        StreamingTranscriber.swift  VAD loop → partial/final segments (trimmed: no cloud queue, no diagnostics)
        TranscriptionBackend.swift  protocol + BackendStatus
        ParakeetBackend.swift       FluidAudio Parakeet TDT, model dir from ModelStore
      Logging.swift                 `Log` os.Logger categories the copied files use (streaming, systemAudio, mic)
      ModelStore.swift              where models live: ~/Library/Application Support/CallAssistant/Models/…
      Transcript/
        Speaker.swift               .me / .them
        Utterance.swift
        TranscriptStore.swift       @Observable list + live partial text per speaker
        SessionWriter.swift         appends finished utterances to a Markdown file as they arrive
      Session/
        LiveSession.swift           start/stop; owns capture, VAD, two transcribers, store, writer
      Probes.swift                  --probe-* command-line checks (see tasks)
    CallAssistant/
      CallAssistantApp.swift        @main; runs a probe and exits if a --probe flag is present, else shows the window
      TranscriptWindow.swift        the live transcript UI
  Tests/CallCoreTests/
    TranscriptStoreTests.swift
    SessionWriterTests.swift
  Resources/
    Info.plist                      bundle id com.jaceg.callassistant, usage strings, LSMinimumSystemVersion 26.0
    CallAssistant.entitlements      audio-input (hardened runtime)
scripts/
  build_mac_app.sh                  swift build → mac/dist/CallAssistant.app → codesign
THIRD_PARTY_NOTICES.md              OpenOats MIT license text
README.md                           what it is, build, first run, permissions
```

`mac/dist/` and `mac/.build/` are gitignored. Sessions are saved to `~/Library/Application Support/CallAssistant/Sessions/`, outside `~/Documents`, so no folder-access prompt appears.

## Tasks

Each task ends with a commit (auto-commit is on; push only when Jace asks).

### Task 1: Package skeleton, build script, signed app that opens a window
- **Intent:** prove the build, bundle and signing pipeline on Swift 6.4 / macOS 27 before any real code. A stable signature is what keeps the mic and system-audio permissions from resetting on every rebuild.
- **Files:**
  - `mac/Package.swift`
  - `mac/Sources/CallCore/Logging.swift`
  - `mac/Sources/CallAssistant/CallAssistantApp.swift` (a window with "Call Assistant" text)
  - `mac/Resources/Info.plist`
  - `mac/Resources/CallAssistant.entitlements`
  - `scripts/build_mac_app.sh`
  - `.gitignore` (add `mac/dist/`)
- **Interfaces:**
  - `Package.swift`:
    - tools 6.2, `platforms: [.macOS(.v26)]`
    - dependency `FluidAudio` pinned `exact: "0.13.5"`. OpenOats notes it breaks source compatibility in patch releases.
    - targets `CallCore` (depends on FluidAudio), `CallAssistant` (executable, depends on CallCore), `CallCoreTests`.
  - The build script:
    - **Identity:** reads `CODESIGN_IDENTITY`, or else picks the first `Apple Development` identity from `security find-identity -v -p codesigning`. Never hard-code a name.
    - **Signing:** `codesign --force --options runtime --entitlements … --sign "$ID"`.
    - **Output:** `mac/dist/CallAssistant.app` with `Contents/MacOS/CallAssistant`, `Contents/Info.plist`, and FluidAudio's resource bundles if `swift build` emits any. Check how OpenOats' script copies `*.bundle` (around line 100).
  - Info.plist keys:
    - `NSMicrophoneUsageDescription`
    - `NSAudioCaptureUsageDescription`
    - `CFBundleIdentifier com.jaceg.callassistant`
    - `CFBundleName Call Assistant`
    - `CFBundleExecutable CallAssistant`
- **Check:**
  - `scripts/build_mac_app.sh` exits 0.
  - `codesign -dv --verbose=2 mac/dist/CallAssistant.app` shows `Authority=Apple Development`, `Identifier=com.jaceg.callassistant` and `flags=0x10000(runtime)`.
  - `open mac/dist/CallAssistant.app` → `pgrep -x CallAssistant` finds it, and a screenshot shows the window.
- **Risks:**
  - FluidAudio 0.13.5 may not compile under Swift 6.4. Try it first with `swift build` in an empty target; if it fails, find the nearest version that builds, then adjust the copied code in Task 3.

### Task 2: Copy audio capture, prove both channels on macOS 27 ⛳ CHECKPOINT
- **Intent:** this is the riskiest layer. Process taps and microphone access both need Jace to click Allow, and nothing has been tested on macOS 27 yet.
- **Files:**
  - `mac/Sources/CallCore/ThirdParty/OpenOats/SystemAudioCapture.swift`
  - `mac/Sources/CallCore/ThirdParty/OpenOats/MicCapture.swift`
  - `mac/Sources/CallCore/Probes.swift`
  - `THIRD_PARTY_NOTICES.md`
- **Changes to the copies:**
  - Remove the `DiagnosticsSupport.record` calls; keep the `Log` lines.
  - Rename the dispatch queue label `com.openoats.*` → `com.jaceg.callassistant.*`.
  - Make the types `public` where `LiveSession` needs them.
- **Interfaces:**
  - `SystemAudioCapture().bufferStream(outputDeviceID: nil) async throws -> CaptureStreams` (`.systemAudio: AsyncStream<AVAudioPCMBuffer>`), plus `stop() async`.
  - `MicCapture().bufferStream(deviceID: nil, echoCancellation: Bool) -> AsyncStream<AVAudioPCMBuffer>`, plus `stop()`.
  - `Probes.audio(seconds: Int) async -> Int32`: prints once per second `mic frames=… peak=… | system frames=… peak=…` and returns 0 only if both channels got frames with a peak above 0.
- **Check:**
  - Run `open mac/dist/CallAssistant.app --stdout /tmp/ca-probe.log --stderr /tmp/ca-probe.log --args --probe-audio 15`.
    - It must go through `open`, so macOS treats Call Assistant as the app asking for permission, not the shell.
  - While it runs, play audio with `afplay /System/Library/Sounds/Submarine.aiff` (repeat it) and speak into the mic.
  - Expect nonzero frames and a peak for both channels in `/tmp/ca-probe.log`.
- **Checkpoint:** Jace clicks Allow on the microphone and the "System Audio Recording Only" prompts. Record exactly what the log showed in the commit message.
- **Risks:**
  - If the system channel shows 0 frames, check `System Settings → Privacy & Security → Screen & System Audio Recording`.
  - Use `tackle:debugging-systematically`.
  - Do not claim it works until the log shows frames.

### Task 3: Copy streaming transcription, prove Parakeet on a known clip
- **Intent:** get on-device speech-to-text working on a deterministic input before wiring it to live audio.
- **Files:**
  - `ThirdParty/OpenOats/StreamingAudioConverter.swift`, `StreamingTranscriber.swift`, `TranscriptionBackend.swift` and `ParakeetBackend.swift`
  - `mac/Sources/CallCore/ModelStore.swift`
  - `Probes.swift`
- **Trimming `StreamingTranscriber`:**
  - Remove the cloud segment queue, `CloudSegmentStatus`, the diagnostics and the `skipPartials` path.
  - Replace OpenOats' `Speaker` with ours.
  - Drop the `sessionID` and `transcriptionModel` init parameters.
  - `flushInterval` = `5 * 16_000` for Parakeet (OpenOats' value).
- **`ModelStore.parakeetDirectory(for:)`:** read `OpenOatsLocalModelStore.parakeetDirectory` first. FluidAudio nests its own folder, and OpenOats wraps that on purpose. Keep the same layout under `CallAssistant/Models/Transcription/`.
- **Interfaces:**
  - `protocol TranscriptionBackend: Sendable` (unchanged from OpenOats).
  - `ParakeetBackend(version: .v2)`.
  - `StreamingTranscriber(backend:locale:vadManager:speaker:flushInterval:onPartial:onFinal:)`, with `run(stream:) async`.
  - `FinalSegment { text, startTime, endTime }`, times in seconds from stream start.
  - `Probes.transcribe(file: URL) async -> Int32`: reads the file into 16 kHz buffers, feeds one `StreamingTranscriber`, and prints each final segment.
- **Check:**
  - Make a test clip: `say -o /tmp/ca-test.aiff "The quarterly numbers look strong and the launch is on Friday"`.
  - Run `…/CallAssistant --probe-transcribe /tmp/ca-test.aiff`. Running the binary directly is fine here: no permission is needed.
  - Expect a final segment containing "quarterly", "launch" and "Friday".
  - The first run downloads Parakeet v2 (about 600 MB) and the Silero VAD model. Note the download time.
- **Risks:**
  - A clip shorter than 1 s of speech yields nothing (the `minimumSpeechSamples` guard).
  - VAD needs some silence after the speech to emit `speechEnd`, or the end-of-stream flush handles it. Make sure the probe finishes the stream.

### Task 4: Transcript model and session file (test first)
- **Intent:** the pure-logic core the UI, Phase 2's answer engine and Phase 5's server will all read.
- **Files:**
  - `Transcript/Speaker.swift`, `Utterance.swift`, `TranscriptStore.swift` and `SessionWriter.swift`
  - `Tests/CallCoreTests/TranscriptStoreTests.swift` and `SessionWriterTests.swift`
- **Interfaces:**
  ```swift
  public enum Speaker: String, Codable, Sendable, CaseIterable { case me, them }
  public struct Utterance: Identifiable, Codable, Sendable, Equatable {
      public let id: UUID; public let speaker: Speaker; public let text: String
      public let start: Date; public let end: Date
  }
  @MainActor @Observable public final class TranscriptStore {
      public private(set) var utterances: [Utterance]
      public private(set) var partial: [Speaker: String]
      public func setPartial(_ text: String, for: Speaker)   // "" clears
      public func append(_ u: Utterance)                     // keeps utterances sorted by start; clears that speaker's partial
  }
  public final class SessionWriter: Sendable {
      public init(directory: URL, startedAt: Date) throws    // creates "<yyyy-MM-dd HHmm> call.md" with a header
      public let fileURL: URL
      public func append(_ u: Utterance) throws              // "**[HH:mm:ss] Me:** text" line, flushed to disk each time
  }
  ```
- **Check:** `cd mac && swift test` passes. The tests cover:
  - out-of-order appends get sorted
  - a partial clears on append
  - the writer creates the file, and every append is on disk before it returns
  - two sessions in the same minute get distinct file names
- **Risks:** `@Observable` together with `@MainActor` in tests: mark the tests `@MainActor`.

### Task 5: LiveSession: both channels into the transcript ⛳ CHECKPOINT
- **Intent:** connect capture, VAD, transcription, the store and the writer, with no UI yet, and prove it with a probe.
- **Files:** `Session/LiveSession.swift` and `Probes.swift`.
- **Interfaces:**
  ```swift
  @MainActor @Observable public final class LiveSession {
      public enum State: Equatable { case idle, preparing(String, progress: Double?), listening, stopping, failed(String) }
      public private(set) var state: State
      public let store: TranscriptStore
      public private(set) var sessionFile: URL?
      public var echoCancellation: Bool                       // mic voice processing; default false (headphones)
      public init(sessionsDirectory: URL = ModelStore.sessionsDirectory)
      public func start() async                               // prepare backends (reports download progress), then capture
      public func stop() async                                // finish streams, wait for in-flight segments, close file
  }
  ```
- **How it fits together:**
  - **Backends:** one `ParakeetBackend` per channel, as OpenOats does at `TranscriptionEngine.swift:445-466`, and one shared `VadManager`.
  - **Transcribers:** each channel runs its `StreamingTranscriber` in a `Task.detached`.
  - **Callbacks:** each one hops to the `@MainActor` to update the store and writer.
  - **Times:** convert segment times to `Date` using the session start.
- **Check:**
  - Run `open mac/dist/CallAssistant.app --stdout /tmp/ca-live.log --args --probe-live 30`.
  - While it runs, `afplay /tmp/ca-test.aiff` twice and say a sentence.
  - The log shows at least one `Them:` line with the clip's words and one `Me:` line with what was said.
  - The session `.md` file exists with the same lines.
- **Checkpoint:** Jace looks at the log and the file.
- **Risks:**
  - **Echo:** on speakers the mic also hears "Them", so `Me:` duplicates appear. Use headphones or `echoCancellation = true`. OpenOats' `AcousticEchoFilter` (text-similarity dedupe) is out of scope; note how often duplicates show up for Phase 2.
  - Running two Parakeet models at once means two copies of the weights in memory. Check the memory use in Activity Monitor.

### Task 6: Transcript window ⛳ CHECKPOINT (real call)
- **Intent:** the UI for Phase 1. Run `ui-consistency:finding-patterns` first; this is the project's first page, so expect platform conventions (HIG) to settle most choices, and say so. Then build the window, then `ui-consistency:verifying` by a separate agent.
- **Files:** `mac/Sources/CallAssistant/TranscriptWindow.swift` and `CallAssistantApp.swift`.
- **What it shows:**
  - A Start/Stop button and a status line: "Downloading speech model 42%", "Listening", or the error text.
  - An echo-cancellation toggle labelled for speaker use. It's disabled while listening.
  - The utterance list: time, speaker ("Me" / "Them"), text. It scrolls to the newest line unless the user has scrolled up.
  - Each speaker's current partial line, in a secondary style.
  - "Open Sessions Folder" (Finder) and "Copy Transcript".
- **Check:**
  - Build and launch, press Start, `afplay /tmp/ca-test.aiff`, and confirm by screenshot that a Them line appears.
  - The `ui-consistency:verifying` report has no open findings.
- **Checkpoint:** Jace runs it on a real call, with headphones and then without, and reports what he saw. Record his report as he gives it.

### Task 7: Docs
- **Files:** `README.md`, `THIRD_PARTY_NOTICES.md` (check that it's complete), and `private/HANDOFF.md` (status, what Phase 1 measured).
- **Check:** the README build steps work from a clean clone of the repo (`git clone` into the scratchpad → run the script).

## Checkpoints
1. **After Task 2:** permissions plus both channels on macOS 27. If the process tap fails, the whole plan changes. ScreenCaptureKit audio is the fallback; Muesli uses it.
2. **After Task 5:** live transcription from both channels.
3. **After Task 6:** Jace on a real call.
