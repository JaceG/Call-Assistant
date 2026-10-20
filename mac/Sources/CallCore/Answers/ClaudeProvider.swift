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

    private struct Request: Sendable {
        let apiKey: @Sendable () throws -> String
        let body: Data
    }

    private static func stream(_ request: Request, session: URLSession, yield: (AnswerEvent) -> Void) async throws {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(try request.apiKey(), forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        // Needed for `fallbacks: "default"`.
        urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        urlRequest.httpBody = request.body
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
        func block(_ block: PromptBlock) -> [String: Any] {
            var json: [String: Any] = ["type": "text", "text": block.text]
            if block.cacheBreakpoint { json["cache_control"] = ["type": "ephemeral"] }
            return json
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
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
        // Sorted keys: the same prompt always produces the same bytes.
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }
}
