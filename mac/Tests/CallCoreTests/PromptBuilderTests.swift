import CallCore
import Foundation
import Testing

struct PromptBuilderTests {
    static let t0 = Date(timeIntervalSince1970: 1_792_505_600) // 14:13:20 UTC
    static let utc = TimeZone(identifier: "UTC")!
    static let playbook = Playbook(name: "Interview", instructions: "Answer as a senior iOS developer.")

    static func line(_ speaker: Speaker, _ text: String, at seconds: TimeInterval) -> Utterance {
        Utterance(speaker: speaker, text: text, start: t0 + seconds, end: t0 + seconds + 2)
    }

    static func lines(_ count: Int) -> [Utterance] {
        (0..<count).map { line($0.isMultiple(of: 2) ? .them : .me, "Line \($0).", at: Double($0) * 5) }
    }

    static func builder(playbook: Playbook? = playbook, notes: String = "Call with Dana about the app.") -> PromptBuilder {
        PromptBuilder(playbook: playbook, callNotes: notes, chunkSize: 10, timeZone: utc)
    }

    // MARK: System

    @Test func systemIsBasePlaybookThenNotesWithTheBreakpointOnTheLast() {
        let system = Self.builder().prompt(lines: [], themSaying: nil, question: .typed("Hi?")).system
        #expect(system.count == 3)
        #expect(system[0].text == PromptBuilder.basePrompt)
        #expect(system[1].text == "# Playbook: Interview\n\nAnswer as a senior iOS developer.")
        #expect(system[2].text == "# Notes for this call\n\nCall with Dana about the app.")
        #expect(system.map(\.cacheBreakpoint) == [false, false, true])
    }

    @Test func withNoPlaybookAndBlankNotesOnlyTheBaseIsSent() {
        let system = Self.builder(playbook: nil, notes: "  \n ").prompt(lines: [], themSaying: nil, question: .typed("Hi?")).system
        #expect(system.map(\.text) == [PromptBuilder.basePrompt])
        #expect(system.map(\.cacheBreakpoint) == [true])
    }

    @Test func filesGoAfterTheBaseAndBeforeThePlaybookWithAnHourLongBreakpoint() {
        let files = CallFiles(files: [
            ContextFile(path: "App/b.swift", text: "struct B {}\n"),
            ContextFile(path: "App/a.swift", text: "struct A {}"),
        ], skipped: [])
        let system = PromptBuilder(playbook: Self.playbook, callNotes: "Call with Dana.", files: files, timeZone: Self.utc)
            .prompt(lines: [], themSaying: nil, question: .typed("Hi?")).system
        #expect(system.count == 4)
        #expect(system[1].text == """
            # Files for this call

            Jace picked these files for this call.

            <file path="App/a.swift">
            struct A {}
            </file>

            <file path="App/b.swift">
            struct B {}
            </file>
            """)
        #expect(system[2].text.hasPrefix("# Playbook: Interview"))
        #expect(system[3].text.hasPrefix("# Notes for this call"))
        #expect(system.map(\.cacheBreakpoint) == [false, true, false, true])
        #expect(system.map(\.cachesForAnHour) == [false, true, false, false])
    }

    @Test func filesTooBigToSendAreListedForTheTools() {
        let big = CallFiles(files: [
            ContextFile(path: "Site/b.js", text: "b"),
            ContextFile(path: "Site/a.js", text: String(repeating: "x", count: 375_003)),
        ], skipped: [])
        let prompt = PromptBuilder(playbook: nil, callNotes: "", files: big, timeZone: Self.utc)
            .prompt(lines: [], themSaying: nil, question: .typed("Hi?"))
        #expect(prompt.lookup == FileLookup(files: big))
        #expect(prompt.system[1].text.contains("search_files finds lines"))
        #expect(prompt.system[1].text.hasSuffix("The files:\nSite/a.js\nSite/b.js"))
        #expect(!prompt.system[1].text.contains("xxxx"))
    }

    @Test func filesSentWholeNeedNoTools() {
        let small = CallFiles(files: [ContextFile(path: "a.txt", text: "a")], skipped: [])
        let prompt = PromptBuilder(playbook: nil, callNotes: "", files: small).prompt(lines: [], themSaying: nil, question: .typed("Hi?"))
        #expect(prompt.lookup == nil)
    }

    @Test func alwaysComesRightAfterTheBase() {
        let files = CallFiles(files: [ContextFile(path: "a.txt", text: "a")], skipped: [])
        let system = PromptBuilder(always: "  Keep it to two sentences.\n", playbook: Self.playbook, callNotes: "Notes.", files: files)
            .prompt(lines: [], themSaying: nil, question: .typed("Hi?")).system
        #expect(system.map { $0.text.components(separatedBy: "\n").first ?? "" }
            == [system[0].text.components(separatedBy: "\n").first ?? "", "# Always", "# Files for this call", "# Playbook: Interview", "# Notes for this call"])
        #expect(system[1].text == "# Always\n\nKeep it to two sentences.")
        #expect(system.map(\.cacheBreakpoint) == [false, false, true, false, true])
    }

    @Test func noFilesMeansNoFilesBlock() {
        let system = Self.builder().prompt(lines: [], themSaying: nil, question: .typed("Hi?")).system
        #expect(!system.contains { $0.text.hasPrefix(PromptBuilder.filesHeading) })
        #expect(PromptBuilder.basePrompt.contains("answer from what the files say"))
    }

    @Test func theBasePromptNamesTheSidesAndAsksForMeaningOverWords() {
        let base = PromptBuilder.basePrompt
        #expect(base.contains("\"Me\" is Jace"))
        #expect(base.contains("\"Them\""))
        #expect(base.contains("sound-alike"))
    }

    /// Jace, after the window tests (2026-10-20): "I need the very first thing I
    /// read to be the response I need to give to the other person", then "I need
    /// a quick concise answer, and then an elaborated answer that picks up after
    /// it naturally. I need them clearly separated but nothing in between them".
    @Test func theBasePromptAsksForAQuickAnswerThenALongerOne() {
        let base = PromptBuilder.basePrompt
        #expect(base.contains("exactly two parts and nothing else"))
        #expect(base.contains("The quick answer: one short sentence"))
        #expect(base.contains("Begin your reply with it"))
        #expect(base.contains("carry on naturally from the quick answer"))
        #expect(base.contains("no bullets"))
        #expect(base.contains("never mention them"))
    }

    // MARK: Transcript

    @Test func fullChunksAreFrozenAndTheLastFullOneCarriesTheBreakpoint() {
        let transcript = Self.builder().prompt(lines: Self.lines(23), themSaying: nil, question: .answerNow).transcript
        #expect(transcript.count == 3)
        #expect(transcript.map(\.cacheBreakpoint) == [false, true, false])
        #expect(transcript[0].text.hasPrefix(PromptBuilder.transcriptHeading))
        #expect(transcript[0].text.contains("[14:13:20] Them: Line 0.\n[14:13:25] Me: Line 1."))
        #expect(transcript[1].text.hasPrefix("[14:14:10] Them: Line 10."))
        #expect(transcript[2].text == "[14:15:00] Them: Line 20.\n[14:15:05] Me: Line 21.\n[14:15:10] Them: Line 22.")
    }

    @Test func frozenChunksDontChangeWhenALateLineArrives() {
        let builder = Self.builder()
        let before = builder.prompt(lines: Self.lines(23), themSaying: nil, question: .answerNow).transcript
        // A Me line recorded late, with an earlier start time, goes at the end.
        let late = Self.lines(23) + [Self.line(.me, "Late line.", at: 3)]
        let after = builder.prompt(lines: late, themSaying: nil, question: .answerNow).transcript
        #expect(after[0] == before[0])
        #expect(after[1] == before[1])
        #expect(after[2].text.hasSuffix("[14:13:23] Me: Late line."))
    }

    @Test func fewerLinesThanAChunkMeansNoTranscriptBreakpoint() {
        let transcript = Self.builder().prompt(lines: Self.lines(4), themSaying: nil, question: .answerNow).transcript
        #expect(transcript.count == 1)
        #expect(transcript[0].cacheBreakpoint == false)
        #expect(transcript[0].text.hasPrefix(PromptBuilder.transcriptHeading))
    }

    @Test func wordsStillBeingSpokenGoAtTheEnd() {
        let transcript = Self.builder().prompt(lines: Self.lines(20), themSaying: "and how would you test", question: .answerNow).transcript
        #expect(transcript.count == 3)
        #expect(transcript[2].text == "(still speaking) Them: and how would you test")
    }

    @Test func noLinesAndNothingSpokenMeansNoTranscript() {
        #expect(Self.builder().prompt(lines: [], themSaying: nil, question: .typed("What is a mutex?")).transcript.isEmpty)
        #expect(Self.builder().prompt(lines: [], themSaying: "", question: .typed("What is a mutex?")).transcript.isEmpty)
    }

    // MARK: Earlier answers and pending lines

    static func answer(_ trigger: Answer.Trigger, _ question: String, _ text: String, at seconds: TimeInterval,
                       state: Answer.State = .done) -> Answer {
        Answer(trigger: trigger, question: question, askedAt: t0 + seconds, text: text, state: state)
    }

    @Test func earlierAnswersReadAsClaudeLinesInRecordedOrder() {
        let entries: [TranscriptEntry] = [
            .line(Self.line(.them, "How do you cache?", at: 0)),
            .answer(Self.answer(.auto, "How do you cache?", "I cache at the edge.\n\nThen I invalidate on write.", at: 3)),
            .line(Self.line(.me, "I cache at the edge.", at: 10)),
        ]
        let transcript = Self.builder().prompt(entries: entries, themSaying: nil, question: .answerNow).transcript
        #expect(transcript.map(\.text) == [PromptBuilder.transcriptHeading + """
            [14:13:20] Them: How do you cache?
            [14:13:23] Claude, to Jace only: I cache at the edge. Then I invalidate on write.
            [14:13:30] Me: I cache at the edge.
            """])
    }

    @Test func aTypedAnswerShowsItsQuestionAndACutOffAnswerSaysSo() {
        let entries: [TranscriptEntry] = [
            .answer(Self.answer(.typed, "What is a mutex?", "A lock.", at: 0)),
            .answer(Self.answer(.answerNow, "Them", "I'd start by", at: 5, state: .stopped)),
        ]
        let text = Self.builder().prompt(entries: entries, themSaying: nil, question: .typed("Shorter")).transcript[0].text
        #expect(text.hasSuffix("""
            [14:13:20] Jace asked Claude: What is a mutex?
            [14:13:20] Claude, to Jace only: A lock.
            [14:13:25] Claude, to Jace only: I'd start by (cut off)
            """))
    }

    @Test func myPendingLinesGoByTimeAmongTheNewestLines() {
        let entries: [TranscriptEntry] = [
            .line(Self.line(.them, "How do you cache?", at: 0)),
            .line(Self.line(.them, "In production. How would you invalidate it?", at: 20)),
        ]
        let pending = [Self.line(.me, "In production or in tests?", at: 10)]
        let text = Self.builder().prompt(entries: entries, pendingMine: pending, themSaying: nil, question: .answerNow).transcript[0].text
        #expect(text.hasSuffix("""
            [14:13:20] Them: How do you cache?
            [14:13:30] Me: In production or in tests?
            [14:13:40] Them: In production. How would you invalidate it?
            """))
    }

    @Test func theBasePromptExplainsClaudeLines() {
        #expect(PromptBuilder.basePrompt.contains("Lines marked \"Claude\" are your own earlier replies"))
        #expect(PromptBuilder.basePrompt.contains("he means your latest one"))
    }

    // MARK: Question

    @Test func eachTriggerAsksInItsOwnWords() {
        let builder = Self.builder()
        #expect(builder.prompt(lines: [], themSaying: nil, question: .typed("What is a mutex?")).question == "What is a mutex?")
        #expect(builder.prompt(lines: [], themSaying: nil, question: .answerNow).question == "What should I say back to what they just said?")
        #expect(builder.prompt(lines: [], themSaying: nil, question: .detected("How do you cache?")).question
            == "They just asked: \"How do you cache?\"\nWhat should I say?")
    }
}
