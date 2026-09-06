import DayreedCore
import Foundation

/// Ephemeral session, no cache/cookies/redirects, bounded response, and no diagnostic response body.
public struct OpenAICompatibleProvider: AnalysisProvider, CustomStringConvertible, CustomDebugStringConvertible {
    private let configuration: ProviderConfiguration
    private let apiKey: String?
    public var description: String { "OpenAICompatibleProvider(credentials redacted)" }
    public var debugDescription: String { description }
    public init(configuration: ProviderConfiguration, apiKey: String?) throws {
        try configuration.validate()
        guard configuration.kind == .openAICompatible else { throw AnalysisError.invalidConfiguration }
        if let apiKey, apiKey.contains(where: { $0.isNewline || $0 == "\0" }) { throw AnalysisError.credentials }
        self.configuration = configuration; self.apiKey = apiKey
    }

    public func classify(_ observations: [ProviderObservation]) async throws -> [ActivityClassification] {
        let request = try makeRequest(observations)
        let transport = BoundedHTTPTransport()
        let data = try await transport.send(request, timeout: configuration.timeoutSeconds)
        return try Self.parse(data, expectedIDs: Set(observations.map(\.recordID)))
    }

    func makeRequest(_ observations: [ProviderObservation]) throws -> URLRequest {
        guard !observations.isEmpty, let endpoint = configuration.endpoint else { throw AnalysisError.noEvidence }
        let images = observations.flatMap(\.evidence).filter { $0.kind == .screenshot }
        if !images.isEmpty && !configuration.supportsImages { throw AnalysisError.unsupportedImages }
        var parts: [[String: Any]] = [["type": "text", "text": try AnalysisPrompt.text(observations)]]
        for image in images {
            guard ["image/png", "image/jpeg", "image/webp"].contains(image.mediaType) else { throw AnalysisError.unsupportedImages }
            parts.append(["type": "text", "text": "Image evidence \(image.id.uuidString), recordID \(image.recordID.uuidString)"])
            parts.append(["type": "image_url", "image_url": ["url": "data:\(image.mediaType);base64,\(image.data.base64EncodedString())"]])
        }
        let body: [String: Any] = [
            "model": configuration.model, "stream": false, "store": false,
            "messages": [["role": "system", "content": AnalysisPrompt.instruction], ["role": "user", "content": parts]],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= 16 * 1_024 * 1_024 else { throw AnalysisError.inputTooLarge }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: configuration.timeoutSeconds)
        request.httpMethod = "POST"; request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    static func parse(_ data: Data, expectedIDs: Set<UUID>) throws -> [ActivityClassification] {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?; let refusal: String?; let tool_calls: [ToolCall]?
                    struct ToolCall: Decodable {}
                }
                let message: Message; let finish_reason: String?
            }
            let choices: [Choice]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.choices.count == 1, let choice = response.choices.first else { throw AnalysisError.invalidResponse }
        if choice.message.refusal?.isEmpty == false || choice.finish_reason == "content_filter" { throw AnalysisError.refused }
        guard choice.finish_reason == "stop", choice.message.tool_calls?.isEmpty != false else { throw AnalysisError.invalidResponse }
        guard let content = choice.message.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AnalysisError.emptyResponse
        }
        return try AnalysisPrompt.decode(Data(content.utf8), expectedIDs: expectedIDs)
    }
}

private final class BoundedHTTPTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Data, any Error>?
    private var bytes = Data()
    private var ended = false
    private var cancelled = false

    func send(_ request: URLRequest, timeout: Double) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: AnalysisError.cancelled); return }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil; configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
                configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request); self.task = task
                task.resume()
                lock.unlock()
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        lock.withLock { cancelled = true }
        finish(.failure(AnalysisError.cancelled))
    }
    private func finish(_ result: Result<Data, any Error>) {
        let cleanup = lock.withLock { () -> (CheckedContinuation<Data, any Error>?, URLSession?) in
            guard !ended else { return (nil, nil) }
            ended = true
            let continuation = self.continuation; self.continuation = nil
            let session = self.session; self.session = nil; task = nil; bytes.removeAll()
            return (continuation, session)
        }
        cleanup.1?.invalidateAndCancel(); cleanup.0?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(AnalysisError.transport))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            finish(.failure(AnalysisError.providerFailed)); completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= 1_024 * 1_024 else {
            finish(.failure(AnalysisError.outputTooLarge)); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let oversized = lock.withLock { () -> Bool in
            guard !ended else { return false }
            if bytes.count + data.count > 1_024 * 1_024 { return true }
            bytes.append(data); return false
        }
        if oversized { finish(.failure(AnalysisError.outputTooLarge)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            let code = (error as NSError).code
            finish(.failure(code == NSURLErrorTimedOut ? AnalysisError.timedOut : AnalysisError.transport))
        } else {
            let value = lock.withLock { bytes }
            finish(.success(value))
        }
    }
}
