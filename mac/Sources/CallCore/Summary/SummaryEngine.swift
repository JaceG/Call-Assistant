import Foundation
import Observation

/// One version of the summary and when it was made.
public struct SummaryVersion: Sendable, Equatable {
    public let summary: CallSummary
    public let at: Date
}

/// Keeps the call's running summary.
///
/// - While a call runs, it checks once per `interval` and asks Claude for a
///   new version only if new lines arrived, so the summary changes at most
///   once a minute. Each request carries the previous version, so items
///   that still hold keep their wording.
/// - While Jace is reading (`isHeld`), a new version waits as `pending`;
///   `applyPending()` shows it at once, and it shows by itself when the hold
///   ends.
@MainActor
@Observable
public final class SummaryEngine {
    /// The version on screen and when it was made.
    public private(set) var shown: SummaryVersion?
    /// A newer version waiting for Jace to finish reading.
    public private(set) var pending: SummaryVersion?
    public private(set) var isUpdating = false
    /// Why the last update failed, until one succeeds.
    public private(set) var failure: String?
    /// True while the pointer is over the summary.
    public var isHeld = false {
        didSet { if !isHeld { applyPending() } }
    }
    /// Notes Jace wrote for this call, for context.
    @ObservationIgnored public var callNotes: @MainActor () -> String = { "" }
    /// Called with every new version as it arrives (shown or pending).
    @ObservationIgnored public var onUpdate: ((CallSummary, Date) -> Void)?

    public static let instructions = """
        You keep a running summary of a live call for Jace, who glances at it while the call goes on. The \
        transcript comes from speech recognition on his Mac: "Me" is Jace and "Them" is the other side. Read \
        sound-alike mistakes as what the speaker meant.

        Fill each part briefly, in plain sentences without Markdown, and leave a list empty when nothing fits:
        - summary: two to four sentences on what the call is about and where it stands now.
        - key_points: the main points made so far, at most eight.
        - questions: questions either side asked, with what was said back ("Not answered yet" if nothing was).
        - quotes: up to five short, notable things said, word for word from the transcript, with the time shown \
        on that line.
        - decisions: what was agreed.
        - action_items: who will do what (owner: Jace, Them, or a name).
        - open_questions: things still unresolved that are worth following up.
        - names_and_numbers: people, companies, products, prices, dates and figures mentioned, each with what it is.
        - next: two to four short suggestions for where Jace could take the conversation next.

        When a previous summary is given, keep the wording and order of every item that still holds, so Jace \
        doesn't lose his place. Change only what the new lines change, and add new items at the end of each list.
        """

    @ObservationIgnored private let provider: StructuredProvider
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var lines: @MainActor () -> [Utterance] = { [] }
    @ObservationIgnored private var summarizedCount = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let timeZone: TimeZone
    /// Counts calls, so a reply that arrives after a new call started is dropped.
    @ObservationIgnored private var generation = 0

    public init(provider: StructuredProvider, interval: Duration = .seconds(60), timeZone: TimeZone = .current) {
        self.provider = provider
        self.interval = interval
        self.timeZone = timeZone
    }

    /// The newest version, shown or pending.
    public var latest: SummaryVersion? { pending ?? shown }

    /// A new call: clears the summary and starts checking every `interval`.
    public func start(lines: @escaping @MainActor () -> [Utterance]) {
        reset()
        self.lines = lines
        let interval = interval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.updateIfNew()
            }
        }
    }

    /// The end of a call: stops checking and makes a last version if there
    /// are lines it hasn't covered.
    public func finish() async {
        loop?.cancel()
        loop = nil
        await updateIfNew()
    }

    public func reset() {
        generation += 1
        loop?.cancel()
        loop = nil
        shown = nil
        pending = nil
        failure = nil
        summarizedCount = 0
    }

    /// Shows the waiting version now.
    public func applyPending() {
        guard let pending else { return }
        shown = pending
        self.pending = nil
    }

    func updateIfNew() async {
        await update(lines: lines())
    }

    /// Asks for a new version if `lines` has lines the last one didn't cover.
    func update(lines: [Utterance]) async {
        guard !isUpdating, lines.count > summarizedCount else { return }
        isUpdating = true
        defer { isUpdating = false }
        let call = generation
        do {
            let reply = try await provider.json(prompt(for: lines), schema: CallSummary.schema)
            let summary = try CallSummary.decode(reply)
            guard call == generation else { return }
            let now = Date()
            summarizedCount = lines.count
            failure = nil
            if isHeld && shown != nil {
                pending = SummaryVersion(summary: summary, at: now)
            } else {
                shown = SummaryVersion(summary: summary, at: now)
                pending = nil
            }
            onUpdate?(summary, now)
        } catch {
            guard call == generation else { return }
            failure = error.localizedDescription
        }
    }

    /// The instructions (and notes), the transcript, then the previous
    /// version to build on.
    func prompt(for lines: [Utterance]) -> AnswerPrompt {
        var system = [PromptBlock(text: Self.instructions)]
        let notes = callNotes().trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { system.append(PromptBlock(text: "# Notes for this call\n\n\(notes)")) }
        system[system.count - 1].cacheBreakpoint = true
        let transcript = PromptBuilder(playbook: nil, callNotes: "", timeZone: timeZone).transcript(of: lines)
        let question = latest.map {
            "The previous summary:\n\($0.summary.json())\n\nUpdate it for the whole transcript above."
        } ?? "Write the summary of the call so far."
        return AnswerPrompt(system: system, transcript: transcript, question: question)
    }
}
