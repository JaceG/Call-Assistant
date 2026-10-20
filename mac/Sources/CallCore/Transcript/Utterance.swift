import Foundation

/// Which side of the call said it: the microphone is me, the system audio is them.
public enum Speaker: String, Codable, Sendable, CaseIterable {
    case me
    case them

    public var label: String {
        switch self {
        case .me: "Me"
        case .them: "Them"
        }
    }
}

/// One finished stretch of speech from one side of the call.
public struct Utterance: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let speaker: Speaker
    public let text: String
    public let start: Date
    public let end: Date

    public init(id: UUID = UUID(), speaker: Speaker, text: String, start: Date, end: Date) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.start = start
        self.end = end
    }
}

extension Date {
    /// "14:13:25" in the given time zone, for transcript lines.
    func clockTime(in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute, .second], from: self)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
