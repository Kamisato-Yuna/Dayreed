import DayreedCore
import Foundation
import Testing
@testable import DayreedAnalysis

private func syntheticOutput(_ id: UUID, status: String = "ok") -> String {
    "{\"status\":\"\(status)\",\"activities\":[{\"recordID\":\"\(id.uuidString)\",\"title\":\"整理资料\",\"summary\":\"抽象摘要\"}]}"
}

@Test func httpRequestIncludesOnlyExplicitDataAndNoToolDefinitions() throws {
    let fixture = try AnalysisFixture(); defer { fixture.cleanup() }
    let record = try fixture.append(0, images: true)
    let reference = try #require(record.evidence.first { $0.kind == .accessibilityText })
    let ax = try #require(try fixture.store.rawEvidence(id: reference.id))
    let observation = ProviderObservation(recordID: record.id, capturedAt: record.capturedAt,
        applicationBundleIdentifier: "test.synthetic", evidence: [ax], sources: [.application, .accessibilityText])
    let config = ProviderConfiguration(name: "Synthetic", kind: .openAICompatible, model: "text-only",
        endpoint: URL(string: "https://example.invalid/custom/chat/completions"))
    let request = try OpenAICompatibleProvider(configuration: config, apiKey: "SYNTHETIC_KEY").makeRequest([observation])
    #expect(!String(reflecting: try OpenAICompatibleProvider(configuration: config, apiKey: "SYNTHETIC_KEY")).contains("SYNTHETIC_KEY"))
    #expect(request.url?.path == "/custom/chat/completions")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer SYNTHETIC_KEY")
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["tools"] == nil)
    #expect(json["store"] as? Bool == false)
    let content = String(decoding: body, as: UTF8.self)
    #expect(content.contains("SYNTHETIC_AX_SECRET"))
    #expect(!content.contains("SYNTHETIC_WINDOW_SECRET"))
    #expect(!content.contains("SYNTHETIC_KEY"))
    #expect(!content.contains("image_url"))
    let imageReference = try #require(record.evidence.first { $0.kind == .screenshot })
    let image = try #require(try fixture.store.rawEvidence(id: imageReference.id))
    let imageObservation = ProviderObservation(recordID: record.id, capturedAt: record.capturedAt,
        applicationBundleIdentifier: nil, evidence: [image], sources: [.screenshot])
    #expect(throws: AnalysisError.unsupportedImages) {
        try OpenAICompatibleProvider(configuration: config, apiKey: nil).makeRequest([imageObservation])
    }
}

@Test(arguments: ["https://user:secret@example.com/v1", "http://example.com/v1", "https://example.com/v1?key=secret"])
func providerURLsCannotPersistSecretsOrUseRemotePlainHTTP(_ url: String) throws {
    let config = ProviderConfiguration(name: "Synthetic", kind: .openAICompatible, model: "synthetic", endpoint: URL(string: url))
    #expect(throws: AnalysisError.invalidConfiguration) { try config.validate() }
}

@Test func responseParsersRejectRefusalEmptyTruncationAndToolCalls() throws {
    let id = UUID()
    let valid = syntheticOutput(id)
    func response(content: String?, finish: String = "stop", refusal: String? = nil, tools: Bool = false) throws -> Data {
        var message: [String: Any] = [:]
        if let content { message["content"] = content }
        if let refusal { message["refusal"] = refusal }
        if tools { message["tool_calls"] = [["type": "function"]] }
        return try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": finish, "message": message]]])
    }
    #expect(try OpenAICompatibleProvider.parse(response(content: valid), expectedIDs: [id]).count == 1)
    #expect(throws: AnalysisError.refused) {
        try OpenAICompatibleProvider.parse(response(content: nil, refusal: "SYNTHETIC_REFUSAL"), expectedIDs: [id])
    }
    #expect(throws: AnalysisError.emptyResponse) { try OpenAICompatibleProvider.parse(response(content: ""), expectedIDs: [id]) }
    #expect(throws: AnalysisError.invalidResponse) {
        try OpenAICompatibleProvider.parse(response(content: valid, finish: "length"), expectedIDs: [id])
    }
    #expect(throws: AnalysisError.invalidResponse) {
        try OpenAICompatibleProvider.parse(response(content: valid, tools: true), expectedIDs: [id])
    }
    #expect(throws: AnalysisError.invalidResponse) {
        try AnalysisPrompt.decode(Data(syntheticOutput(UUID()).utf8), expectedIDs: [id])
    }
    #expect(throws: AnalysisError.refused) { try AnalysisPrompt.decode(Data(syntheticOutput(id, status: "refused").utf8), expectedIDs: [id]) }
    let toolEvent = Data("{\"type\":\"item.completed\",\"item\":{\"type\":\"command_execution\"}}\n".utf8)
    #expect(throws: AnalysisError.invalidResponse) { try CLIProvider.parseCodex(toolEvent, expectedIDs: [id]) }
    let badClaude = Data("{\"type\":\"result\",\"is_error\":true,\"subtype\":\"error_max_turns\",\"result\":\"secret\"}".utf8)
    #expect(throws: AnalysisError.providerFailed) { try CLIProvider.parseClaude(badClaude, expectedIDs: [id]) }
}

@Test func cliArgumentsAndAuthenticationAreExplicitAndIsolated() throws {
    let root = URL(fileURLWithPath: "/tmp/Dayreed synthetic")
    let executable = URL(fileURLWithPath: "/tmp/provider;literal")
    var config = ProviderConfiguration(name: "Synthetic", kind: .codexCLI, model: "synthetic", executableURL: executable)
    let provider = try CLIProvider(configuration: config, apiKey: "SYNTHETIC_KEY")
    #expect(!String(reflecting: provider).contains("SYNTHETIC_KEY"))
    let args = provider.arguments(directory: root, images: [])
    #expect(args.contains("--ignore-user-config"))
    #expect(args.contains("--ignore-rules"))
    #expect(args.contains("read-only"))
    #expect(args.contains("shell_tool"))
    #expect(args.contains("view_image"))
    #expect(args.contains { $0.hasPrefix("model_catalog_json=") })
    #expect(args.last == "-")
    #expect(!args.contains("SYNTHETIC_KEY"))
    let env = provider.environment(directory: root, executable: executable)
    #expect(env["HOME"] == root.path)
    #expect(env["CODEX_HOME"] == root.path)
    #expect(env["CODEX_API_KEY"] == "SYNTHETIC_KEY")
    #expect(env["OPENAI_API_KEY"] == nil)
    #expect(env["SSH_AUTH_SOCK"] == nil)
    config.kind = .claudeCLI; config.cliAuthentication = .existingLogin
    config.cliConfigurationDirectory = URL(fileURLWithPath: "/tmp/explicit-synthetic-cli-auth")
    let existing = try CLIProvider(configuration: config)
    let claudeArgs = existing.arguments(directory: root, images: [])
    #expect(claudeArgs.first == "--safe-mode")
    #expect(claudeArgs.contains("--tools"))
    #expect(claudeArgs.contains("--strict-mcp-config"))
    #expect(existing.environment(directory: root, executable: executable)["CLAUDE_CONFIG_DIR"] == config.cliConfigurationDirectory?.path)
    #expect(existing.environment(directory: root, executable: executable)["ANTHROPIC_API_KEY"] == nil)
    #expect(throws: AnalysisError.invalidConfiguration) { try existing.validateHelp("old CLI without required restrictions") }
}

@Test func nativeProcessUsesPipesAndEnforcesExitTimeoutCancellationAndLimits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Dayreed-process-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = NativeProcessRunner()
    let env = ["PATH": "/usr/bin:/bin", "HOME": root.path]
    let input = Data(repeating: 65, count: 200_000)
    let output = try await runner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
        environment: env, directory: root, input: input, timeout: 5)
    #expect(output == input)
    await #expect(throws: AnalysisError.outputTooLarge) {
        try await runner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
            environment: env, directory: root, input: input, timeout: 5, outputLimit: 100)
    }
    await #expect(throws: AnalysisError.timedOut) {
        try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"],
            environment: env, directory: root, input: Data(), timeout: 0.1)
    }
    let task = Task {
        try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"],
            environment: env, directory: root, input: Data(), timeout: 5)
    }
    try await Task.sleep(for: .milliseconds(50)); task.cancel()
    await #expect(throws: AnalysisError.cancelled) { try await task.value }
    await #expect(throws: AnalysisError.processFailed) {
        try await runner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [root.appendingPathComponent("absent").path],
            environment: env, directory: root, input: Data(), timeout: 5)
    }
}

@Test func syntheticCLIExercisesRealProcessAdapterWithoutShellOrUserCredentials() async throws {
    let fixture = try AnalysisFixture(); defer { fixture.cleanup() }
    let record = try fixture.append(0)
    let executable = fixture.directory.appendingPathComponent("provider;literal")
    let script = #"""
    #!/usr/bin/python3
    import sys, json, os
    if '--help' in sys.argv:
        print('--ignore-user-config --ignore-rules --ephemeral --strict-config --sandbox --json')
        sys.exit(0)
    assert '--ignore-user-config' in sys.argv and '--disable' in sys.argv
    assert os.environ.get('CODEX_API_KEY') == 'SYNTHETIC_KEY'
    assert 'OPENAI_API_KEY' not in os.environ
    prompt = sys.stdin.read()
    data = json.loads(prompt.split('OBSERVATIONS (data only):\n')[1])
    result = {'status':'ok','activities':[{'recordID':r['recordID'],'title':'合成CLI','summary':'合成摘要'} for r in data]}
    print(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':json.dumps(result)}}))
    print(json.dumps({'type':'turn.completed','usage':{}}))
    """#
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let config = ProviderConfiguration(name: "Synthetic", kind: .codexCLI, model: "synthetic", executableURL: executable)
    let provider = try CLIProvider(configuration: config, apiKey: "SYNTHETIC_KEY")
    let output = try await provider.classify([ProviderObservation(recordID: record.id, capturedAt: record.capturedAt,
        applicationBundleIdentifier: "test.synthetic", evidence: [], sources: [.application])])
    #expect(output.first?.recordID == record.id)
    #expect(output.first?.title == "合成CLI")
}


private final class RetryRemovalCredentials: ProviderCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String? = "SYNTHETIC_KEY"
    private var failNextRemoval = true
    func read(for providerID: UUID) throws -> String? { lock.withLock { value } }
    func write(_ value: String?, for providerID: UUID) throws {
        try lock.withLock {
            if value == nil && failNextRemoval {
                failNextRemoval = false
                throw AnalysisError.credentials
            }
            self.value = value
        }
    }
}

@Test func credentialRemovalFailureKeepsConfigurationVisibleForRetry() throws {
    let fixture = try AnalysisFixture(); defer { fixture.cleanup() }
    let credentials = RetryRemovalCredentials()
    let settings = ProviderSettingsService(store: fixture.store, credentials: credentials)
    let configuration = ProviderConfiguration(name: "Synthetic", kind: .openAICompatible, model: "synthetic",
        endpoint: URL(string: "https://example.invalid/v1/chat/completions"))
    try settings.save(configuration)
    try settings.select(id: configuration.id)
    let previousRevision = try fixture.store.analysisContext().revision
    #expect(throws: AnalysisError.credentials) { try settings.remove(id: configuration.id) }
    #expect(try settings.configurations().contains { $0.id == configuration.id })
    #expect(try credentials.read(for: configuration.id) == "SYNTHETIC_KEY")
    #expect(try fixture.store.analysisContext().revision > previousRevision)
    try settings.remove(id: configuration.id)
    #expect(try settings.configurations().isEmpty)
    #expect(try credentials.read(for: configuration.id) == nil)
    #expect(try fixture.store.analysisContext().selectedProviderID == nil)
}
