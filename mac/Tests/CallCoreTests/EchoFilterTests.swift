import CallCore
import Foundation
import Testing

/// Cases taken from the checkpoint 2 runs (2026-10-20), where the mic heard
/// the speakers.
struct EchoFilterTests {
    static let t0 = Date(timeIntervalSince1970: 1_792_505_600)
    static let question = "Can you walk me through how the caching layer handles invalidation?"

    static func line(_ speaker: Speaker, _ text: String, at seconds: TimeInterval, for duration: TimeInterval = 3) -> Utterance {
        Utterance(speaker: speaker, text: text, start: t0 + seconds, end: t0 + seconds + duration)
    }

    let filter = EchoFilter()

    @Test func dropsAnExactRepeatOfWhatTheySaid() {
        let them = [Self.line(.them, Self.question, at: 0)]
        #expect(filter.clean(Self.line(.me, Self.question, at: 0), against: them) == nil)
    }

    @Test func dropsARepeatWithRecognitionDifferences() {
        let them = [Self.line(.them, "And what happens when 2 rights arrive at the same time?", at: 10)]
        let mine = Self.line(.me, "And what happens when two rights arrive at the same time?", at: 10)
        #expect(filter.clean(mine, against: them) == nil)
    }

    @Test func keepsMyOwnAnswer() {
        let them = [Self.line(.them, Self.question, at: 0)]
        let mine = Self.line(.me, "Sure, the cash keys expire after five minutes.", at: 4)
        #expect(filter.clean(mine, against: them) == mine)
    }

    @Test func trimsTheEchoOffMyOwnWords() {
        let them = [Self.line(.them, Self.question, at: 0)]
        let mine = Self.line(.me, "Sure, the cash. Can you walk me through how the cashing layer handles invalidation?", at: 0, for: 5)
        let cleaned = filter.clean(mine, against: them)
        #expect(cleaned?.text == "Sure, the cash.")
        #expect(cleaned?.id == mine.id)
        #expect(cleaned?.start == mine.start)
    }

    @Test func dropsAnEchoFragment() {
        let them = [Self.line(.them, Self.question, at: 0)]
        let mine = Self.line(.me, "Can you walk me through how the cast...", at: 1)
        #expect(filter.clean(mine, against: them) == nil)
    }

    @Test func keepsTheSameWordsWhenTheyWereSaidLongAgo() {
        let them = [Self.line(.them, Self.question, at: 0)]
        let mine = Self.line(.me, Self.question, at: 30)
        #expect(filter.clean(mine, against: them) == mine)
    }

    @Test func ignoresMyOwnEarlierLines() {
        let others = [Self.line(.me, Self.question, at: 0)]
        let mine = Self.line(.me, Self.question, at: 2)
        #expect(filter.clean(mine, against: others) == mine)
    }
}
