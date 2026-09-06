import Darwin
import DayreedCore
import Foundation
import Testing
@testable import DayreedAnalysis

/// Only loopback, synthetic payloads, no external Provider or user credentials.
private final class HTTPFixture: @unchecked Sendable {
    let listener: Int32
    let port: UInt16
    private let lock = NSLock()
    private var stopped = false
    private var received = 0
    private let response: Data
    private let delay: Double
    var requestCount: Int { lock.withLock { received } }

    init(body: Data, status: Int = 200, extraHeaders: String = "", delay: Double = 0,
         advertisedLength: Int? = nil, omitLength: Bool = false) throws {
        self.delay = delay
        let length = omitLength ? "" : "Content-Length: \(advertisedLength ?? body.count)\r\n"
        response = Data("HTTP/1.1 \(status) Synthetic\r\n\(length)\(extraHeaders)Connection: close\r\n\r\n".utf8) + body
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        self.listener = listener
        guard listener >= 0 else { throw AnalysisError.transport }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 8) == 0 else { Darwin.close(listener); throw AnalysisError.transport }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) }
        }
        guard named == 0 else { Darwin.close(listener); throw AnalysisError.transport }
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global(qos: .utility).async { [self] in serve() }
    }

    func stop() {
        let close = lock.withLock { () -> Bool in
            guard !stopped else { return false }; stopped = true; return true
        }
        if close { shutdown(listener, SHUT_RDWR); Darwin.close(listener) }
    }
    private func serve() {
        while !lock.withLock({ stopped }) {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            lock.withLock { received += 1 }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
            while bytes.count < 16 * 1_024 * 1_024 {
                let count = read(client, &buffer, buffer.count)
                guard count > 0 else { break }
                bytes.append(contentsOf: buffer.prefix(count))
                if let headerEnd = bytes.range(of: Data("\r\n\r\n".utf8)) {
                    let header = String(decoding: bytes[..<headerEnd.lowerBound], as: UTF8.self)
                    let length = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                        .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                    if bytes.count >= headerEnd.upperBound + length { break }
                }
            }
            if delay > 0 { usleep(useconds_t(delay * 1_000_000)) }
            if !lock.withLock({ stopped }) {
                response.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let sent = write(client, bytes.baseAddress!.advanced(by: offset), min(16_384, bytes.count - offset))
                        if sent <= 0 { break }; offset += sent
                    }
                }
            }
            Darwin.close(client)
        }
    }
    func provider(timeout: Double = 3) throws -> OpenAICompatibleProvider {
        try OpenAICompatibleProvider(configuration: ProviderConfiguration(name: "Synthetic loopback", kind: .openAICompatible,
            model: "synthetic", endpoint: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions"), timeoutSeconds: timeout), apiKey: "SYNTHETIC_KEY")
    }
}

private func httpObservation(_ id: UUID) -> [ProviderObservation] {
    [ProviderObservation(recordID: id, capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                         applicationBundleIdentifier: "test.synthetic", evidence: [], sources: [.application])]
}

@Test func realHTTPTransportAcceptsSyntheticResponseAndDoesNotFollowRedirects() async throws {
    let id = UUID()
    let content = "{\"status\":\"ok\",\"activities\":[{\"recordID\":\"\(id)\",\"title\":\"合成活动\",\"summary\":\"抽象描述\"}]}"
    let body = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
    let server = try HTTPFixture(body: body); defer { server.stop() }
    let values = try await server.provider().classify(httpObservation(id))
    #expect(values.count == 1 && values[0].recordID == id)
    #expect(server.requestCount == 1)
    let redirect = try HTTPFixture(body: Data(), status: 302, extraHeaders: "Location: http://127.0.0.1:\(server.port)/v1/chat/completions\r\n")
    defer { redirect.stop() }
    await #expect(throws: AnalysisError.transport) { try await redirect.provider().classify(httpObservation(id)) }
    #expect(server.requestCount == 1)
}

@Test func realHTTPTransportBoundsDeclaredAndStreamingBodiesAndSanitizesErrors() async throws {
    let id = UUID()
    let declared = try HTTPFixture(body: Data(repeating: 65, count: 2 * 1_024 * 1_024)); defer { declared.stop() }
    await #expect(throws: AnalysisError.outputTooLarge) { try await declared.provider().classify(httpObservation(id)) }
    let streaming = try HTTPFixture(body: Data(repeating: 65, count: 2 * 1_024 * 1_024), omitLength: true); defer { streaming.stop() }
    await #expect(throws: AnalysisError.outputTooLarge) { try await streaming.provider().classify(httpObservation(id)) }
    let failed = try HTTPFixture(body: Data("SYNTHETIC_PROVIDER_BODY_SECRET".utf8), status: 503); defer { failed.stop() }
    await #expect(throws: AnalysisError.providerFailed) { try await failed.provider().classify(httpObservation(id)) }
}

@Test func realHTTPTransportCancelsAndTimesOutWithoutPersistingSuccess() async throws {
    let id = UUID()
    let slow = try HTTPFixture(body: Data(), delay: 2); defer { slow.stop() }
    await #expect(throws: AnalysisError.timedOut) { try await slow.provider(timeout: 1).classify(httpObservation(id)) }
    let cancelled = try HTTPFixture(body: Data(), delay: 2); defer { cancelled.stop() }
    let task = Task { try await cancelled.provider().classify(httpObservation(id)) }
    try await Task.sleep(for: .milliseconds(50)); task.cancel()
    await #expect(throws: AnalysisError.cancelled) { try await task.value }
}
