# Live Summary and Session Learning Plan

**Goal:**
1. A live summary document of the call that Jace can read beside the transcript or in its own window.
2. Suggestions after each call, for standing instructions and for new app features, learned from how he used the app.

**Approach:**
- Both are structured-JSON requests to Claude (`output_config.format`), separate from the answers.
- The summary is redone at most once a minute while the call has new lines, building on the previous version so it stays stable to read. It's held while Jace points at it.
- The review runs once, after Stop.
- Nothing from the review changes until Jace accepts it.

**Stack:** Swift 6.4, SwiftUI (`.inspector`, a second `Window`), CallCore, and the Messages API over raw HTTP with structured outputs.

**Spec:** Jace (2026-10-21).
- *Summary:* "an ongoing 'summary' document… open on the side in a panel like a claude artifact style thing… session recaps, quotes, Q/As, points, short summaries, where it could naturally lead to next at the end… never more than… every 60 seconds as to not have it update mid-read. Maybe other useful things you might think of."
- *Learning:* "learn from my prompting at the end of every session. It should record patterns and ideas it sees in a session and propose updating the universal pre-prompt training with them."
- *His answers to my questions:*
  - Show the summary in "Both" (a side panel and its own window).
  - "Wait while I point with an update now button when a new one is ready to populate instantly."
  - "New always instructions, and also suggest updates to code into the app as features."
  - Auto-commit each step.

## Decisions

**Summary sections,** in this order:
- Summary (2–4 sentences)
- Key points
- Questions and answers (who asked, and what was said back)
- Quotes (exact words, with who said them and when)
- Decisions
- Action items (who does what)
- Open questions
- Names and numbers (people, companies, prices, dates mentioned)
- Where this could go next (last)

Empty sections are hidden. "Decisions", "Action items", "Open questions" and "Names and numbers" are the "other useful things".

**When the summary updates:**
- A check every 60 s while listening, plus one final version at Stop.
- A request goes out only if new lines arrived since the last one, and never more than one per 60 s.
- The previous version is sent back, with an instruction to keep the wording of items that still hold.

**Reading hold:**
- While the pointer is over the summary (panel or window), a new version waits.
- An **Update Now** button appears to apply it at once. When the pointer leaves, it applies.

**Where the summary shows:**
- A **Summary** toolbar button toggles a right-hand side panel (`.inspector`).
- A pop-out button in the panel opens the **Call Summary** window. It shows the same document and floats when Keep on Top is on.

**Saving:**
- The call's Sessions folder gets `<call file name> summary.md`, rewritten with each new version. The final one is written at Stop.
- A **Copy** button copies the summary as Markdown.

**"Always" instructions:**
- A new `Always.md` in the app's support folder, used on every call whatever the playbook.
- The prompt order becomes base, Always, files, playbook, notes.
- **Edit Always Instructions…** sits at the bottom of the Playbook menu and opens an editor sheet.

**The review after Stop:**
- *Claude sees:*
  - the call's lines
  - its own answers, with how each was asked (Auto, Answer Now, Typed, or Quick and which button)
  - the current Always instructions and quick actions
  - what was proposed and skipped before
- *It returns:*
  - observations
  - instruction proposals
  - quick-action proposals
  - feature ideas

  Each item comes with a reason that points at what happened.
- *Where it shows:* the status bar says "Claude has N suggestions from this call — Review". That opens a sheet with **Add** or **Skip** on each item.
  - **Add** puts an instruction into Always.md and a quick action into the button row.
  - **Add** puts a feature idea into `Feature Ideas.md` (support folder) under a date, ready to hand to Claude Code. A **Copy** button sits next to each idea.
  - **Skipped** items go into `Learning.md`, so they aren't proposed again.
- *Saved:* every review is appended to `Learning.md` with its date and what Jace chose.

**Model:** `claude-sonnet-5-5` at low effort, as for answers. The transcript is cached the same way.

**Cost** (estimate): about 1¢ per summary update, so about 60¢ for an hour-long call. A few cents for each review.

## Tasks

1. **Structured requests.**
   - `ClaudeProvider.json(_ prompt: AnswerPrompt, schema: Data) async throws -> Data`: not streamed, `output_config.format = {type: json_schema, schema}`.
   - A `StructuredProvider` protocol, so tests can fake it.
   - *Check:* tests on the request body, and one live request with a small schema.
2. **SummaryEngine (CallCore).**
   - `CallSummary` (Codable) and its schema.
   - The prompt: summary instructions, then the transcript chunks, then the previous summary.
   - The 60 s rule, the hold (`isHeld`, `pending`, `applyPending()`), the final version at Stop, and the Markdown text.
   - `LiveSession` drives it and writes `summary.md`.
   - *Check:*
     - Tests for: no request without new lines, at most one per interval, a held update pending and applied, and the Markdown.
     - A probe, `--probe-summary <call.md>`, against a saved call.
3. **The summary panel and window.** The toolbar button, the inspector, the window, Update Now, Copy, and the hold while pointing.
   - *Process:* the ui-consistency steps.
   - *Check:*
     - Driven by me in the window against a mock call from YouTube.
     - The separate check.
4. **Always instructions.** `AlwaysInstructions` storage, the prompt block, and the menu item and sheet.
   - *Check:* tests for the prompt order and caching.
5. **The review after Stop.**
   - `SessionReviewer` builds the review prompt and schema, and records each answer's trigger and quick-action name.
   - It writes `Learning.md` and `Feature Ideas.md`.
   - *Check:*
     - Tests.
     - A probe, `--probe-review <call.md>`, on a saved call where Shorter was used several times. Expected: an instruction proposal about length.
6. **The review sheet.** The status bar notice, the sheet with Add/Skip/Copy, and the outcomes applied.
   - *Process:* the ui-consistency steps.
   - *Check:* driven by me in the window, and the separate check.
7. **Docs.** README, and this plan's results.

## Checkpoint

After Task 3, show Jace the summary panel updating on a mock call. Then go on.

## Results (2026-10-21)

**Mid-build request from Jace:** "When lines are just updated or added, highlight them until the next change so I can quickly see the new changes."
- Each item that isn't in the previous version is highlighted with the system's find-highlight colour until the next version.
- VoiceOver reads it as "New". The first version highlights nothing.

**Summary:**
- `--probe-summary` on the saved mock interview took 10 s per version. The second version kept every earlier point word for word and added three.
- `--probe-live 200`, with a YouTube mock interview playing in the built-in browser:
  - Versions came at +66 s and +134 s, the second with 7 new or changed items.
  - The content was accurate: the requirements, the open questions, and "Name the core classes, such as Book, Page, Library…".
  - **It found a bug.** The final version at Stop failed with a CancellationError, because stopping the loop cancelled the request already under way.
  - **Fixed and unit-tested.** Updates now run in a task of their own, and Stop waits for the one under way before making the last version.
  - **Not re-run live,** because Jace was on a call.
- **One mistake in the content.** Both voices in the video were "Them", so the summary called the candidate "Jace" once. On a real call, Jace is "Me".

**Review:**
- `--probe-review` on a made-up interview took 9.7 s. In that call:
  - Shorter was pressed after three of four Auto replies, and once after a typed one.
  - "give me a number I can quote" was typed twice.
- The review suggested:
  - instructions:
    - a two-sentence limit
    - plain first-person wording
    - Jace's background as facts (8 years of Swift, SwiftUI since 2020, a team of three)
    - his real figures (60 fps, launch time halved)
  - a "Quote a number" button
  - short Auto replies, as a feature
- Every reason pointed at what happened.
- **One clash to watch.** The two-sentence suggestion conflicts with the base prompt's two-part answer. Jace decides when he sees it.

**Not tested in the window.**
- My screenshot tools failed with "Screenshot capture returned nil (permission missing or SCContentFilter failure)", from both the per-app and full-screen capture.
- Then Jace asked for the machine to stay quiet and his screen untouched during his call.
- So the summary panel, the pop-out window, Update Now, the Always editor and the review sheet are unit-tested and checked by a separate agent, but have not been seen rendered.

