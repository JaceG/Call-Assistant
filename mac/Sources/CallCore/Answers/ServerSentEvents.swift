import Foundation

/// Reads the Messages API's streamed reply one line at a time. Each `data:`
/// line holds one complete JSON event, so lines are parsed on their own and
/// `event:` lines, comments and blank lines are skipped.
struct ServerSentEvents {
    private var usage = Usage()
    private var stopReason: String?
    private var refusalCategory: String?

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
        case "content_block_delta":
            // Only text is shown; thinking and signature deltas are skipped.
            let delta = event["delta"] as? [String: Any]
            if delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String, !text.isEmpty {
                return [.text(text)]
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
            // ping, content_block_start/stop, and event types added later.
            break
        }
        return []
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
