import Foundation

/// Answers through Claude's Messages API, streaming the reply as it's written.
/// Swift has no official Anthropic SDK, so this speaks HTTP directly
/// (`URLSession`), following the API's documented request and event shapes.
public struct ClaudeProvider: AnswerProvider {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let defaultModel = "claude-sonnet-5-5"
    /// Room for thinking plus the reply; thinking counts toward it.
    static let maxTokens = 16000

    private let apiKey: @Sendable () throws -> String
    private let model: String
    private let effort: String
    private let thinkingOff: Bool
    private let session: URLSession
    /// The most requests one answer makes when Claude looks in the files.
    /// The last one asks Claude to answer with what it has.
    private let lookupRounds: Int

    /// - Parameters:
    ///   - effort: "low" keeps thinking short and skips it on most simple questions.
    ///   - thinkingOff: Sonnet 5.5's lowest thinking setting (`between_tools`);
    ///     `disabled` is rejected on this model.
    public init(
        apiKey: @escaping @Sendable () throws -> String = { try APIKeyStore.read() },
        model: String = defaultModel,
        effort: String = "low",
        thinkingOff: Bool = false,
        session: URLSession = .shared,
        lookupRounds: Int = 4
    ) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.thinkingOff = thinkingOff
        self.session = session
        self.lookupRounds = max(lookupRounds, 1)
    }

    /// Streams the answer. When the prompt has file tools and Claude calls
    /// them, runs them and asks again with the results, up to `lookupRounds`
    /// requests, sending Claude's own blocks back unchanged each time.
    public func answer(_ prompt: AnswerPrompt) -> AsyncThrowingStream<AnswerEvent, Error> {
        let apiKey = apiKey, model = model, effort = effort, thinkingOff = thinkingOff, session = session, rounds = lookupRounds
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Claude's tool calls and their results so far, as messages.
                    var turns: [[String: Any]] = []
                    var usage = Usage()
                    for round in 1...rounds {
                        let body = Self.requestBody(for: prompt, model: model, effort: effort, thinkingOff: thinkingOff,
                                                    turns: turns, lastRound: round == rounds)
                        let reply = try await Self.stream(Request(apiKey: apiKey, body: body), session: session) { continuation.yield($0) }
                        usage.add(reply.usage)
                        if let category = reply.declined {
                            continuation.yield(.declined(category: category))
                            break
                        }
                        let calls = reply.toolUses
                        guard reply.stopReason == "tool_use", let lookup = prompt.lookup, !calls.isEmpty, round < rounds else {
                            continuation.yield(.finished(stopReason: reply.stopReason, usage: usage))
                            break
                        }
                        turns.append(["role": "assistant", "content": reply.blocks])
                        var results: [[String: Any]] = []
                        for call in calls {
                            continuation.yield(.lookingUp(FileLookup.activity(name: call.name, input: call.input)))
                            let result = lookup.run(name: call.name, input: call.input)
                            var block: [String: Any] = ["type": "tool_result", "tool_use_id": call.id, "content": result.text]
                            if result.isError { block["is_error"] = true }
                            results.append(block)
                        }
                        // All results go back in one message, in the order of the calls.
                        turns.append(["role": "user", "content": results])
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func warm(_ prompt: AnswerPrompt) async throws -> Usage {
        var urlRequest = try Self.urlRequest(apiKey: apiKey(), body: Self.warmBody(for: prompt, model: model, effort: effort, thinkingOff: thinkingOff))
        // Writing a large cache takes a while; nothing streams back meanwhile.
        urlRequest.timeoutInterval = 120
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw Self.mapped(error)
        }
        let http = response as? HTTPURLResponse
        guard let http, http.statusCode == 200 else {
            throw Self.error(status: http?.statusCode ?? 0, body: data, retryAfter: http?.value(forHTTPHeaderField: "retry-after"))
        }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let usage = object?["usage"] as? [String: Any]
        return Usage(
            inputTokens: usage?["input_tokens"] as? Int ?? 0,
            outputTokens: usage?["output_tokens"] as? Int ?? 0,
            cacheReadTokens: usage?["cache_read_input_tokens"] as? Int ?? 0,
            cacheWriteTokens: usage?["cache_creation_input_tokens"] as? Int ?? 0
        )
    }

    static func urlRequest(apiKey: String, body: Data) -> URLRequest {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        // Needed for `fallbacks: "default"`.
        urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        urlRequest.httpBody = body
        return urlRequest
    }

    private struct Request: Sendable {
        let apiKey: @Sendable () throws -> String
        let body: Data
    }

    /// How one request ended.
    private struct Reply {
        var usage = Usage()
        var stopReason = "end_turn"
        /// Set when Claude declined, with the API's category (if any).
        var declined: String??
        var blocks: [[String: Any]] = []
        var toolUses: [(id: String, name: String, input: [String: Any])] = []
    }

    /// Streams one request, passing on text and returning how it ended.
    private static func stream(_ request: Request, session: URLSession, yield: (AnswerEvent) -> Void) async throws -> Reply {
        var urlRequest = urlRequest(apiKey: try request.apiKey(), body: request.body)
        // The longest wait allowed between two pieces of the reply.
        urlRequest.timeoutInterval = 60

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch {
            throw mapped(error)
        }
        let http = response as? HTTPURLResponse
        guard let http, http.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 64 * 1024 { break }
            }
            throw error(status: http?.statusCode ?? 0, body: body, retryAfter: http?.value(forHTTPHeaderField: "retry-after"))
        }

        var parser = ServerSentEvents()
        var reply: Reply?
        do {
            for try await line in bytes.lines {
                for event in try parser.consume(line: line) {
                    switch event {
                    case .text, .lookingUp:
                        yield(event)
                    case .finished(let stopReason, let usage):
                        reply = Reply(usage: usage, stopReason: stopReason)
                    case .declined(let category):
                        reply = Reply(usage: parser.usage, stopReason: "refusal", declined: .some(category))
                    }
                }
            }
        } catch let error as AnswerError {
            throw error
        } catch {
            throw mapped(error)
        }
        guard var reply else { throw AnswerError.badStream("the reply stopped before it finished") }
        reply.blocks = parser.blocks
        reply.toolUses = parser.toolUses
        return reply
    }

    private static func mapped(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return CancellationError() }
            return AnswerError.network(urlError.localizedDescription)
        }
        return AnswerError.network(error.localizedDescription)
    }

    /// The error to show for a failed HTTP response.
    static func error(status: Int, body: Data, retryAfter: String?) -> AnswerError {
        switch status {
        case 401, 403: return .keyRejected
        case 429: return .rateLimited(retryAfter: retryAfter.flatMap { Int($0) })
        case 529: return .overloaded
        default:
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let message = (object?["error"] as? [String: Any])?["message"] as? String
            return .http(status: status, message: message ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
    }

    /// The Messages API request body: one user turn holding the transcript
    /// blocks and then the question, under the system blocks.
    ///
    /// - Parameters:
    ///   - turns: Claude's tool calls and their results so far, sent after the
    ///     user turn.
    ///   - lastRound: no more tool calls; Claude answers with what it has.
    static func requestBody(for prompt: AnswerPrompt, model: String, effort: String, thinkingOff: Bool,
                            turns: [[String: Any]] = [], lastRound: Bool = false) -> Data {
        var body = body(for: prompt, model: model, effort: effort, thinkingOff: thinkingOff)
        body["stream"] = true
        if !turns.isEmpty { body["messages"] = (body["messages"] as? [[String: Any]] ?? []) + turns }
        if lastRound, prompt.lookup != nil { body["tool_choice"] = ["type": "none"] }
        return encoded(body)
    }

    /// A request that only writes the cache: `max_tokens` 0 (the API then
    /// stops after reading the prompt) and not streamed, which `max_tokens` 0
    /// doesn't allow. Everything else matches a real answer, since thinking
    /// and effort are part of what's cached.
    static func warmBody(for prompt: AnswerPrompt, model: String, effort: String, thinkingOff: Bool) -> Data {
        var body = body(for: prompt, model: model, effort: effort, thinkingOff: thinkingOff)
        body["max_tokens"] = 0
        return encoded(body)
    }

    private static func body(for prompt: AnswerPrompt, model: String, effort: String, thinkingOff: Bool) -> [String: Any] {
        func block(_ block: PromptBlock) -> [String: Any] {
            var json: [String: Any] = ["type": "text", "text": block.text]
            if block.cacheBreakpoint {
                json["cache_control"] = block.cachesForAnHour ? ["type": "ephemeral", "ttl": "1h"] : ["type": "ephemeral"]
            }
            return json
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "output_config": ["effort": effort],
            // On a decline in some categories, the API retries on an older model.
            "fallbacks": "default",
            "system": prompt.system.map(block),
            "messages": [[
                "role": "user",
                "content": prompt.transcript.map(block) + [block(PromptBlock(text: prompt.question))],
            ]],
        ]
        if thinkingOff { body["thinking"] = ["type": "between_tools"] }
        // Tools come first in what's cached, so they're sent the same way every time.
        if prompt.lookup != nil { body["tools"] = FileLookup.definitions }
        return body
    }

    /// Sorted keys: the same prompt always produces the same bytes.
    private static func encoded(_ body: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }
}
