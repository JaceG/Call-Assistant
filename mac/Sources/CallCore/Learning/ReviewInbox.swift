import Foundation
import Observation

/// The suggestions from the review after the last call, until Jace adds or
/// skips each one. Adding an instruction appends it to Always.md, adding a
/// quick action puts a button in the row, and keeping a feature idea writes
/// it to Feature Ideas.md. Every choice goes into Learning.md, so the next
/// review doesn't suggest it again.
@MainActor
@Observable
public final class ReviewInbox {
    /// The suggestions still to decide on, from the call named `call`.
    public private(set) var review: SessionReview?
    public private(set) var call = ""
    public private(set) var isReviewing = false
    public private(set) var failure: String?

    @ObservationIgnored private let reviewer: SessionReviewer
    @ObservationIgnored private let log: LearningLog
    @ObservationIgnored private let always: AlwaysInstructions
    @ObservationIgnored private let defaults: UserDefaults
    /// Called after an instruction is added, with the new Always text.
    @ObservationIgnored public var onAlwaysChanged: ((String) -> Void)?

    public init(reviewer: SessionReviewer, log: LearningLog = LearningLog(), always: AlwaysInstructions = AlwaysInstructions(),
                defaults: UserDefaults = .standard) {
        self.reviewer = reviewer
        self.log = log
        self.always = always
        self.defaults = defaults
    }

    /// How many suggestions are waiting.
    public var waiting: Int { review?.suggestionCount ?? 0 }

    /// Reviews a finished call, unless there was too little in it.
    public func review(call: String, lines: [Utterance], answers: [Answer]) async {
        guard SessionReviewer.isWorthReviewing(lines: lines, answers: answers), !isReviewing else { return }
        isReviewing = true
        defer { isReviewing = false }
        do {
            let review = try await reviewer.review(
                lines: lines, answers: answers, always: always.load(),
                quickActions: QuickAction.decode(defaults.string(forKey: QuickAction.storageKey) ?? ""),
                learningLog: log.tail()
            )
            try? log.recordReview(review, call: call, at: Date())
            failure = nil
            self.call = call
            self.review = review.suggestionCount > 0 ? review : nil
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: Choices

    public func add(_ instruction: SessionReview.Instruction) {
        do {
            try always.append(instruction.text)
            onAlwaysChanged?(always.load())
            decided("Added instruction: \(instruction.text)")
        } catch {
            failure = "Couldn't add the instruction: \(error.localizedDescription)"
            return
        }
        review?.instructions.removeAll { $0 == instruction }
        closeIfDone()
    }

    public func add(_ idea: SessionReview.QuickActionIdea) {
        var actions = QuickAction.decode(defaults.string(forKey: QuickAction.storageKey) ?? "")
        actions.append(QuickAction(name: idea.name, prompt: idea.prompt))
        defaults.set(QuickAction.encode(actions), forKey: QuickAction.storageKey)
        decided("Added quick action \(idea.name): \(idea.prompt)")
        review?.quickActions.removeAll { $0 == idea }
        closeIfDone()
    }

    public func keep(_ idea: SessionReview.FeatureIdea) {
        do {
            try log.keepFeature(idea, call: call, at: Date())
            decided("Kept feature idea: \(idea.title)")
        } catch {
            failure = "Couldn't save the idea: \(error.localizedDescription)"
            return
        }
        review?.features.removeAll { $0 == idea }
        closeIfDone()
    }

    public func skip(_ instruction: SessionReview.Instruction) {
        decided("Skipped instruction: \(instruction.text)")
        review?.instructions.removeAll { $0 == instruction }
        closeIfDone()
    }

    public func skip(_ idea: SessionReview.QuickActionIdea) {
        decided("Skipped quick action \(idea.name): \(idea.prompt)")
        review?.quickActions.removeAll { $0 == idea }
        closeIfDone()
    }

    public func skip(_ idea: SessionReview.FeatureIdea) {
        decided("Skipped feature idea: \(idea.title)")
        review?.features.removeAll { $0 == idea }
        closeIfDone()
    }

    /// Skips everything still waiting.
    public func skipAll() {
        guard let review else { return }
        review.instructions.forEach(skip)
        review.quickActions.forEach(skip)
        review.features.forEach(skip)
    }

    private func decided(_ choice: String) {
        try? log.recordChoice(choice)
    }

    private func closeIfDone() {
        if review?.suggestionCount == 0 { review = nil }
    }
}
