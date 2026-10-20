# Phase 2: Claude Answers Plan

**Goal:** During a call, Claude answers what the other person asks, live in the window, guided by pre-call instructions Jace picks (a playbook) plus notes for this call.
**Approach:**
- **Code:** the answer engine lives in `CallCore` behind one `AnswerProvider` protocol, with Claude as the only provider for now. Swift has no official Anthropic SDK, so the provider calls the Messages API over HTTP with `URLSession` and reads the streamed (SSE) reply as it arrives.
- **Triggers (all three, Jace):**
  - **Automatic:** a question from Them, detected by its "?", once they pause.
  - **Answer Now:** a button, or the global hotkey ⌃⌥A.
  - **Typed:** a question typed into the window.
- **Prompt:** a base prompt, then the chosen playbook, then the call notes, then the transcript so far, then the question. The stable parts are cached so each answer is cheaper and starts sooner.
- **Testing:** pure logic is tested first with Swift Testing. Probes cover the live API and the Keychain, and Jace checks the window.

**Stack:** Swift 6.4 (tools 6.2), SwiftUI, macOS 26+, `URLSession` streaming, Security framework (Keychain), Carbon `RegisterEventHotKey` (the global hotkey), the Claude Messages API (`claude-sonnet-5-5`), and Swift Testing.
**Spec:** Jace's requirements 4 ("Can answer questions live") and 5 ("Can be pre-prompted with instructions to use to guide its assistance during a call") in `private/HANDOFF.md`. Decisions are below.

## Decisions (Jace, 2026-10-20)
- **Model:** "let's use sonnet 5.5" → `claude-sonnet-5-5`.
- **Triggers:** "let's use all 3 triggers": automatic, Answer Now (button + hotkey), and typed.
- **Pre-call instructions:** "Both". Reusable instruction files per call type (playbooks), picked from a menu before Start, plus a notes box for this one call.
- **API key:** Jace made a new key and saved it himself in the login Keychain:
  - service `com.jaceg.callassistant`, account `anthropic-api-key`, label "Call Assistant - Claude API key"
  - Tested 2026-10-20: `GET /v1/models` → HTTP 200, and `claude-sonnet-5-5` was listed.
  - The key starts with `sk-ant-` but not `sk-ant-api`, so never check a key's format by its prefix.
- **New views:** "Answers in a new file". `AnswersPane.swift` holds the answers list, an answer's view and the Ask field. The playbook picker and the notes box stay inside `TranscriptWindow.swift`.
- **Hotkey:** ⌃⌥A.
- **License:** Jace doesn't mind. Nothing changes (a GPL-3.0 LICENSE is added only if GPL code is ever copied in).

## Claude API choices (from the `claude-api` skill, read 2026-10-20)
- **Request:** `POST https://api.anthropic.com/v1/messages` with these headers:
  - `x-api-key`
  - `anthropic-version: 2023-06-01`
  - `content-type: application/json`
  - `anthropic-beta: server-side-fallback-2026-07-01`

  The body has `"stream": true`, `"model": "claude-sonnet-5-5"` and `"max_tokens": 16000`. Thinking counts toward `max_tokens`; the skill says not to set it low.
- **Thinking and speed:** Sonnet 5.5 rejects `thinking: {"type": "disabled"}` with a 400.
  - First choice: adaptive thinking (the default) with `output_config: {"effort": "low"}`. At `low` it skips thinking on most simple requests.
  - Alternative: `thinking: {"type": "between_tools"}`, also at `low`.
  - Task 1 measures the time to the first answer text for both, and the faster one is kept.
- **Refusals:** a decline is an HTTP 200 with `stop_reason: "refusal"`; read `stop_reason` before trusting the text. `"fallbacks": "default"` (the beta header above, Claude API only) retries "cyber" and "frontier_llm" declines on Claude Sonnet 5. The skill says to enable it by default and tell the user; this plan does both.
- **Reading the stream:** blocks are read by their `type`. A reply can start with an empty `thinking` block, which isn't shown. Unknown block types (for example `fallback`) and `ping` events are ignored.
- **Preserved thinking doesn't apply:** each answer is one fresh single-turn request, and nothing is replayed.
- **Caching:** explicit `cache_control` breakpoints, one at the end of the system prompt and one at the end of the last frozen transcript chunk (Task 3).
  - The minimum cacheable prefix on Sonnet 5.5 is 512 tokens. Early in a call nothing caches, and that's expected.
  - Reads only happen where an earlier request wrote a breakpoint, and a breakpoint looks back at most 20 blocks.
- **Price** (Sonnet 5.5, per the skill's table): $2 per million input tokens and $10 per million output tokens; cache reads $0.20.
  - An answer late in an hour-long call (~15k tokens in, ~300 out) costs about 3–4 cents without caching. That's an estimate.
  - Every live probe spends a little real money. Task 1's probes total under $0.10 (estimate).
- **Privacy:** the transcript, playbook and notes are sent to Anthropic's API for each answer. That's the cloud default Jace chose; the README says so.

## Out of scope (later phases), but don't block them
- **Phase 3 (phone server + iPhone app):** answers must be observable from `CallCore` (`AnswerEngine`), and its events should map onto `answer.delta` / `answer.done` / `ask`. No views hold answer state.
- **Other providers** (Ollama, OpenAI-compatible) can be added later behind `AnswerProvider`.
- **Codebase knowledge** (Phase 5).
- **Open Phase 1 UI item:** the status bar stays at "Downloading… 100%" during the mic prompt on a first run. It's not touched here.

## File map

```
mac/Sources/CallCore/
  Answers/
    AnswerProvider.swift      protocol + AnswerEvent; AnswerPrompt (what one request carries)
    ClaudeProvider.swift      Messages API over URLSession, streaming; builds the JSON body
    ServerSentEvents.swift    pure: SSE data lines → AnswerEvent (tested)
    APIKeyStore.swift         reads the key from the login Keychain
    Playbooks.swift           Playbook + PlaybookLibrary (folder of .md files, a starter General.md)
    PromptBuilder.swift       pure: base prompt + playbook + notes + transcript chunks + question → AnswerPrompt (tested)
    QuestionDetector.swift    pure: is this Them line a question worth answering? (tested)
    AnswerEngine.swift        @Observable: triggers, one answer at a time, the answers list, saving them
  Session/LiveSession.swift   owns an AnswerEngine; passes it each committed line; Start resets it
  Transcript/SessionWriter.swift   writes answers into the call file, in time order on rewrite
  Paths.swift                 + playbooksDirectory
  Probes.swift                + --probe-answer, --probe-detect; --probe-live gets --auto-answer
mac/Sources/CallAssistant/
  AnswersPane.swift           new (Jace): answers list, one answer's view, the Ask field
  TranscriptWindow.swift      split view, toolbar additions, playbook picker, notes popover
  GlobalHotKey.swift          ⌃⌥A through Carbon RegisterEventHotKey
  CallAssistantApp.swift      creates the engine/provider; registers the hotkey
mac/Tests/CallCoreTests/
  ServerSentEventsTests.swift, ClaudeRequestTests.swift, PromptBuilderTests.swift,
  QuestionDetectorTests.swift, AnswerEngineTests.swift, PlaybooksTests.swift, SessionWriterTests.swift (+answers)
README.md                     API key setup, playbooks folder, cost and privacy notes
```

- **Playbooks:** saved in `~/Library/Application Support/CallAssistant/Playbooks/`, one `.md` file per playbook, named after the file. They're outside the repo, so personal ones are never committed.
- **No new entitlement is needed.** The app isn't sandboxed, so outgoing network calls work under the hardened runtime.

## Tasks

Each task ends with a commit (auto-commit is on; push only when Jace asks).

### Task 1: Claude client, Keychain key, latency probe ⛳ CHECKPOINT
- **Intent:** the riskiest layer goes first. That means calling the API from Swift without an SDK, parsing the stream, and the signed app reading a Keychain item that `/usr/bin/security` created. It also measures how fast Sonnet 5.5 starts answering.
- **Files:**
  - Code: `Answers/AnswerProvider.swift`, `ClaudeProvider.swift`, `ServerSentEvents.swift` and `APIKeyStore.swift`, plus `Probes.swift`
  - Tests: `Tests/CallCoreTests/ServerSentEventsTests.swift` and `ClaudeRequestTests.swift`
- **Interfaces:**
  ```swift
  public struct AnswerPrompt: Sendable, Equatable {
      public var system: [PromptBlock]      // text blocks; `cacheBreakpoint` marks the last one to cache
      public var transcript: [PromptBlock]  // frozen chunks first, then the live tail
      public var question: String
  }
  public struct PromptBlock: Sendable, Equatable { public var text: String; public var cacheBreakpoint: Bool }
  public enum AnswerEvent: Sendable, Equatable {
      case text(String)                                   // a piece of the answer
      case finished(stopReason: String, usage: Usage)     // usage: input, output, cacheRead, cacheWrite tokens
      case declined(category: String?)                    // stop_reason "refusal"
  }
  public protocol AnswerProvider: Sendable {
      func answer(_ prompt: AnswerPrompt) -> AsyncThrowingStream<AnswerEvent, Error>   // cancelling the consumer cancels the request
  }
  public struct ClaudeProvider: AnswerProvider {
      public init(apiKey: @escaping @Sendable () throws -> String, model: String = "claude-sonnet-5-5",
                  effort: String = "low", thinkingOff: Bool = false, session: URLSession = .shared)
      static func requestBody(for: AnswerPrompt, model: String, effort: String, thinkingOff: Bool) -> Data   // tested
  }
  public enum APIKeyStore {
      public static func read(service: String = "com.jaceg.callassistant", account: String = "anthropic-api-key") throws -> String
  }
  public enum AnswerError: LocalizedError { case noKey, keyRejected, rateLimited(retryAfter: Int?), overloaded, http(Int, String), network(String) }
  ```
  - **SSE parsing:** each `data:` line holds one JSON event, so parse every `data:` line on its own and switch on its `"type"`. Skip `event:` lines and blank lines; `URLSession.bytes(for:).lines` drops blank lines anyway.
  - **Events:**
    - `content_block_delta` with `delta.type == "text_delta"` → `.text`
    - `message_delta` carries `stop_reason` and the output tokens
    - `message_start` carries the input and cache tokens
    - `error` → throw
  - **Errors (by HTTP status):** 401 → `.keyRejected`, 429 → `.rateLimited` (from `retry-after`), 529 → `.overloaded`.
  - **Messages the user sees** (they show on the failed answer):
    - "No Claude API key in the Keychain. See the README to add one."
    - "Claude rejected the API key."
    - "Claude is busy. Try again in a moment."
  - **Probe:** `--probe-answer "<question>" [--effort low|medium] [--thinking-off] [--runs N] [--transcript <call.md>]`.
    - Prints the time to the first text and the total time, the tokens (input, output, cache read, cache write) and the answer.
    - Returns 0 if any text came back.
- **Check:**
  - `swift test` passes. The tests feed recorded streams through the parser:
    - a plain answer
    - an answer that starts with an empty thinking block
    - a `refusal`
    - an `error` event mid-stream
    - `ping` and unknown block types (ignored)
  - The body tests check the JSON: model, `stream: true`, `output_config.effort`, `fallbacks: "default"`, the `cache_control` placement, and that `thinking: {"type": "between_tools"}` appears only when `thinkingOff` is set.
  - Run `open mac/dist/CallAssistant.app --stdout /tmp/ca-answer.log --stderr /tmp/ca-answer.log --args --probe-answer "In one sentence, what is a mutex?" --runs 3`. Then the same with `--thinking-off`.
  - Expect 3 answers each, a first-text time per run, and no key in the log.
- **Checkpoint:**
  - Jace clicks **Always Allow** when macOS asks whether CallAssistant may use the "Call Assistant - Claude API key" item. Give him the instructions and wait for "ready" first.
  - Report the two medians and keep the faster setting as the default, unless the answers read worse.
  - Record the numbers here.
- **Risks:**
  - **The Keychain prompt** may come back after each rebuild. "Always Allow" is tied to the app's code signature, and the signature stays the same across rebuilds, so I expect it to hold, but that hasn't been tested. If it does come back, re-create the item with `-T` for the app path. That needs Jace, because only he types the key.
  - **Never log the key** or the request headers.
  - **A guess:** `URLSession.bytes` may buffer small chunks. If the first text shows up much later than the server sends it (compare with `curl -N`), switch to a `URLSessionDataDelegate`.

### Task 2: Playbooks, call notes, the prompt (test first)
- **Intent:** the text Claude receives. The playbook and the notes steer the answer, and the transcript gives it context. This is Jace's requirement 5.
- **Files:** `Answers/Playbooks.swift`, `PromptBuilder.swift`, `Paths.swift`, `Tests/CallCoreTests/PlaybooksTests.swift` and `PromptBuilderTests.swift`.
- **Interfaces:**
  ```swift
  public struct Playbook: Identifiable, Sendable, Equatable { public var id: String { name }; public let name: String; public let instructions: String }
  public struct PlaybookLibrary: Sendable {
      public init(directory: URL = Paths.playbooksDirectory)
      public func load() throws -> [Playbook]       // *.md sorted by name; creates the folder and General.md when there are none
  }
  public struct PromptBuilder: Sendable {
      public init(playbook: Playbook?, callNotes: String, chunkSize: Int = 10)
      public func prompt(lines: [Utterance], themSaying: String?, question: Question, now: Date) -> AnswerPrompt
  }
  public enum Question: Sendable, Equatable { case detected(String), answerNow, typed(String) }
  ```
- **The base prompt (system, block 1)** says that:
  - Claude is helping Jace live during a call.
  - "Me" is Jace and "Them" is the other side.
  - The transcript comes from speech recognition and has sound-alike slips ("home" for "phone", "cash" for "cache"), so Claude should read the meaning from context.
  - It should answer so Jace can say it out loud right away: the direct answer first, then at most 3 short "- " bullets, no headings, and only inline Markdown.
  - If it isn't sure, it should say so in a few words.
  - **Leave out** any instruction to write out its reasoning: the skill says that invites `reasoning_extraction` declines.
- **The rest of the system prompt:**
  - Block 2 is the playbook (`# Playbook: <name>` + its text), if one is picked.
  - Block 3 is the call notes, if any.
  - The last system block carries the cache breakpoint.
- **The transcript:**
  - Lines are `[HH:mm:ss] Them: text`, in the order they were recorded. The timestamps give the real order, so a late Me line doesn't change any frozen chunk.
  - Every `chunkSize` recorded lines become one frozen block, and the last frozen block carries the second breakpoint.
  - The newest lines and any words Them is still saying ("(still speaking) …") go in the live tail.
- **The question:**
  - `detected(q)` → "They just asked: "q". Help me answer."
  - `answerNow` → "Help me respond to what they just said."
  - `typed(q)` → q as written.
- **Starter `General.md`:** "Keep answers short and concrete. Lead with the answer. If they ask about my experience, answer in the first person, as me."
- **Check:** `swift test` covers:
  - block order and breakpoints
  - frozen chunks staying byte-identical when a line arrives out of time order
  - no playbook block when none is picked
  - the empty-notes case
  - `General.md` being created only in an empty folder
  - files sorted by name
- **Risks:** a playbook file that isn't UTF-8 is skipped and logged, never a crash.

### Task 3: Prompt caching, measured
- **Intent:** a late-call answer re-sends thousands of transcript tokens. Caching makes it cheaper and should shorten the time to the first text.
- **Files:** `ClaudeProvider.swift` (cache_control on blocks whose `cacheBreakpoint` is set) and `Probes.swift`.
- **Check:**
  - Run `--probe-answer "What did they ask about caching?" --transcript <a long saved call or a generated 2,000-word one> --runs 2`.
  - The second run shows `cache read > 0`.
  - Record both runs' first-text times and the cache read/write tokens.
- **Risks:** the minimum is 512 tokens, so a short transcript shows `cache write 0`. That's expected. Test with a long one.

### Task 4: Question detector (test first)
- **Intent:** the automatic trigger. Measured 2026-10-20: Apple's transcriber puts "?" on questions. Every played test question in the 9 test files had one, and 4 of 12 Them lines in the real call did.
- **Files:** `Answers/QuestionDetector.swift`, `Tests/CallCoreTests/QuestionDetectorTests.swift` and `Probes.swift`.
- **Interfaces:**
  ```swift
  public struct QuestionDetector: Sendable {
      public init()
      /// The question to answer if this Them line asks one, else nil.
      public func question(in line: Utterance) -> String?
  }
  ```
- **Rule:**
  - Only Them lines count.
  - A sentence ending in "?" with at least 4 words, or a line starting with a request phrase ("tell me about", "walk me through", "talk me through", "can you explain", "explain", "describe").
  - Tag questions are skipped: "right?", "you know?", "okay?", "yeah?", "make sense?", "does that make sense?", "sound good?" and the like.
  - It returns the question sentence(s) only.
- **Probe:** `--probe-detect <call.md>` replays a saved call through the detector and prints each line it would answer. It makes no API call.
- **Check:**
  - `swift test` covers: a real question, a tag question, a short "Really?", a request with no "?", Me lines ignored, and two questions in one line.
  - `--probe-detect` on Jace's real call (`2026-10-20 1004 call.md`) prints the lines it picks. Report how many, with the text left out of the report.

### Task 5: Answer engine + session wiring (test first, fake provider)
- **Intent:** the logic between the triggers and the window: one answer at a time, what interrupts what, and answers saved in the call file.
- **Files:** `Answers/AnswerEngine.swift`, `Session/LiveSession.swift`, `Transcript/SessionWriter.swift`, `Probes.swift`, `Tests/CallCoreTests/AnswerEngineTests.swift` and `SessionWriterTests.swift`.
- **Interfaces:**
  ```swift
  public struct Answer: Identifiable, Sendable, Equatable {
      public enum Trigger: String, Sendable { case auto, answerNow, typed }
      public enum State: Sendable, Equatable { case waiting, streaming, done, stopped, failed(String), declined }
      public let id: UUID; public let trigger: Trigger; public let question: String   // what was asked, as shown
      public let askedAt: Date; public var text: String; public var state: State
      public var firstTextAfter: TimeInterval?
  }
  @MainActor @Observable public final class AnswerEngine {
      public private(set) var answers: [Answer]
      public var autoAnswer: Bool
      public var playbook: Playbook?
      public var callNotes: String
      public var onFinished: ((Answer) -> Void)?           // LiveSession saves it
      public init(provider: AnswerProvider, detector: QuestionDetector = .init(), pause: Duration = .milliseconds(1500))
      public func lineRecorded(_ line: Utterance, transcript: TranscriptStore)   // auto trigger
      public func answerNow(transcript: TranscriptStore)
      public func ask(_ text: String, transcript: TranscriptStore)
      public func stop()                                    // stops the one streaming
      public func reset()                                   // new call: clears the list
  }
  ```
- **Rules:**
  - **Automatic answers:**
    - Only when `autoAnswer` is on.
    - Only for a Them line the detector picks.
    - It waits until Them has had no words in progress for `pause`, so a question spoken across two lines finishes first.
    - It never answers the same line twice.
  - **One answer streams at a time:**
    - **Answer Now or a typed question** stops the answer that's streaming (it's marked `stopped` and keeps its text) and starts at once.
    - **An automatic trigger while anything is streaming** waits. Only the newest waiting question is kept, and it runs when the current answer finishes.
  - **Saving:** each answer is written to the call file when it finishes, as a quote block:

    ```
    > **[HH:mm:ss] Claude** (auto): *question*
    >
    > text
    ```

    `rewrite` puts answers and lines together in time order. Answers given before Start (when no call file exists) aren't saved.
  - **LiveSession:**
    - It owns `answers: AnswerEngine`.
    - `commit` calls `answers.lineRecorded`.
    - `start()` calls `answers.reset()`.
    - `stop()` waits for a streaming answer up to 10 s, then stops it and saves it.
  - **The engine keeps its own list of lines** in the order `lineRecorded` receives them, and passes that list to `PromptBuilder`. That keeps the frozen chunks unchanged. The `TranscriptStore` argument is used only for Them's words in progress. `reset()` clears this list.
  - **`--probe-live N --auto-answer`** prints answers as they stream, alongside the lines.
- **Check:**
  - `swift test` with a fake provider (scripted events and delays). It covers:
    - an automatic answer fires after the pause, not before
    - Answer Now stops a streaming automatic answer
    - a waiting automatic question runs after the current answer, and only the newest is kept
    - typed questions work with no call running
    - `failed` and `declined` states
    - answers in the rewritten file in time order
  - A live probe: `--probe-live 40 --auto-answer` while `afplay` plays a `say` clip of "Can you walk me through how you would cache API responses in a mobile app?". The log shows an automatic answer. Record the time from the Them line to the first answer text.

### Task 6: The window — answers, Ask field, playbook, notes, hotkey ⛳ CHECKPOINT (Jace)
- **Intent:** everything Jace sees in Phase 2. It runs `ui-consistency`: the checklist below (from `finding-patterns`, 2026-10-20), then `implementing`, then `verifying` by an agent that didn't write the code.
- **Files:**
  - `mac/Sources/CallAssistant/AnswersPane.swift` (new, as Jace chose)
  - `TranscriptWindow.swift`, `GlobalHotKey.swift` (new) and `CallAssistantApp.swift`
- **The shape (agreed with this plan's yes):**
  ```
  Window "Call Assistant"                     existing Window scene, floats while pinned
    Toolbar                                   existing ToolbarItemGroup
      Start/Stop · Copy Transcript · Open Sessions Folder · Keep on Top     (unchanged, first)
      Playbook       Picker, menu style: "None" + one entry per playbook file
      Call Notes     Button → popover with a TextEditor for this call's notes
      Answer Now     Button, also ⌃⌥A anywhere; disabled when there's nothing heard yet
      Auto-Answer    Toggle, button style, on/off symbol like Keep on Top
    VSplitView
      Transcript                              existing, unchanged
      Answers pane (AnswersPane.swift)
        Answers list                          newest at the bottom, follows new text
          Answer ×n                           header (time · how it was asked · question), text, state
        Empty state                           when there are no answers
        Ask field                             TextField "Ask Claude…", Return sends
    Status bar                                existing, unchanged
  ```
- **The checklist:**
  ```
  transcript window + answers against "the transcript window" (the project's only page; it is the
  page being extended) — from mac/Sources/CallAssistant/TranscriptWindow.swift, 1 member of 1
  candidate in the CallAssistant app target + CallCore (CallAssistantApp.swift is the scene that
  mounts it, not a member), read 2026-10-20. A family of one: every line below is that page's own
  way, a starting point, not a counted convention. No theme and no DESIGN.md; the value scale is
  not derivable from its few literals, so values are SwiftUI's system styles and default spacing.

  - [ ] window holder — the existing Window("Call Assistant", id: "transcript") and its floating
        level; the body becomes a VSplitView, transcript above, answers pane below; the minimum
        420 × 300 kept — the agreed shape (plan's yes); the minimum is the reference's own literal
  - [ ] toolbar order — the four existing items keep their places; Playbook, Call Notes, Answer
        Now and Auto-Answer follow in that reading order — a position no member has: nowhere to
        read an order from, so the existing controls keep their places (conventions, rare)
  - [ ] toolbar items — each a Label("…", systemImage:) with a .help("…") sentence that starts
        with a verb, like the four existing ones; Auto-Answer is a Toggle with .toggleStyle(.button),
        "bolt.fill" while on and "bolt" while off, stored with @AppStorage behind a static key and
        default constant, like Keep on Top — the reference's own way (1 member)
  - [ ] Answer Now — disabled when the transcript has no line and nothing in progress, and while
        preparing or stopping, like Copy Transcript's disabled rule; its help names ⌃⌥A — the
        reference's own way
  - [ ] answers list — ScrollView + LazyVStack(alignment: .leading) with .padding(), newest at the
        bottom, following new text unless scrolled up, through the same ScrollPosition +
        onScrollGeometryChange mechanism and the same bottomTolerance constant, made shared rather
        than written twice — the reference's own way; one constant, not a copy
  - [ ] one answer — a view in AnswersPane.swift (Jace): header with the time as .caption
        .monospacedDigit() .secondary (the transcript line's time style), then "Auto" / "Asked" /
        "Typed" and the question in .caption .secondary; the text as .body, selectable, inline
        Markdown only; answers separated by Divider(); the block reads as one VoiceOver item
        (.accessibilityElement(children: .combine), like a transcript line) — the reference's own
        type roles; Divider as the plainest separator (decisions, what this does not decide)
  - [ ] answer states — waiting: "Thinking…" in .secondary italic (the in-progress line's style);
        stopped: the text kept, then "Stopped" in .secondary; failed: the message in .red (the status
        bar's failure style); declined: "Claude declined to answer this one." in .secondary — the
        reference's own styles; new copy for Jace to read
  - [ ] empty state — centred .secondary text: "Answers appear here. Press Answer Now, type a
        question, or turn on Auto-Answer." — the reference's empty-state way; new copy
  - [ ] Ask field — TextField("Ask Claude…") at the bottom of the answers pane with .padding();
        Return sends a non-empty question and clears the field; usable with no call running — a
        position no member has: the plainest way SwiftUI allows
  - [ ] Call Notes popover — a TextEditor in a .popover from the toolbar button, its size a named
        constant beside bottomTolerance; edits apply to the next answer — the plainest way; the
        constant follows the reference's named-constant way
  - [ ] what the user sees happen — Answer Now, ⌃⌥A and Return each add an answer at the bottom and
        scroll to it; a new one stops a streaming one; Start clears the answers like the
        transcript (they're kept in the call file); the status bar stays about the call only —
        as agreed (Task 5's rules)
  - [ ] not copied from the reference — nothing particular can be separated out, because nothing
        repeats in a family of one; the speaker column (Me/Them) isn't used for answers
  ```
  (Searches the counts came from: the reference's exact names `ToolbarItemGroup`, `Label(`, `.help(`, `.toggleStyle(.button)`, `@AppStorage`, `ScrollPosition`, `onScrollGeometryChange`, `bottomTolerance`, `.caption.monospacedDigit()`, `.accessibilityElement(children: .combine)`, `.foregroundStyle(.red)`. Each was run over `mac/Sources/CallAssistant/*.swift` and found in `TranscriptWindow.swift` only. No `DESIGN.md` at the repo root.)
- **Steps:**
  1. **Calibrate the check** before building. A separate agent with `ui-consistency:verifying` gets a scratch copy of `TranscriptWindow.swift` (kept outside the repo), with one role written differently, and this checklist. It's told only that the copy differs somewhere; whoever plants doesn't check. If it misses the planted difference, stop and report that the check is blind for it.
  2. **Build** `GlobalHotKey` (⌃⌥A → `answers.answerNow`; it doesn't bring the window forward), then `AnswersPane.swift`, then the `TranscriptWindow.swift` changes. Re-read the checklist before writing; don't work from memory.
  3. **Report it ready for its check.** A checker agent with `ui-consistency:verifying` (not the one that wrote it, and not the calibrated one) walks the checklist. Fix what it reports.
  4. **Status:** `done` here once the check passes, or `parked — <why>`.
- **Check:**
  - Build and launch.
  - Type a question and press Return: an answer streams in.
  - Press Start, play the `say` question clip with Auto-Answer on: an automatic answer appears.
  - Press ⌃⌥A with another app in front: an Answer Now answer appears.
  - Screenshots of each, and the verifying report with no open findings.
- **Checkpoint:** Jace runs it with played questions, then on a real call. Record what he reports, in his words.
- **Risks:**
  - **`RegisterEventHotKey`** is expected to work without the Accessibility permission. That hasn't been tested here, so check it first.
  - **The toolbar** may overflow into » at the 420-point minimum width. That's fine, but check what's hidden first.

### Task 7: Docs
- **Files:** `README.md`, and `private/HANDOFF.md` (gitignored).
- **README:**
  - Adding the API key (the `security add-generic-password … -w` command and the one-time Always Allow)
  - The Playbooks folder
  - The three triggers and ⌃⌥A
  - That the transcript is sent to Anthropic's API for each answer
  - A rough cost per answer, labelled as an estimate
- **Check:** the README's steps match what the app does: create a playbook file, pick it, and an answer reflects it.

## Checkpoints
1. **After Task 1:** the API works from the signed app, the Keychain prompt is answered, and the latency numbers are in. If the first text takes too long for a live call, the model or thinking choice goes back to Jace before anything else is built.
2. **After Task 6:** Jace uses it with played questions and on a real call.
