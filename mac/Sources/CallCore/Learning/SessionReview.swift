import Foundation

/// What Claude suggests after a call, from how Jace used the app: lines for
/// his Always instructions, new quick-action buttons, and feature ideas for
/// the app itself, each with the reason from the call.
public struct SessionReview: Codable, Sendable, Equatable {
    public struct Instruction: Codable, Sendable, Equatable, Hashable {
        public var text: String
        public var reason: String

        public init(text: String, reason: String) {
            self.text = text
            self.reason = reason
        }
    }

    public struct QuickActionIdea: Codable, Sendable, Equatable, Hashable {
        public var name: String
        public var prompt: String
        public var reason: String

        public init(name: String, prompt: String, reason: String) {
            self.name = name
            self.prompt = prompt
            self.reason = reason
        }
    }

    public struct FeatureIdea: Codable, Sendable, Equatable, Hashable {
        public var title: String
        public var description: String
        public var reason: String

        public init(title: String, description: String, reason: String) {
            self.title = title
            self.description = description
            self.reason = reason
        }
    }

    public var observations: [String]
    public var instructions: [Instruction]
    public var quickActions: [QuickActionIdea]
    public var features: [FeatureIdea]

    public init(observations: [String] = [], instructions: [Instruction] = [], quickActions: [QuickActionIdea] = [],
                features: [FeatureIdea] = []) {
        self.observations = observations
        self.instructions = instructions
        self.quickActions = quickActions
        self.features = features
    }

    /// How many suggestions there are to decide on.
    public var suggestionCount: Int { instructions.count + quickActions.count + features.count }

    public static let schema = Data(#"""
        {"type":"object","additionalProperties":false,
         "required":["observations","instructions","quick_actions","features"],
         "properties":{
          "observations":{"type":"array","items":{"type":"string"}},
          "instructions":{"type":"array","items":{"type":"object","additionalProperties":false,
            "required":["text","reason"],"properties":{"text":{"type":"string"},"reason":{"type":"string"}}}},
          "quick_actions":{"type":"array","items":{"type":"object","additionalProperties":false,
            "required":["name","prompt","reason"],
            "properties":{"name":{"type":"string"},"prompt":{"type":"string"},"reason":{"type":"string"}}}},
          "features":{"type":"array","items":{"type":"object","additionalProperties":false,
            "required":["title","description","reason"],
            "properties":{"title":{"type":"string"},"description":{"type":"string"},"reason":{"type":"string"}}}}
         }}
        """#.utf8)

    public static func decode(_ data: Data) throws -> SessionReview {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionReview.self, from: data)
    }

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
