import Foundation

public enum DirectProviderError: Error, Equatable, LocalizedError {
    case invalidRoute
    case missingCredential
    case requestTooLarge
    case transport
    case rejected(statusCode: Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidRoute: "The approved provider address or model is invalid."
        case .missingCredential: "This provider requires an API key on this iPad."
        case .requestTooLarge: "The approved provider request is too large."
        case .transport: "The provider could not be reached. The request remains available to retry."
        case let .rejected(statusCode): "The provider rejected the request (HTTP \(statusCode))."
        case .invalidResponse: "The provider returned an unsupported response."
        }
    }
}

/// A direct, non-caching provider transport. It intentionally exposes only validated text and
/// bounded usage metadata; response bodies never enter error descriptions or logs.
public final class DirectProviderClient: ProviderClient, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 180
            self.session = URLSession(configuration: configuration)
        }
    }

    public func performText(
        _ request: ProviderTextRequest,
        route: AIProviderRouteSnapshot,
        apiKey: String?
    ) async throws -> ProviderTextResponse {
        guard request.prompt.utf8.count <= 2_000_000 else {
            throw DirectProviderError.requestTooLarge
        }
        var urlRequest = try makeRequest(request, route: route, apiKey: apiKey)
        urlRequest.httpBody = try requestBody(request, route: route)
        guard (urlRequest.httpBody?.count ?? 0) <= 2_200_000 else {
            throw DirectProviderError.requestTooLarge
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DirectProviderError.transport
        }
        guard let http = response as? HTTPURLResponse else {
            throw DirectProviderError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw DirectProviderError.rejected(statusCode: http.statusCode)
        }
        guard data.count <= 8_000_000 else { throw DirectProviderError.invalidResponse }
        return try parse(data, route: route, requestId: http.value(forHTTPHeaderField: "x-request-id"))
    }

    private func makeRequest(
        _ request: ProviderTextRequest,
        route: AIProviderRouteSnapshot,
        apiKey: String?
    ) throws -> URLRequest {
        guard route.capabilities.contains(.text),
              !route.textModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let baseURL = Self.validatedBaseURL(route.baseURL)
        else { throw DirectProviderError.invalidRoute }

        let endpoint: URL
        switch route.adapter {
        case .openAIResponses:
            guard let apiKey, !apiKey.isEmpty else { throw DirectProviderError.missingCredential }
            endpoint = baseURL.appending(path: "responses")
        case .openAICompatible:
            endpoint = baseURL.appending(path: "chat/completions")
        case .anthropicMessages:
            guard let apiKey, !apiKey.isEmpty else { throw DirectProviderError.missingCredential }
            endpoint = baseURL.appending(path: "messages")
        case .geminiGenerateContent:
            guard let apiKey, !apiKey.isEmpty else { throw DirectProviderError.missingCredential }
            endpoint = baseURL
                .appending(path: "models")
                .appending(path: route.textModel)
                .appending(path: ":generateContent")
        }

        var result = URLRequest(url: endpoint)
        result.httpMethod = "POST"
        result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        result.setValue("application/json", forHTTPHeaderField: "Accept")
        switch route.adapter {
        case .openAIResponses, .openAICompatible:
            if let apiKey, !apiKey.isEmpty {
                result.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        case .anthropicMessages:
            result.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            result.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .geminiGenerateContent:
            result.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        return result
    }

    private func requestBody(
        _ request: ProviderTextRequest,
        route: AIProviderRouteSnapshot
    ) throws -> Data {
        let object: [String: Any]
        switch route.adapter {
        case .openAIResponses:
            var value: [String: Any] = [
                "model": route.textModel,
                "input": request.prompt,
                "max_output_tokens": request.maximumOutputTokens,
            ]
            if let instructions = request.systemInstructions { value["instructions"] = instructions }
            object = value
        case .openAICompatible:
            var messages: [[String: String]] = []
            if let instructions = request.systemInstructions {
                messages.append(["role": "system", "content": instructions])
            }
            messages.append(["role": "user", "content": request.prompt])
            object = [
                "model": route.textModel,
                "messages": messages,
                "max_tokens": request.maximumOutputTokens,
            ]
        case .anthropicMessages:
            var value: [String: Any] = [
                "model": route.textModel,
                "max_tokens": request.maximumOutputTokens,
                "messages": [["role": "user", "content": request.prompt]],
            ]
            if let instructions = request.systemInstructions { value["system"] = instructions }
            object = value
        case .geminiGenerateContent:
            var value: [String: Any] = [
                "contents": [["role": "user", "parts": [["text": request.prompt]]]],
                "generationConfig": ["maxOutputTokens": request.maximumOutputTokens],
            ]
            if let instructions = request.systemInstructions {
                value["systemInstruction"] = ["parts": [["text": instructions]]]
            }
            object = value
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func parse(
        _ data: Data,
        route: AIProviderRouteSnapshot,
        requestId: String?
    ) throws -> ProviderTextResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DirectProviderError.invalidResponse
        }
        let text: String?
        switch route.adapter {
        case .openAIResponses:
            text = root["output_text"] as? String ?? Self.openAIOutputText(root)
        case .openAICompatible:
            text = (((root["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String)
        case .anthropicMessages:
            text = (root["content"] as? [[String: Any]])?
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
        case .geminiGenerateContent:
            text = (root["candidates"] as? [[String: Any]])?
                .compactMap { $0["content"] as? [String: Any] }
                .compactMap { $0["parts"] as? [[String: Any]] }
                .flatMap { $0 }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DirectProviderError.invalidResponse
        }
        let usage = root["usage"] as? [String: Any] ?? root["usageMetadata"] as? [String: Any]
        return ProviderTextResponse(
            text: text,
            providerRequestId: (root["id"] as? String) ?? requestId,
            inputTokens: (usage?["input_tokens"] as? Int)
                ?? (usage?["prompt_tokens"] as? Int)
                ?? (usage?["promptTokenCount"] as? Int),
            outputTokens: (usage?["output_tokens"] as? Int)
                ?? (usage?["completion_tokens"] as? Int)
                ?? (usage?["candidatesTokenCount"] as? Int)
        )
    }

    private static func openAIOutputText(_ root: [String: Any]) -> String? {
        (root["output"] as? [[String: Any]])?
            .compactMap { $0["content"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }

    private static func validatedBaseURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              scheme == "https" || (scheme == "http" && isPrivateHost(host)),
              let url = components.url
        else { return nil }
        return url
    }

    private static func isPrivateHost(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host.hasSuffix(".local")
            || host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.")
            || (host.split(separator: ".").count == 4 && {
                let values = host.split(separator: ".").compactMap { Int($0) }
                return values.count == 4 && values[0] == 172 && (16 ... 31).contains(values[1])
            }())
    }
}
