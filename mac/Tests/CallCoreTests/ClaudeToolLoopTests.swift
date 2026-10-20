@testable import CallCore
import Foundation
import os
import Testing

/// Answers each request with the next canned reply and keeps the bodies sent.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Script {
        var replies: [String] = []
        var bodies: [Data] = []
    }

    static let script = OSAllocatedUnfairLock(initialState: Script())

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset(replies: [String]) {
        script.withLock { $0 = Script(replies: replies) }
    }

    /// The JSON bodies sent so far.
    static var bodies: [[String: Any]] {
        script.withLock { $0.bodies }.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let sent = body
        let reply = Self.script.withLock { script -> String in
            script.bodies.append(sent)
            return script.replies.isEmpty ? "" : script.replies.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["content-type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Look-up answers: Claude calls a file tool, the provider runs it and asks
/// again with Claude's own blocks and the results.
@Suite(.serialized)
struct ClaudeToolLoopTests {
    static func sse(_ events: [String]) -> String {
        events.map { "data: \($0)\n\n" }.joined()
    }

    static let searchReply = sse([
        #"{"type":"message_start","message":{"usage":{"input_tokens":100,"cache_read_input_tokens":50,"output_tokens":1}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-1"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01","name":"search_files","input":{}}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"terminal\"}"}}"#,
        #"{"type":"content_block_stop","index":1}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":40}}"#,
        #"{"type":"message_stop"}"#,
    ])

    static let textReply = sse([
        #"{"type":"message_start","message":{"usage":{"input_tokens":200,"cache_read_input_tokens":50,"output_tokens":1}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"From the code."}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":10}}"#,
        #"{"type":"message_stop"}"#,
    ])

    static let prompt = AnswerPrompt(system: [PromptBlock(text: "Base.", cacheBreakpoint: true)], transcript: [],
                                     question: "How did you build the terminal?", lookup: FileLookupTests.lookup)

    static func answer(rounds: Int = 4) async throws -> [AnswerEvent] {
        let provider = ClaudeProvider(apiKey: { "test-key" }, session: StubProtocol.session, lookupRounds: rounds)
        var events: [AnswerEvent] = []
        for try await event in provider.answer(prompt) { events.append(event) }
        return events
    }

    @Test func aToolCallIsRunAndAnsweredInASecondRequest() async throws {
        StubProtocol.reset(replies: [Self.searchReply, Self.textReply])
        let events = try await Self.answer()
        #expect(events == [
            .lookingUp("Searching the files for \u{201C}terminal\u{201D}…"),
            .text("From the code."),
            .finished(stopReason: "end_turn", usage: Usage(inputTokens: 300, outputTokens: 50, cacheReadTokens: 100, cacheWriteTokens: 0)),
        ])

        let bodies = StubProtocol.bodies
        #expect(bodies.count == 2)
        #expect((bodies[0]["tools"] as? [[String: Any]])?.map { $0["name"] as? String } == ["search_files", "read_file"])
        #expect(bodies[0]["tool_choice"] == nil)
        #expect((bodies[0]["messages"] as? [Any])?.count == 1)

        let messages = try #require(bodies[1]["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let sentBack = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(NSDictionary(dictionary: sentBack[0]).isEqual(to: ["type": "thinking", "thinking": "", "signature": "sig-1"]))
        #expect(NSDictionary(dictionary: sentBack[1]).isEqual(to: [
            "type": "tool_use", "id": "toolu_01", "name": "search_files", "input": ["query": "terminal"],
        ]))
        let results = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(results.count == 1)
        #expect(results[0]["type"] as? String == "tool_result")
        #expect(results[0]["tool_use_id"] as? String == "toolu_01")
        #expect((results[0]["content"] as? String)?.contains("Site/README.md:2: The terminal opens") == true)
        #expect(results[0]["is_error"] == nil)
        #expect(bodies[1]["tool_choice"] == nil)
    }

    @Test func theLastRoundAsksForAnAnswerWithoutTools() async throws {
        StubProtocol.reset(replies: [Self.searchReply, Self.textReply])
        _ = try await Self.answer(rounds: 2)
        let bodies = StubProtocol.bodies
        #expect(bodies.count == 2)
        #expect(bodies[1]["tool_choice"] as? [String: String] == ["type": "none"])
        // The tools stay listed: the earlier turn used one.
        #expect((bodies[1]["tools"] as? [Any])?.count == 2)
    }

    @Test func withoutFileToolsNoToolsAreSent() throws {
        let plain = AnswerPrompt(system: [PromptBlock(text: "Base.")], transcript: [], question: "Hi?")
        let data = ClaudeProvider.requestBody(for: plain, model: "claude-sonnet-5-5", effort: "low", thinkingOff: false, lastRound: true)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["tools"] == nil)
        #expect(body["tool_choice"] == nil)
    }
}
