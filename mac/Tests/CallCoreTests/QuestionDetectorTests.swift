import CallCore
import Foundation
import Testing

struct QuestionDetectorTests {
    static let t0 = Date(timeIntervalSince1970: 1_792_505_600)
    let detector = QuestionDetector()

    func question(_ text: String, from speaker: Speaker = .them) -> String? {
        detector.question(in: Utterance(speaker: speaker, text: text, start: Self.t0, end: Self.t0 + 3))
    }

    @Test func aRealQuestionIsPicked() {
        #expect(question("Can you walk me through how you would cache API responses in a mobile app?")
            == "Can you walk me through how you would cache API responses in a mobile app?")
    }

    @Test func onlyTheQuestionSentencesAreKept() {
        #expect(question("That's great. How big was the team? And how did you split the work?")
            == "How big was the team? And how did you split the work?")
    }

    @Test func myOwnQuestionsAreIgnored() {
        #expect(question("Can you tell me more about the team structure?", from: .me) == nil)
    }

    @Test func shortQuestionsAreIgnored() {
        #expect(question("Really?") == nil)
        #expect(question("Is that so?") == nil)
    }

    @Test func tagQuestionsAreIgnored() {
        #expect(question("We ship every two weeks, right?") == nil)
        #expect(question("It was a pretty big migration, you know?") == nil)
        #expect(question("Does that make sense?") == nil)
        #expect(question("Sound good?") == nil)
    }

    @Test func callLogisticsAreIgnored() {
        #expect(question("Can you hear me?") == nil)
        #expect(question("Can you see my screen?") == nil)
    }

    @Test func requestsWithoutAQuestionMarkArePicked() {
        #expect(question("Tell me about a time you disagreed with a designer.")
            == "Tell me about a time you disagreed with a designer.")
        #expect(question("So walk me through your testing setup.") == "So walk me through your testing setup.")
        #expect(question("Okay, explain how the sync works when the app is offline.")
            == "Okay, explain how the sync works when the app is offline.")
    }

    @Test func statementsAreIgnored() {
        #expect(question("We use SwiftUI for most of the new screens.") == nil)
        #expect(question("I'd like to explain our process first.") == nil)
    }
}
