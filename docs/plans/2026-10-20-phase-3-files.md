# Phase 3: Folders and Files for a Call Plan

**Goal:** Jace picks folders and files for a call (a project's code, a resume PDF), and Claude's answers use them.

**Approach:**
- The app reads the chosen folders and files into memory as text.
- If they're small enough, all of the text goes into the system prompt, cached for an hour, so every answer can use it.
- If they're too big, Claude gets the list of files and two tools to search them and read them while it answers.
- Picks stay until Jace changes them, like the playbook.

**Stack:** Swift 6.4, SwiftUI, CallCore, the Messages API over raw HTTP (as in Phase 2), PDFKit, and AppKit's document reading for Word and RTF.

**Spec:**
- Jace (2026-10-20): "Just a way for the app to respond to questions live and also have context of certain folders and files for a call."
- The original requirement: "indexing local PC directory paths containing PDFs, text, markdown, or codebases without commercial file limits."

## Scope change

This replaces the old phase list:

| Phase | Was | Now |
|---|---|---|
| 3 | Phone server and iPhone app | Dropped. iOS apps can't hear call audio on the same iPhone (from web sources, not tested). |
| 4 | Screen capture and call recording | Dropped. |
| 5 | Codebase index | **This plan,** as Phase 3. |
| 6 | Headless | Dropped. |
| 7 | Tailscale/AWS remote access | Dropped. |

Jace dropped all four, and confirmed it with "You are correct". Nothing is left after this plan.

## Decisions

- **Small or big is decided by size, not by Jace.**
  - Up to the budget (initially 150,000 tokens, estimated as characters ÷ 3), Claude gets everything ("whole").
  - Above it, Claude searches ("look-up").
  - The budget gets checked against measured times in Task 2.
- **What's read:**
  - Text and code (any UTF-8 file without NUL bytes in its first 8 KB).
  - PDF, through PDFKit.
  - Word (`.docx`, `.doc`), `.rtf` and `.odt`, through `NSAttributedString`.
- **What's skipped.** Each skipped file is listed with its reason.
  - In a git work tree: whatever `git ls-files --cached --others --exclude-standard` leaves out (that is, .gitignore).
  - Otherwise: hidden files and folders, plus `node_modules`, `build`, `dist`, `.build`, `DerivedData`, `Pods`, `.next`, `target`, `out`, `__pycache__`, `venv`, `.venv` and `coverage`.
  - Always skipped:
    - Lockfiles.
    - `*.min.js` and `*.min.css`.
    - `*.map`.
    - Any text over 1 MB.
  - **Secrets are never sent, even when picked by hand:**
    - `.env*`, `.npmrc`, `.netrc`, `.pypirc`
    - `*.pem`, `*.key`, `*.p12`, `*.p8`, `*.pfx`, `*.jks`, `*.keystore`, `*.mobileprovision`
    - `id_rsa*`, `id_ecdsa*`, `id_ed25519*`
  - A walk stops at 20,000 files and says so, in case of a pick like the whole home folder.
- **Prompt order:** base, files, playbook, notes.
  - Files sit before the notes, so editing notes mid-call keeps the files cached.
  - The files block gets its own `cache_control` with `ttl: "1h"`. Gaps between answers can pass 5 minutes. The longer TTL has to come before the 5-minute breakpoints, which this order gives.
  - That's 3 breakpoints at most: files, the end of the system prompt, and the transcript.
- **Warming the cache:** a `max_tokens: 0` request, not streamed, with the same system prompt.
  - It's sent at Start, and when the files change during a call.
  - So the first answer of a call doesn't wait for the files to be cached.
- **Look-up tools:**
  - `search_files(query)`: lines containing every word of the query (case-insensitive), with file-name matches first. Up to 40 lines, each `path:line: text`.
  - `read_file(path, start_line?, end_line?)`: numbered lines, at most 800 lines or 40,000 characters per call.
  - At most 4 rounds of requests. The last round sends `tool_choice: {type: "none"}`, so Claude answers with what it has.
  - The assistant's content blocks (thinking with its signature, text, tool_use) are sent back unchanged, as preserved thinking requires.
- **While Claude looks:** the answer shows what it's doing, for example "Searching for "offline sync"…" or "Reading mac/Sources/…/SessionWriter.swift…".
- **Base prompt:** one line saying to answer from the files when the question is about them, and to look things up only when needed.

## Files

```
mac/Sources/CallCore/Files/
    FileCollector.swift      reads chosen folders/files → [ContextFile] + skipped, by the rules above
    DocumentText.swift       PDF / Word / RTF → text
    CallFiles.swift          the loaded set: files, size estimate, mode (.whole / .lookUp), summary
    FileLookup.swift         search_files / read_file over CallFiles; tool definitions
mac/Sources/CallCore/Answers/
    AnswerProvider.swift     AnswerPrompt.files; AnswerEvent.lookingUp(String)
    ServerSentEvents.swift   also keeps whole content blocks (thinking + signature, tool_use input) for the tool loop
    ClaudeProvider.swift     tools, the tool loop, the 1h breakpoint, warm(_:)
    PromptBuilder.swift      the files block; the base prompt line
    AnswerEngine.swift       files; Answer.activity; warm at Start
mac/Sources/CallCore/Session/LiveSession.swift   warm at Start
mac/Sources/CallCore/Probes.swift                --probe-files, --probe-answer --files
mac/Sources/CallAssistant/FilesPopover.swift      the Files button's popover
mac/Sources/CallAssistant/TranscriptWindow.swift  the Files button; stored picks
mac/Tests/CallCoreTests/                          FileCollectorTests, FileLookupTests, ClaudeToolLoopTests, + PromptBuilder/ClaudeRequest/ServerSentEvents/AnswerEngine additions
README.md                                         Files section; phone app and AWS removed
```

## Tasks

### Task 1: read folders and files

- **Intent:** turn the chosen paths into text files Claude can use, with what was skipped and why.
- **Files:** `FileCollector.swift`, `DocumentText.swift`, `CallFiles.swift`, `FileCollectorTests.swift`, `Probes.swift`.
- **Interfaces:**
  ```swift
  public struct ContextFile: Sendable, Equatable { public let path: String; public let text: String }   // path as shown: "<folder name>/sub/file.swift"
  public struct SkippedFile: Sendable, Equatable { public let path: String; public let reason: String }
  public struct CallFiles: Sendable, Equatable {
      public let files: [ContextFile]          // sorted by path
      public let skipped: [SkippedFile]
      public var estimatedTokens: Int          // characters / 3
      public enum Mode: Sendable { case whole, lookUp }
      public var mode: Mode                    // .whole when estimatedTokens <= CallFiles.wholeBudget
      public static let wholeBudget = 150_000
  }
  public struct FileCollector: Sendable { public func collect(_ picks: [URL]) async -> CallFiles }
  ```
- **Check:**
  - `swift test` passes. The tests cover the skip rules, secrets, binary files, sorting, a git repo with a .gitignore, and a picked file that's a secret.
  - `--probe-files <this repo>` and `--probe-files ~/Codebases/Personal/Jace-Portfolio` print the counts, the estimate, the mode and the skip reasons. This repo should come out "whole" and the Portfolio "lookUp".
- **Risks:**
  - `/usr/bin/git` needs the command-line tools. If git fails, fall back to the walk.
  - Folders in ~/Documents or ~/Desktop may make macOS ask for access.

### Task 2: whole mode

- **Intent:** the files go into the cached system prompt, and the cache is warmed at Start.
- **Files:** `PromptBuilder.swift`, `AnswerProvider.swift`, `ClaudeProvider.swift`, and their tests, plus `Probes.swift`.
- **Check:**
  - Tests: system order base → files → playbook → notes, the files block with `ttl: "1h"`, and the warm request body (`max_tokens` 0, no `stream`).
  - Probe on this repo: answer a question about its code (for example "How does the app cancel echo?"). Record the time to first text with a cold cache, after warming, and the cache read tokens. The answer should name the real mechanism (WebRTC AEC3).
- **Risks:** a big prompt could make the first text slow even when it's cached. If it does, lower `wholeBudget`.

### Task 3: look-up mode

- **Intent:** for big sets, Claude searches and reads files while it answers.
- **Files:** `FileLookup.swift`, `ServerSentEvents.swift`, `ClaudeProvider.swift`, `AnswerProvider.swift`, and their tests.
- **Check:**
  - Tests: the search and read results; content blocks rebuilt from a recorded stream (thinking signature, tool_use input); a two-round loop through a stubbed `URLProtocol`, with the second request carrying the first's blocks and the tool results; and the last round sending `tool_choice: none`.
  - Probe on the Portfolio with a question about its code. Record the rounds, the time to first text, and whether the answer is right.
- **Risks:** each round adds a request. If answers get too slow, prompt for fewer look-ups.

### Task 4: engine and session

- **Intent:** the engine sends the files with every answer, shows what Claude is looking up, and warms the cache at Start.
- **Files:** `AnswerEngine.swift`, `LiveSession.swift`, `AnswerEngineTests.swift`.
- **Check:** tests for `.lookingUp` setting `Answer.activity` and for the prompt carrying the files. `--probe-live` still works.

### Task 5: the Files button

- **Intent:** pick, see and remove folders and files from the window.
- **Files:** `FilesPopover.swift`, `TranscriptWindow.swift`, `AnswersPane.swift` (the activity line).
- **The popover:**
  - The list of picks: icon, name and folder, each with a remove button.
  - "Add Folders or Files…", which opens an NSOpenPanel for files and folders with multiple selection.
  - A summary line, for example "212 files · Claude reads all of them with each answer" or "1,204 files · too many to read whole, so Claude searches them when a question needs it".
  - The skipped files with their reasons.
  - "Reading files…" while loading.
- **Stored setting:** `@AppStorage("files")` holds the paths, one per line. They're read when the window opens, when the list changes, and at Start.
- **Process:** the ui-consistency steps (adjusting, implementing, then verifying by a separate agent with one plant).
- **Check:**
  - I drive the window myself. I add this repo, see the summary, ask a typed question about the code, and see it answered from the code.
  - I add the Portfolio, ask, and see "Searching…" and then an answer.

### Task 6: docs

- **Intent:** the README describes the Mac app only, with a Files section covering what's read, what's skipped, what gets sent to Anthropic, and the cost. This plan gets its results. The memory file gets updated.
- **Check:** the README has no mention of the iPhone app or AWS left.

## Checkpoint

After Task 5, show Jace the window with files picked and an answer that came from them.
