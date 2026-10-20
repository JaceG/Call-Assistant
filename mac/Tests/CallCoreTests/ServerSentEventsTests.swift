@testable import CallCore
import Foundation
import Testing

/// Streams shaped like the Messages API's (`stream: true`), fed line by line.
struct ServerSentEventsTests {
    static func events(_ lines: [String]) throws -> [AnswerEvent] {
        var parser = ServerSentEvents()
        return try lines.flatMap { try parser.consume(line: $0) }
    }

    static let start = #"data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":812,"cache_creation_input_tokens":0,"cache_read_input_tokens":640,"output_tokens":1}}}"#
    static let stop = #"data: {"type":"message_stop"}"#

    @Test func aPlainAnswerComesThroughAsTextThenFinished() throws {
        let events = try Self.events([
            "event: message_start",
            Self.start,
            "",
            "event: content_block_start",
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            "event: ping",
            #"data: {"type":"ping"}"#,
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"A mutex lets "}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"one thread in at a time."}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":14}}"#,
            Self.stop,
        ])
        #expect(events == [
            .text("A mutex lets "),
            .text("one thread in at a time."),
            .finished(stopReason: "end_turn", usage: Usage(inputTokens: 812, outputTokens: 14, cacheReadTokens: 640, cacheWriteTokens: 0)),
        ])
    }

    @Test func anEmptyThinkingBlockFirstIsSkipped() throws {
        let events = try Self.events([
            Self.start,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQBCkYIBxgCKkA"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Yes."}}"#,
            #"data: {"type":"content_block_stop","index":1}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":40}}"#,
            Self.stop,
        ])
        #expect(events.first == .text("Yes."))
        #expect(events.count == 2)
    }

    @Test func aRefusalIsReportedAsDeclinedWithItsCategory() throws {
        let events = try Self.events([
            Self.start,
            #"data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":null}},"usage":{"output_tokens":0}}"#,
            Self.stop,
        ])
        #expect(events == [.declined(category: "cyber")])
    }

    @Test func anErrorEventMidStreamThrows() throws {
        var parser = ServerSentEvents()
        _ = try parser.consume(line: Self.start)
        _ = try parser.consume(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Partly"}}"#)
        #expect(throws: AnswerError.overloaded) {
            try parser.consume(line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        }
    }

    @Test func unknownBlocksAndEventsAreIgnored() throws {
        let events = try Self.events([
            Self.start,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"fallback","from":{"model":"claude-sonnet-5-5"},"to":{"model":"claude-sonnet-5"}}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"some_future_event","value":1}"#,
            ": a comment line",
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Still here."}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#,
            Self.stop,
        ])
        #expect(events.first == .text("Still here."))
        #expect(events.count == 2)
    }

    @Test func aBrokenDataLineThrows() {
        var parser = ServerSentEvents()
        #expect(throws: AnswerError.self) {
            try parser.consume(line: "data: {not json")
        }
    }

    /// A reply that calls a tool: the blocks are rebuilt exactly, so they can
    /// be sent back (thinking with its signature, the tool's input as JSON).
    @Test func aToolCallsBlocksAreRebuiltFromTheirDeltas() throws {
        var parser = ServerSentEvents()
        for line in [
            Self.start,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQBCkYIARgC"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01","name":"search_files","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"echo"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" cancel\"}"}}"#,
            #"data: {"type":"content_block_stop","index":1}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":40}}"#,
            Self.stop,
        ] { _ = try parser.consume(line: line) }

        #expect(parser.stopReason == "tool_use")
        #expect(parser.blocks.count == 2)
        #expect(NSDictionary(dictionary: parser.blocks[0]).isEqual(to: ["type": "thinking", "thinking": "", "signature": "EqQBCkYIARgC"]))
        #expect(NSDictionary(dictionary: parser.blocks[1]).isEqual(to: [
            "type": "tool_use", "id": "toolu_01", "name": "search_files", "input": ["query": "echo cancel"],
        ]))
        let calls = parser.toolUses
        #expect(calls.map(\.id) == ["toolu_01"])
        #expect(calls.first?.input["query"] as? String == "echo cancel")
    }

    @Test func textIsKeptInItsBlockToo() throws {
        var parser = ServerSentEvents()
        for line in [
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me "}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"check."}}"#,
        ] { _ = try parser.consume(line: line) }
        #expect(parser.blocks.first?["text"] as? String == "Let me check.")
    }
}
