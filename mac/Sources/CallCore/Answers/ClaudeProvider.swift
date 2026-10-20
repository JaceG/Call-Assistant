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

    /// - Parameters:
    ///   - effort: "low" keeps thinking short and skips it on most simple questions.
    ///   - thinkingOff: Sonnet 5.5's lowest thinking setting (`between_tools`);
    ///     `disabled` is rejected on this model.
    public init(
        apiKey: @escaping @Sendable () throws -> String = { try APIKeyStore.read() },
        model: String = defaultModel,
        effort: String = "low",
        thinkingOff: Bool = false,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.thinkingOff = thinkingOff
        self.session = session
    }

    public func answer(_ prompt: AnswerPrompt) -> AsyncThrowingStream<AnswerEvent, Error> {
        let request = Request(apiKey: apiKey, body: Self.requestBody(for: prompt, model: model, effort: effort, thinkingOff: thinkingOff))
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.stream(request, session: session) { continuation.yield($0) }
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

    private static func stream(_ request: Request, session: URLSession, yield: (AnswerEvent) -> Void) async throws {
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
        var ended = false
        do {
            for try await line in bytes.lines {
                for event in try parser.consume(line: line) {
                    if case .text = event {} else { ended = true }
                    yield(event)
                }
            }
        } catch let error as AnswerError {
            throw error
        } catch {
            throw mapped(error)
        }
        guard ended else { throw AnswerError.badStream("the reply stopped before it finished") }
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
    static func requestBody(for prompt: AnswerPrompt, model: String, effort: String, thinkingOff: Bool) -> Data {
        var body = body(for: prompt, model: model, effort: effort, thinkingOff: thinkingOff)
        body["stream"] = true
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
        return body
    }

    /// Sorted keys: the same prompt always produces the same bytes.
    private static func encoded(_ body: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }
}
