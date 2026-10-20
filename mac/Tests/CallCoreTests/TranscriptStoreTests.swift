import CallCore
import Foundation
import Testing

@MainActor
struct TranscriptStoreTests {
    static let t0 = Date(timeIntervalSince1970: 1_792_505_600)

    static func utterance(_ speaker: Speaker, _ text: String, at seconds: TimeInterval) -> Utterance {
        Utterance(speaker: speaker, text: text, start: t0 + seconds, end: t0 + seconds + 1)
    }

    @Test func keepsUtterancesInTimeOrderWhenTheyArriveOutOfOrder() {
        let store = TranscriptStore()
        store.append(Self.utterance(.them, "third", at: 10))
        store.append(Self.utterance(.me, "first", at: 5))
        store.append(Self.utterance(.them, "second", at: 7))
        #expect(store.utterances.map(\.text) == ["first", "second", "third"])
    }

    @Test func keepsArrivalOrderForTheSameStartTime() {
        let store = TranscriptStore()
        store.append(Self.utterance(.me, "a", at: 5))
        store.append(Self.utterance(.them, "b", at: 5))
        #expect(store.utterances.map(\.text) == ["a", "b"])
    }

    @Test func setsAndClearsPartialText() {
        let store = TranscriptStore()
        store.setPartial("hel", for: .me)
        #expect(store.partial[.me] == "hel")
        store.setPartial("", for: .me)
        #expect(store.partial[.me] == nil)
    }

    @Test func appendingClearsOnlyThatSpeakersPartial() {
        let store = TranscriptStore()
        store.setPartial("I think", for: .me)
        store.setPartial("So the", for: .them)
        store.append(Self.utterance(.me, "I think so.", at: 1))
        #expect(store.partial[.me] == nil)
        #expect(store.partial[.them] == "So the")
    }

    @Test func plainTextHasTimeSpeakerAndText() {
        let store = TranscriptStore()
        store.append(Self.utterance(.me, "Hello.", at: 0))
        store.append(Self.utterance(.them, "Hi there.", at: 65))
        let utc = TimeZone(identifier: "UTC")!
        #expect(store.plainText(timeZone: utc) == "[14:13:20] Me: Hello.\n[14:14:25] Them: Hi there.")
    }
}
