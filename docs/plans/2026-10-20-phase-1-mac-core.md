# Phase 1: Mac Core Plan

**Goal:** A signed macOS app that captures the call's audio (my mic and the system audio, as separate channels), transcribes both live on the Mac, shows a live "Me / Them" transcript in a window, and saves it to disk.
**Approach:**
- **Code:** a Swift package with a library (`CallCore`) and a thin SwiftUI app target. Audio capture is copied from OpenOats (MIT). Transcription uses Apple's built-in `SpeechAnalyzer` (macOS 26+). The transcript model, the session file writer and the session orchestration are new.
- **Build:** a script wraps the binary into a `.app` signed with the local Apple Development identity, so macOS permissions persist across rebuilds.
- **Testing:** each risky layer gets a command-line probe built into the app, so it can be checked without the UI.

**Stack:** Swift 6.4 (tools 6.2), SwiftUI, macOS 26+, Core Audio process taps, AVAudioEngine, Apple Speech (`SpeechAnalyzer` + `SpeechTranscriber`), Swift Testing.
**Spec:** `private/HANDOFF.md` (gitignored: decisions, requirements) and `cluely-alternative-fact-check.md` (research).

## Out of scope (later phases), but don't block them
Phase order (Jace, 2026-10-20): 1 Mac core → 2 Claude answers + playbooks → 3 phone server + iPhone app → 4 screen capture + call recording (Mac only) → 5 codebase index → 6 headless → 7 Tailscale/AWS. The iPhone app doesn't capture its own screen or record calls.
- Claude answers and playbooks (Phase 2): `CallCore` will hold the answer engine, so keep the transcript store observable and the session API small.
- The phone server and iPhone app (Phase 3), and headless mode (Phase 6): all session logic lives in `CallCore`, not in views, so a server and a windowless mode can drive it.
- Screen capture and call recording on the Mac (Phase 4).
- The codebase index (Phase 5). Remote access (Phase 7).
- Other speech engines: Parakeet (FluidAudio), WhisperKit or a cloud API can be added later behind the same `LiveTranscriber` protocol, if Apple's accuracy disappoints on real calls.
- Echo filtering by text similarity: see Risks in Task 5.

## Changes since the plan was written
- **2026-10-20, Jace:** use Apple's built-in transcriber first, not Parakeet. Apple's `SpeechAnalyzer` (seen in the macOS 27 SDK, available from macOS 26) runs on the Mac, macOS manages its model, and it gives live partial and final results itself. So Task 3 drops FluidAudio, Parakeet and OpenOats' VAD transcriber, and Task 1's FluidAudio dependency comes out of `Package.swift`.

## File map

```
mac/
  Package.swift                     products: library CallCore, executable CallAssistant
  Sources/
    CallCore/
      ThirdParty/OpenOats/          copied from reference/OpenOats (commit ea405d8), each with a header naming the source and changes
        SystemAudioCapture.swift    process-tap system audio → AsyncStream<AVAudioPCMBuffer>
        MicCapture.swift            AVAudioEngine mic → AsyncStream<AVAudioPCMBuffer> (+ AudioLevel/Sync* helpers it defines)
      Transcription/
        LiveTranscriber.swift       protocol: prepare (model download), run (audio stream → partial/final text)
        AppleSpeechTranscriber.swift  SpeechAnalyzer + SpeechTranscriber implementation
        AudioBufferConverter.swift  capture format → the analyzer's format (AVAudioConverter)
      Logging.swift                 `Log` os.Logger categories the copied files use (systemAudio, mic, …)
      Paths.swift                   ~/Library/Application Support/CallAssistant/Sessions
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
    - targets `CallCore`, `CallAssistant` (executable, depends on CallCore), `CallCoreTests`. FluidAudio was pinned here at first, then removed in Task 3.
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
- **Result:** done (`ee45fad`). FluidAudio 0.13.5 built on Swift 6.4, but it was removed in Task 3 when Apple's transcriber was chosen.

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

### Task 3: Apple speech-to-text, proved on a known clip
- **Intent:** get on-device speech-to-text working on a deterministic input before wiring it to live audio.
- **Files:**
  - `mac/Sources/CallCore/Transcription/LiveTranscriber.swift`, `AppleSpeechTranscriber.swift` and `AudioBufferConverter.swift`
  - `mac/Tests/CallCoreTests/AudioBufferConverterTests.swift`
  - `Probes.swift`
  - `mac/Package.swift` (remove FluidAudio)
- **Interfaces:**
  ```swift
  public struct TranscribedSegment: Sendable, Equatable { public let text: String; public let start: TimeInterval; public let end: TimeInterval }
  public protocol LiveTranscriber: Sendable {
      /// Makes sure the speech model is installed (downloading it if needed) and ready.
      func prepare(onStatus: @escaping @Sendable (String) -> Void, onProgress: @escaping @Sendable (Double) -> Void) async throws
      /// Transcribes `audio` until it ends. Partial text replaces the previous partial; "" clears it.
      func run(_ audio: AsyncStream<AVAudioPCMBuffer>,
               onPartial: @escaping @Sendable (String) -> Void,
               onFinal: @escaping @Sendable (TranscribedSegment) -> Void) async throws
  }
  ```
  - `AppleSpeechTranscriber(locale: Locale = .current)`.
    - **prepare:**
      - `SpeechTranscriber.supportedLocale(equivalentTo:)`, or else throw "language not supported".
      - Use `SpeechTranscriber(locale:preset: .progressiveTranscription)`, which gives volatile results.
      - Check `AssetInventory.status(forModules:)`. If it isn't `.installed`, call `assetInstallationRequest(supporting:)?.downloadAndInstall()` and report `.progress.fractionCompleted`.
    - **run:**
      - Get the format from `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`, then `prepareToAnalyze(in:)`.
      - Feed `AsyncStream<AnalyzerInput>` from converted buffers into `start(inputSequence:)`.
      - Read `transcriber.results`: `isFinal` goes to `onFinal` (with `range` converted to seconds), anything else to `onPartial`.
      - When the audio stream ends, call `finalizeAndFinishThroughEndOfInput()`.
  - `AudioBufferConverter(to: AVAudioFormat)` with `convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer?`. It rebuilds its `AVAudioConverter` when the input format changes.
  - `Probes.transcribe(file: URL) async -> Int32`: reads the file in 0.1 s buffers as a stream, prints each partial (marked `~`) and each final, and returns 0 if any final text came back.
- **Check:**
  - `swift test`: the converter test passes. It turns 1 s of 48 kHz stereo float into the target format (for example 16 kHz mono), and the frame count is within 1% of the rate ratio.
  - Make a clip: `say -o /tmp/ca-test.aiff "The quarterly numbers look strong and the launch is on Friday"`.
  - Run `…/CallAssistant --probe-transcribe /tmp/ca-test.aiff`. Expect a final segment containing "quarterly", "launch" and "Friday".
  - Record whether the English model had to download, and how long it took.
- **Risks:**
  - The model may need a download on the first run; that's what the status and progress callbacks are for.
  - Apple's `isFinal` timing on a short clip: the stream ends and the finalize call should flush it.
  - Two analyzers at once, one per channel, is untested. Check it in Task 5.

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
  - **Transcribers:** one `AppleSpeechTranscriber` per channel, each running in its own `Task`.
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
  - Two `SpeechAnalyzer`s at once: check that both produce results and note the CPU use.

- **Result (checkpoint 2, 2026-10-20):**
  - **Without echo cancellation:** Jace's answers came through as Me lines, but on speakers every Them line also appeared as a Me duplicate.
  - **With echo cancellation on, the first try failed.** Voice processing makes the mic deliver 9 identical channels, and AVAudioConverter turned those into silence. Fixed in `adfb743` by taking channel 0.
  - **With the fix:**
    - Jace's answers came through.
    - The first played question leaked into Me as a fragment; the second was fully removed.
    - The call audio was captured at about a third of its usual level (peak ~0.28 vs 0.69-0.81), so voice processing turns the other side down even at minimum ducking.
  - **Recognition errors seen:** sound-alikes ("cash" for cache, "rights" for writes, "weights" for waits).

### Task 5b: Echo duplicate filter (test first)
- **Intent:** on speakers, the mic hears the other side, so Me lines repeat Them lines. Drop or trim them using the Them transcript. There's no model and no volume cost. Jace chose this together with Task 5c (2026-10-20).
- **Files:** `mac/Sources/CallCore/Transcript/EchoFilter.swift`, `mac/Tests/CallCoreTests/EchoFilterTests.swift` and `Session/LiveSession.swift`.
- **Rule:**
  - Compare a Me line with Them lines that overlap it in time, give or take 10 s.
  - Remove every run of 3 or more consecutive Me words that matches the Them words in order. Words match when equal, or when they're long enough and differ by an edit or two ("cashing"/"caching").
  - If fewer than 2 words are left, drop the line. Otherwise keep what's left.
- **LiveSession:**
  - Holds each Me line for 3 s after it ends before recording it, because the Them line it echoes may finalize later.
  - Then it filters and records the line.
  - `stop()` flushes the held lines.
- **Check:**
  - `swift test` passes these cases from the checkpoint 2 runs:
    - an exact duplicate is dropped
    - "two"/"2" variants are dropped
    - Jace's own answer is kept
    - "Sure, the cash. Can you walk me through…" is trimmed to "Sure, the cash."
    - a fragment ("…how the cast...") is dropped
    - an identical line 30 s apart is kept
  - The live probe with echo cancellation off and two played questions shows no duplicate Me lines.
- **Risks:** if Jace repeats the other person's words within 10 s, those words get trimmed.

### Task 5c: WebRTC echo canceller (reference: the system audio)
- **Intent:** remove the speaker echo from the mic signal itself, using the system tap as the known far-end audio, without turning the call down the way Apple's voice processing does.
- **First step, research:** how to build WebRTC's AEC3 for macOS arm64 inside this package. Candidates are the `webrtc-audio-processing` extraction (meson; BSD), a prebuilt xcframework, or an existing Swift wrapper. Check the license and whether it needs Homebrew tools (ask Jace before installing any).
- **Then:**
  - Pass the system audio to the canceller as the far-end ("render") stream and the mic as the near-end ("capture") stream, both 10 ms frames at the same rate.
  - Transcribe the canceller's output for Me.
- **Check:**
  - With echo cancellation off and the duplicate filter disabled, the live probe's played questions don't appear as Me lines, while Jace's spoken answers do.
  - The system-audio level is unchanged compared with no processing.
- **Checkpoint:** the research result (approach, effort, license) goes to Jace before integration.

- **Result (2026-10-20):**
  - **Build:** WebRTC v2.1 builds for macOS 26 with meson + ninja and links through `CEchoCanceller`.
  - **Tests:** a pure echo comes out 24.2 dB quieter; with nothing playing, the mic level changes by -0.05 dB.
  - **Live run** (speakers, canceller on, duplicate filter off, Apple voice processing off): no echoed questions in Me, and both of Jace's spoken answers came through.
  - **Volume:** the call level wasn't measured in this run. The canceller only processes the mic copy and doesn't use voice processing, so it can't duck the call.
  - **Defaults now:** canceller on, filter on as a backup, Apple voice processing off. Both are harmless with headphones, so Task 6 needs no echo toggle.

### Task 6: Transcript window ⛳ CHECKPOINT (real call)
- **Intent:** the UI for Phase 1. Run `ui-consistency:finding-patterns` first; this is the project's first page, so expect platform conventions (HIG) to settle most choices, and say so. Then build the window, then `ui-consistency:verifying` by a separate agent.
- **Files:** `mac/Sources/CallAssistant/TranscriptWindow.swift` and `CallAssistantApp.swift`.
- **What it shows:**
  - A Start/Stop button and a status line: "Downloading speech model 42%", "Listening", or the error text.
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
