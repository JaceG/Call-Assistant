import Foundation
import Observation

/// The live transcript: finished utterances in time order, plus each side's
/// text in progress. The window, the answer engine and the phone server all
/// read from this.
@MainActor
@Observable
public final class TranscriptStore {
    public private(set) var utterances: [Utterance] = []
    /// Text still being recognized, per speaker. Absent when nothing is in progress.
    public private(set) var partial: [Speaker: String] = [:]

    public init() {}

    /// Replaces the speaker's text in progress; an empty string clears it.
    public func setPartial(_ text: String, for speaker: Speaker) {
        partial[speaker] = text.isEmpty ? nil : text
    }

    /// Adds a finished utterance in time order (the two channels finish speech
    /// at different moments) and clears that speaker's text in progress.
    public func append(_ utterance: Utterance) {
        let index = utterances.lastIndex { $0.start <= utterance.start }.map { $0 + 1 } ?? 0
        utterances.insert(utterance, at: index)
        partial[utterance.speaker] = nil
    }

    public func clear() {
        utterances.removeAll()
        partial.removeAll()
    }

    /// "[14:13:25] Them: text" lines, for copying.
    public func plainText(timeZone: TimeZone = .current) -> String {
        utterances
            .map { "[\($0.start.clockTime(in: timeZone))] \($0.speaker.label): \($0.text)" }
            .joined(separator: "\n")
    }
}
