import Foundation

/// Reads the Messages API's streamed reply one line at a time. Each `data:`
/// line holds one complete JSON event, so lines are parsed on their own and
/// `event:` lines, comments and blank lines are skipped.
struct ServerSentEvents {
    private(set) var usage = Usage()
    private(set) var stopReason: String?
    private var refusalCategory: String?
    /// The reply's content blocks as the API sent them (thinking with its
    /// signature, text, tool_use with its input), rebuilt from the deltas so
    /// they can be sent back unchanged when Claude uses a tool.
    private(set) var blocks: [[String: Any]] = []
    /// A tool_use block's input arrives as pieces of JSON text.
    private var toolInputs: [Int: String] = [:]

    /// The answer events this line carries (most carry none).
    mutating func consume(line: String) throws -> [AnswerEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let json = line.dropFirst("data:".count).drop { $0 == " " }
        guard let event = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw AnswerError.badStream("not JSON: \(json.prefix(80))")
        }

        switch event["type"] as? String {
        case "message_start":
            let message = event["message"] as? [String: Any]
            read(usage: message?["usage"] as? [String: Any])
        case "content_block_start":
            if let block = event["content_block"] as? [String: Any] {
                blocks.append(block)
                if block["type"] as? String == "tool_use" { toolInputs[blocks.count - 1] = "" }
            }
        case "content_block_delta":
            // Only text is shown; the rest is kept for sending back.
            let delta = event["delta"] as? [String: Any]
            let index = event["index"] as? Int ?? blocks.count - 1
            switch delta?["type"] as? String {
            case "text_delta":
                let text = delta?["text"] as? String ?? ""
                append(text, to: "text", at: index)
                if !text.isEmpty { return [.text(text)] }
            case "thinking_delta":
                append(delta?["thinking"] as? String ?? "", to: "thinking", at: index)
            case "signature_delta":
                append(delta?["signature"] as? String ?? "", to: "signature", at: index)
            case "input_json_delta":
                toolInputs[index, default: ""] += delta?["partial_json"] as? String ?? ""
            default:
                break
            }
        case "content_block_stop":
            let index = event["index"] as? Int ?? blocks.count - 1
            if let json = toolInputs[index], blocks.indices.contains(index) {
                let input = json.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
                guard let input else { throw AnswerError.badStream("a tool's input wasn't JSON") }
                blocks[index]["input"] = input
            }
        case "message_delta":
            let delta = event["delta"] as? [String: Any]
            if let reason = delta?["stop_reason"] as? String { stopReason = reason }
            let details = (delta?["stop_details"] ?? event["stop_details"]) as? [String: Any]
            if let category = details?["category"] as? String { refusalCategory = category }
            read(usage: event["usage"] as? [String: Any])
        case "message_stop":
            if stopReason == "refusal" { return [.declined(category: refusalCategory)] }
            return [.finished(stopReason: stopReason ?? "end_turn", usage: usage)]
        case "error":
            let error = event["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "unknown error"
            switch error?["type"] as? String {
            case "overloaded_error": throw AnswerError.overloaded
            case "rate_limit_error": throw AnswerError.rateLimited(retryAfter: nil)
            default: throw AnswerError.badStream(message)
            }
        default:
            // ping, and event types added later.
            break
        }
        return []
    }

    private mutating func append(_ piece: String, to field: String, at index: Int) {
        guard blocks.indices.contains(index) else { return }
        blocks[index][field] = (blocks[index][field] as? String ?? "") + piece
    }

    /// The tool calls in the reply: their id, tool name and input.
    var toolUses: [(id: String, name: String, input: [String: Any])] {
        blocks.compactMap { block in
            guard block["type"] as? String == "tool_use", let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
            return (id, name, block["input"] as? [String: Any] ?? [:])
        }
    }

    /// Takes whichever counts this usage object reports; later events repeat
    /// or update earlier ones.
    private mutating func read(usage object: [String: Any]?) {
        guard let object else { return }
        if let n = object["input_tokens"] as? Int { usage.inputTokens = n }
        if let n = object["output_tokens"] as? Int { usage.outputTokens = n }
        if let n = object["cache_read_input_tokens"] as? Int { usage.cacheReadTokens = n }
        if let n = object["cache_creation_input_tokens"] as? Int { usage.cacheWriteTokens = n }
    }
}
