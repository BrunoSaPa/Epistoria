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
public final class DirectProviderClient: ProviderClient, ProviderTranscriptionClient, @unchecked Sendable {
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
        guard request.prompt.utf8.count
                + (request.systemInstructions?.utf8.count ?? 0) <= 2_000_000,
              request.images.allSatisfy({
                  ["image/png", "image/jpeg"].contains($0.mimeType) && $0.data.count <= 2_000_000
              }),
              request.images.reduce(0, { $0 + $1.data.count }) <= 12_000_000
        else {
            throw DirectProviderError.requestTooLarge
        }
        var urlRequest = try makeRequest(request, route: route, apiKey: apiKey)
        urlRequest.httpBody = try requestBody(request, route: route)
        guard (urlRequest.httpBody?.count ?? 0) <= 18_000_000 else {
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

    public func performTranscription(
        _ request: ProviderTranscriptionRequest,
        route: AIProviderRouteSnapshot,
        apiKey: String?
    ) async throws -> ProviderTranscriptionResponse {
        guard route.capabilities.contains(.transcription),
              let model = route.transcriptionModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty,
              request.audio.count <= 25 * 1_024 * 1_024,
              [.openAIResponses, .openAICompatible].contains(route.adapter),
              let baseURL = Self.validatedBaseURL(route.baseURL)
        else { throw DirectProviderError.invalidRoute }
        if route.adapter == .openAIResponses, apiKey?.isEmpty != false {
            throw DirectProviderError.missingCredential
        }
        let boundary = "Epistoria-\(UUID().uuidString)"
        var urlRequest = URLRequest(url: baseURL.appending(path: "audio/transcriptions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = Self.multipartBody(
            request: request,
            model: model,
            boundary: boundary
        )
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
        return try Self.parseTranscription(
            data,
            requestId: http.value(forHTTPHeaderField: "x-request-id")
        )
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
                "max_output_tokens": request.maximumOutputTokens,
            ]
            if request.images.isEmpty {
                value["input"] = request.prompt
            } else {
                value["input"] = [[
                    "role": "user",
                    "content": Self.openAIContent(request),
                ]]
            }
            if let instructions = request.systemInstructions { value["instructions"] = instructions }
            object = value
        case .openAICompatible:
            var messages: [[String: String]] = []
            if let instructions = request.systemInstructions {
                messages.append(["role": "system", "content": instructions])
            }
            var genericMessages: [[String: Any]] = messages.map { $0 }
            let userContent: Any = request.images.isEmpty
                ? request.prompt
                : Self.openAICompatibleContent(request)
            genericMessages.append([
                "role": "user",
                "content": userContent,
            ])
            object = [
                "model": route.textModel,
                "messages": genericMessages,
                "max_tokens": request.maximumOutputTokens,
            ]
        case .anthropicMessages:
            let userContent: Any = request.images.isEmpty
                ? request.prompt
                : Self.anthropicContent(request)
            var value: [String: Any] = [
                "model": route.textModel,
                "max_tokens": request.maximumOutputTokens,
                "messages": [[
                    "role": "user",
                    "content": userContent,
                ]],
            ]
            if let instructions = request.systemInstructions { value["system"] = instructions }
            object = value
        case .geminiGenerateContent:
            var value: [String: Any] = [
                "contents": [["role": "user", "parts": Self.geminiParts(request)]],
                "generationConfig": ["maxOutputTokens": request.maximumOutputTokens],
            ]
            if let instructions = request.systemInstructions {
                value["systemInstruction"] = ["parts": [["text": instructions]]]
            }
            object = value
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func openAIContent(_ request: ProviderTextRequest) -> [[String: Any]] {
        var content: [[String: Any]] = [["type": "input_text", "text": request.prompt]]
        content += request.images.map {
            ["type": "input_image", "image_url": dataURL(for: $0)]
        }
        return content
    }

    private static func openAICompatibleContent(_ request: ProviderTextRequest) -> [[String: Any]] {
        var content: [[String: Any]] = [["type": "text", "text": request.prompt]]
        content += request.images.map {
            ["type": "image_url", "image_url": ["url": dataURL(for: $0)]]
        }
        return content
    }

    private static func anthropicContent(_ request: ProviderTextRequest) -> [[String: Any]] {
        var content: [[String: Any]] = [["type": "text", "text": request.prompt]]
        content += request.images.map {
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": $0.mimeType,
                    "data": $0.data.base64EncodedString(),
                ],
            ]
        }
        return content
    }

    private static func geminiParts(_ request: ProviderTextRequest) -> [[String: Any]] {
        var parts: [[String: Any]] = [["text": request.prompt]]
        parts += request.images.map {
            ["inlineData": ["mimeType": $0.mimeType, "data": $0.data.base64EncodedString()]]
        }
        return parts
    }

    private static func dataURL(for image: ProviderImageInput) -> String {
        "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
    }

    private static func multipartBody(
        request: ProviderTranscriptionRequest,
        model: String,
        boundary: String
    ) -> Data {
        var body = Data()
        func append(_ value: String) { body.append(Data(value.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        field("model", model)
        field("response_format", "verbose_json")
        if let language = request.language, !language.isEmpty { field("language", language) }
        append("--\(boundary)\r\n")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let safeFilename = String(request.filename.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "_"
        }).prefix(255)
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename.isEmpty ? "media" : String(safeFilename))\"\r\n")
        append("Content-Type: \(request.mimeType)\r\n\r\n")
        body.append(request.audio)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func parseTranscription(
        _ data: Data,
        requestId: String?
    ) throws -> ProviderTranscriptionResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = root["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw DirectProviderError.invalidResponse }
        let rawSegments = root["segments"] as? [[String: Any]] ?? []
        var segments: [TranscriptSegment] = []
        for (index, value) in rawSegments.prefix(20_000).enumerated() {
            guard let segmentText = value["text"] as? String,
                  let start = (value["start"] as? NSNumber)?.doubleValue,
                  let end = (value["end"] as? NSNumber)?.doubleValue,
                  start.isFinite, end.isFinite, end >= start
            else { throw DirectProviderError.invalidResponse }
            segments.append(
                TranscriptSegment(
                    index: (value["id"] as? Int) ?? index,
                    startSeconds: start,
                    endSeconds: end,
                    text: String(segmentText.prefix(20_000))
                )
            )
        }
        let duration = (root["duration"] as? NSNumber)?.doubleValue
            ?? segments.last?.endSeconds ?? 0
        guard duration.isFinite, duration >= 0 else { throw DirectProviderError.invalidResponse }
        if segments.isEmpty {
            segments = [TranscriptSegment(index: 0, startSeconds: 0, endSeconds: duration, text: text)]
        }
        return ProviderTranscriptionResponse(
            text: text,
            language: root["language"] as? String,
            durationSeconds: duration,
            segments: segments,
            providerRequestId: (root["id"] as? String) ?? requestId
        )
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
