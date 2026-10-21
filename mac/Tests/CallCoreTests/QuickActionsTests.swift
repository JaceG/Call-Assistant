import CallCore
import Foundation
import Testing

struct QuickActionsTests {
    @Test func nothingSavedMeansTheStarters() {
        #expect(QuickAction.decode("").map { $0.name } == ["Shorter", "Simpler", "Example", "Ask them", "Recap"])
        #expect(QuickAction.starters.allSatisfy { $0.isComplete })
    }

    @Test func aSavedListComesBackTheSameIncludingAnEmptyOne() {
        let actions = [QuickAction(name: "Stall", prompt: "Give me something natural to say while I think.")]
        #expect(QuickAction.decode(QuickAction.encode(actions)) == actions)
        #expect(QuickAction.decode(QuickAction.encode([])) == [])
    }

    @Test func unreadableSettingsFallBackToTheStarters() {
        #expect(QuickAction.decode("not json") == QuickAction.starters)
    }

    @Test func anActionNeedsANameAndAPromptToGetAButton() {
        #expect(!QuickAction(name: " ", prompt: "Make that shorter.").isComplete)
        #expect(!QuickAction(name: "Shorter", prompt: "\n").isComplete)
    }
}
