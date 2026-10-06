import Foundation

nonisolated struct OpenRouterError: LocalizedError, Sendable {
    enum Kind: Sendable {
        case missingKey, invalidKey, noCredits, rateLimited, badRequest, server, network, timeout, invalidResponse
    }

    let kind: Kind
    let message: String
    var retryAfter: Double?

    var errorDescription: String? { message }

    var isRetryable: Bool {
        switch kind {
        case .rateLimited, .server, .network, .timeout, .invalidResponse: true
        case .missingKey, .invalidKey, .noCredits, .badRequest: false
        }
    }

    static let missingKey = OpenRouterError(kind: .missingKey, message: "Add your OpenRouter API key in Settings › AI.")
}

nonisolated enum Retry {
    /// Retries transient failures (network, rate limits, server errors, malformed output) with backoff.
    /// Rate limits get more patience: preview speech-to-text endpoints throttle bursts.
    static func run<T: Sendable>(_ attempts: Int = 7, _ operation: @Sendable () async throws -> T) async throws -> T {
        var delay = 2.0
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch let error as OpenRouterError where error.isRetryable && attempt < attempts {
                let wait = max(error.retryAfter ?? 0, error.kind == .rateLimited ? max(delay, 3) : delay)
                Log.warn("Attempt \(attempt) failed (\(error.message)); retrying in \(Int(wait)) s", "ai")
                try await Task.sleep(for: .seconds(wait))
                delay = min(delay * 2, 30)
                attempt += 1
            }
        }
    }
}

nonisolated struct ChatResult: Sendable {
    let content: String
    let cost: Double
    let model: String?
    let provider: String?
    let promptTokens: Int
    let completionTokens: Int
    let seconds: Double
}

nonisolated struct ORModel: Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let inputModalities: [String]
    let outputModalities: [String]
    let promptPrice: Double      // USD per 1M tokens
    let completionPrice: Double  // USD per 1M tokens
    let audioPrice: Double       // USD per 1M audio tokens (0 = billed as prompt tokens)
    let contextLength: Int

    var acceptsAudio: Bool { inputModalities.contains("audio") }
    var producesText: Bool { outputModalities.contains("text") }
    /// Dedicated speech-to-text models (served by /audio/transcriptions).
    var isSpeechToText: Bool { outputModalities.contains("transcription") }
}

/// Minimal client for OpenRouter's OpenAI-compatible API.
nonisolated struct OpenRouterClient: Sendable {
    static let base = URL(string: "https://openrouter.ai/api/v1")!
    let apiKey: String

    static func fromKeychain() throws -> OpenRouterClient {
        guard let key = Keychain.openRouterKey, !key.isEmpty else { throw OpenRouterError.missingKey }
        return OpenRouterClient(apiKey: key)
    }

    /// POST /chat/completions with a prebuilt JSON body.
    func chat(_ body: Data, timeout: TimeInterval = 180) async throws -> ChatResult {
        var request = URLRequest(url: Self.base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = body
        authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let started = Date()
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.error(status: status, data: data, response: response) }

        let decoded: ChatResponse
        do {
            decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw OpenRouterError(kind: .invalidResponse, message: "Unreadable response from OpenRouter: \(error.localizedDescription)")
        }
        if let apiError = decoded.error ?? decoded.choices?.first?.error {
            throw Self.error(status: apiError.code ?? 500, message: apiError.message ?? "Provider error")
        }
        guard let content = decoded.choices?.first?.message?.content?.text, !content.isEmpty else {
            let reason = decoded.choices?.first?.finish_reason ?? "empty"
            throw OpenRouterError(kind: .invalidResponse, message: "The model returned no content (\(reason)).")
        }
        return ChatResult(content: content,
                          cost: decoded.usage?.cost ?? 0,
                          model: decoded.model,
                          provider: decoded.provider,
                          promptTokens: decoded.usage?.prompt_tokens ?? 0,
                          completionTokens: decoded.usage?.completion_tokens ?? 0,
                          seconds: Date().timeIntervalSince(started))
    }

    /// POST /audio/transcriptions (dedicated speech-to-text models) with a prebuilt JSON body.
    func transcription(_ body: Data, timeout: TimeInterval = 120) async throws -> STTResponse {
        var request = URLRequest(url: Self.base.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = body
        authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.error(status: status, data: data, response: response) }
        do {
            return try JSONDecoder().decode(STTResponse.self, from: data)
        } catch {
            throw OpenRouterError(kind: .invalidResponse, message: "Unreadable transcription response: \(error.localizedDescription)")
        }
    }

    /// GET /key — validates the key and returns a short description of its limits/usage.
    func checkKey() async throws -> String {
        var request = URLRequest(url: Self.base.appendingPathComponent("key"))
        request.timeoutInterval = 20
        authorize(&request)
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.error(status: status, data: data, response: response) }
        struct KeyInfo: Decodable {
            struct Inner: Decodable { let label: String?; let usage: Double?; let limit: Double?; let limit_remaining: Double? }
            let data: Inner
        }
        guard let info = try? JSONDecoder().decode(KeyInfo.self, from: data) else { return "Key is valid." }
        var parts = ["Key is valid"]
        if let usage = info.data.usage { parts.append(String(format: "used $%.2f", usage)) }
        if let remaining = info.data.limit_remaining { parts.append(String(format: "$%.2f left on this key", remaining)) }
        return parts.joined(separator: " · ") + "."
    }

    /// Public model catalog (no key needed), including speech-to-text models, which the default
    /// listing leaves out.
    static func models() async throws -> [ORModel] {
        let chat = try await models(query: nil)
        let stt = (try? await models(query: "output_modalities=transcription")) ?? []
        let known = Set(chat.map(\.id))
        return chat + stt.filter { !known.contains($0.id) }
    }

    private static func models(query: String?) async throws -> [ORModel] {
        var components = URLComponents(url: base.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        components.query = query
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: request)
        struct List: Decodable {
            struct Model: Decodable {
                struct Arch: Decodable { let input_modalities: [String]?; let output_modalities: [String]? }
                struct Pricing: Decodable { let prompt: String?; let completion: String?; let audio: String? }
                let id: String
                let name: String?
                let context_length: Int?
                let architecture: Arch?
                let pricing: Pricing?
            }
            let data: [Model]
        }
        let list = try JSONDecoder().decode(List.self, from: data)
        func perMillion(_ s: String?) -> Double { (Double(s ?? "0") ?? 0) * 1_000_000 }
        return list.data.map {
            ORModel(id: $0.id, name: $0.name ?? $0.id,
                    inputModalities: $0.architecture?.input_modalities ?? [],
                    outputModalities: $0.architecture?.output_modalities ?? [],
                    promptPrice: perMillion($0.pricing?.prompt),
                    completionPrice: perMillion($0.pricing?.completion),
                    audioPrice: perMillion($0.pricing?.audio),
                    contextLength: $0.context_length ?? 0)
        }
    }

    /// Provider routing: zero-data-retention endpoints only and no training on prompts. When nobody is
    /// waiting (chunks transcribed during a call), Google's flex tier is tried first: half the price,
    /// ~10 s slower, falls back to the standard tier. Default routing never picks flex by itself.
    ///
    /// Not `require_parameters`: it rejects every endpoint that ignores any one parameter (e.g.
    /// `temperature` on GPT-6), which leaves no endpoint at all.
    static func providerPreferences(zeroRetention: Bool, urgent: Bool) -> [String: Any] {
        var provider: [String: Any] = ["data_collection": "deny"]
        if zeroRetention { provider["zdr"] = true }
        if urgent {
            provider["sort"] = "latency"
        } else {
            provider["order"] = ["google-vertex/global/flex", "google-ai-studio/flex"]
            provider["allow_fallbacks"] = true
        }
        return provider
    }

    // MARK: - Internals

    private func authorize(_ request: inout URLRequest) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("https://github.com/refifauzan/minutes", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Minutes", forHTTPHeaderField: "X-Title")
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw OpenRouterError(kind: .timeout, message: "OpenRouter took too long to answer.")
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw OpenRouterError(kind: .network, message: "Network error: \(error.localizedDescription)")
        }
    }

    private static func error(status: Int, data: Data, response: URLResponse) -> OpenRouterError {
        struct Envelope: Decodable { let error: APIError? }
        let apiError = (try? JSONDecoder().decode(Envelope.self, from: data))?.error
        let message = apiError?.message ?? String(data: data.prefix(300), encoding: .utf8) ?? "HTTP \(status)"
        var error = Self.error(status: status, message: message)
        if let seconds = apiError?.retryAfter {
            error.retryAfter = seconds
        } else if let retry = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(retry) {
            error.retryAfter = seconds
        }
        return error
    }

    private static func error(status: Int, message: String) -> OpenRouterError {
        switch status {
        case 401, 403: OpenRouterError(kind: .invalidKey, message: "OpenRouter rejected the API key: \(message)")
        case 402: OpenRouterError(kind: .noCredits, message: "OpenRouter credits are exhausted: \(message)")
        case 408: OpenRouterError(kind: .timeout, message: message)
        case 429: OpenRouterError(kind: .rateLimited, message: "Rate limited: \(message)")
        case 400, 404, 413, 422: OpenRouterError(kind: .badRequest, message: message)
        default: OpenRouterError(kind: .server, message: "OpenRouter error \(status): \(message)")
        }
    }
}

// MARK: - Response decoding

nonisolated struct APIError: Decodable, Sendable {
    let code: Int?
    let message: String?
    /// Upstream rate limits report their wait in metadata.retry_after_seconds.
    let retryAfter: Double?

    enum CodingKeys: String, CodingKey { case code, message, metadata }
    struct Metadata: Decodable { let retry_after_seconds: Double? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = try? c.decode(String.self, forKey: .message)
        if let int = try? c.decode(Int.self, forKey: .code) {
            code = int
        } else if let string = try? c.decode(String.self, forKey: .code) {
            code = Int(string)
        } else {
            code = nil
        }
        retryAfter = (try? c.decode(Metadata.self, forKey: .metadata))?.retry_after_seconds
    }
}

/// Response of /audio/transcriptions with `verbose_json`.
nonisolated struct STTResponse: Decodable, Sendable {
    struct Segment: Decodable, Sendable {
        let start: Double?
        let end: Double?
        let text: String?
        let speaker: SpeakerID?
    }
    struct Word: Decodable, Sendable {
        let word: String?
        let start: Double?
        let end: Double?
        let speaker: SpeakerID?
    }
    struct Usage: Decodable, Sendable {
        let seconds: Double?
        let cost: Double?
    }
    let text: String?
    let language: String?
    let duration: Double?
    let segments: [Segment]?
    let words: [Word]?
    let usage: Usage?
}

/// Providers label speakers with numbers or strings.
nonisolated struct SpeakerID: Decodable, Sendable, Hashable {
    let value: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let int = try? c.decode(Int.self) { value = String(int) } else { value = (try? c.decode(String.self)) ?? "?" }
    }
}

private nonisolated struct ChatResponse: Decodable {
    struct Choice: Decodable {
        let message: Message?
        let finish_reason: String?
        let error: APIError?
    }
    struct Message: Decodable { let content: Content? }
    struct Usage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let cost: Double?
    }
    let model: String?
    let provider: String?
    let choices: [Choice]?
    let usage: Usage?
    let error: APIError?
}

/// Message content is usually a string, but some providers return an array of parts.
private nonisolated struct Content: Decodable {
    let text: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            text = string
            return
        }
        struct Part: Decodable { let type: String?; let text: String? }
        let parts = (try? container.decode([Part].self)) ?? []
        text = parts.compactMap(\.text).joined()
    }
}
