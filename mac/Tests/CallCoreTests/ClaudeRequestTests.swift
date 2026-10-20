@testable import CallCore
import Foundation
import Testing

/// The JSON body sent to the Messages API.
struct ClaudeRequestTests {
    static let prompt = AnswerPrompt(
        system: [
            PromptBlock(text: "You help Jace on calls."),
            PromptBlock(text: "# Playbook: General\nKeep it short.", cacheBreakpoint: true),
        ],
        transcript: [
            PromptBlock(text: "[10:00:01] Them: Hello.", cacheBreakpoint: true),
            PromptBlock(text: "[10:00:09] Them: How do you cache?"),
        ],
        question: "Help me respond to what they just said."
    )

    static func body(thinkingOff: Bool = false, prompt: AnswerPrompt = prompt) throws -> [String: Any] {
        let data = ClaudeProvider.requestBody(for: prompt, model: "claude-sonnet-5-5", effort: "low", thinkingOff: thinkingOff)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func streamsSonnetAtLowEffortWithDefaultFallbacks() throws {
        let body = try Self.body()
        #expect(body["model"] as? String == "claude-sonnet-5-5")
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_tokens"] as? Int == 16000)
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "low")
        #expect(body["fallbacks"] as? String == "default")
        #expect(body["thinking"] == nil)
    }

    @Test func turnsThinkingOffOnlyWhenAsked() throws {
        let body = try Self.body(thinkingOff: true)
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "between_tools")
        #expect((body["thinking"] as? [String: Any])?.count == 1)
    }

    @Test func systemBlocksCarryTheirCacheBreakpoint() throws {
        let system = try #require(try Self.body()["system"] as? [[String: Any]])
        #expect(system.count == 2)
        #expect(system.map { $0["text"] as? String } == ["You help Jace on calls.", "# Playbook: General\nKeep it short."])
        #expect(system[0]["cache_control"] == nil)
        #expect((system[1]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    }

    @Test func anHourLongBreakpointAsksForAnHourLongCache() throws {
        let prompt = AnswerPrompt(system: [
            PromptBlock(text: "Base."),
            PromptBlock(text: "# Files for this call", cacheBreakpoint: true, cachesForAnHour: true),
            PromptBlock(text: "# Notes for this call", cacheBreakpoint: true),
        ], transcript: [], question: "Hi?")
        let system = try #require(try Self.body(prompt: prompt)["system"] as? [[String: Any]])
        #expect(system[1]["cache_control"] as? [String: String] == ["type": "ephemeral", "ttl": "1h"])
        #expect(system[2]["cache_control"] as? [String: String] == ["type": "ephemeral"])
    }

    @Test func aWarmRequestIsTheSameButStopsBeforeAnswering() throws {
        let data = ClaudeProvider.warmBody(for: Self.prompt, model: "claude-sonnet-5-5", effort: "low", thinkingOff: false)
        var warm = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var real = try Self.body()
        #expect(warm["max_tokens"] as? Int == 0)
        #expect(warm["stream"] == nil)
        warm["max_tokens"] = nil
        real["max_tokens"] = nil
        real["stream"] = nil
        #expect(NSDictionary(dictionary: warm).isEqual(to: real))
    }

    @Test func oneUserTurnHoldsTheTranscriptThenTheQuestion() throws {
        let messages = try #require(try Self.body()["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["text", "text", "text"])
        #expect(content.map { $0["text"] as? String } == [
            "[10:00:01] Them: Hello.", "[10:00:09] Them: How do you cache?", "Help me respond to what they just said.",
        ])
        #expect((content[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect(content[1]["cache_control"] == nil)
        #expect(content[2]["cache_control"] == nil)
    }

    @Test func withNoTranscriptOnlyTheQuestionIsSent() throws {
        let prompt = AnswerPrompt(system: [PromptBlock(text: "Base.")], transcript: [], question: "What is a mutex?")
        let messages = try #require(try Self.body(prompt: prompt)["messages"] as? [[String: Any]])
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content.map { $0["text"] as? String } == ["What is a mutex?"])
    }

    @Test func httpStatusesBecomeClearErrors() {
        #expect(ClaudeProvider.error(status: 401, body: Data(), retryAfter: nil) == .keyRejected)
        #expect(ClaudeProvider.error(status: 429, body: Data(), retryAfter: "12") == .rateLimited(retryAfter: 12))
        #expect(ClaudeProvider.error(status: 529, body: Data(), retryAfter: nil) == .overloaded)
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: too big"}}"#.utf8)
        #expect(ClaudeProvider.error(status: 400, body: body, retryAfter: nil) == .http(status: 400, message: "max_tokens: too big"))
    }
}
