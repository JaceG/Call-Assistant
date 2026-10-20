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

    @Test func theBasePromptNamesTheSidesAndAsksForMeaningOverWords() {
        let base = PromptBuilder.basePrompt
        #expect(base.contains("\"Me\" is Jace"))
        #expect(base.contains("\"Them\""))
        #expect(base.contains("sound-alike"))
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

    // MARK: Question

    @Test func eachTriggerAsksInItsOwnWords() {
        let builder = Self.builder()
        #expect(builder.prompt(lines: [], themSaying: nil, question: .typed("What is a mutex?")).question == "What is a mutex?")
        #expect(builder.prompt(lines: [], themSaying: nil, question: .answerNow).question == "Help me respond to what they just said.")
        #expect(builder.prompt(lines: [], themSaying: nil, question: .detected("How do you cache?")).question
            == "They just asked: \"How do you cache?\"\nHelp me answer it.")
    }
}
