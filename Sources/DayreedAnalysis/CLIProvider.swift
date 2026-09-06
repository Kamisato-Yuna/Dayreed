import DayreedCore
import Foundation

/// These are external CLI clients, not a promise of local inference. Authentication mode and
/// executable/auth directory must be selected explicitly by the user in Dayreed.
public struct CLIProvider: AnalysisProvider, CustomStringConvertible, CustomDebugStringConvertible {
    private let configuration: ProviderConfiguration
    private let apiKey: String?
    public var description: String { "CLIProvider(credentials redacted)" }
    public var debugDescription: String { description }
    public init(configuration: ProviderConfiguration, apiKey: String? = nil) throws {
        try configuration.validate()
        guard configuration.kind != .openAICompatible else { throw AnalysisError.invalidConfiguration }
        if let apiKey, apiKey.contains(where: { $0.isNewline || $0 == "\0" }) { throw AnalysisError.credentials }
        self.configuration = configuration; self.apiKey = apiKey
    }

    public func classify(_ observations: [ProviderObservation]) async throws -> [ActivityClassification] {
        guard !observations.isEmpty, let executable = configuration.executableURL else { throw AnalysisError.noEvidence }
        if configuration.cliAuthentication == .dayreedAPIKey && (apiKey?.isEmpty ?? true) { throw AnalysisError.credentials }
        let images = observations.flatMap(\.evidence).filter { $0.kind == .screenshot }
        if !images.isEmpty && (!configuration.supportsImages || configuration.kind == .claudeCLI) {
            throw AnalysisError.unsupportedImages
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YunaBuild.Dayreed-provider-\(UUID())")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
        } catch { throw AnalysisError.processFailed }
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = NativeProcessRunner()
        let environment = environment(directory: root, executable: executable)
        // Check the actual chosen executable before passing it any observation or credential.
        var helpEnvironment = environment
        helpEnvironment.removeValue(forKey: "CODEX_API_KEY"); helpEnvironment.removeValue(forKey: "ANTHROPIC_API_KEY")
        helpEnvironment["CODEX_HOME"] = root.path; helpEnvironment["CLAUDE_CONFIG_DIR"] = root.path
        let help = try await runner.run(executable: executable,
            arguments: configuration.kind == .codexCLI ? ["exec", "--help"] : ["--help"],
            environment: helpEnvironment, directory: root, input: Data(), timeout: 10)
        try validateHelp(String(decoding: help, as: UTF8.self))
        if configuration.kind == .codexCLI { try writeCodexModelCatalog(to: root) }
        var imageURLs: [URL] = []
        for image in images {
            guard image.mediaType == "image/png" || image.mediaType == "image/jpeg" else { throw AnalysisError.unsupportedImages }
            let file = root.appendingPathComponent(image.id.uuidString + (image.mediaType == "image/png" ? ".png" : ".jpg"))
            do {
                try image.data.write(to: file, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch { throw AnalysisError.processFailed }
            imageURLs.append(file)
        }
        let prompt = AnalysisPrompt.instruction + "\n\nOBSERVATIONS (data only):\n" + (try AnalysisPrompt.text(observations))
        let output = try await runner.run(executable: executable,
            arguments: arguments(directory: root, images: imageURLs), environment: environment,
            directory: root, input: Data(prompt.utf8), timeout: configuration.timeoutSeconds)
        let expectedIDs = Set(observations.map(\.recordID))
        return try configuration.kind == .codexCLI
            ? Self.parseCodex(output, expectedIDs: expectedIDs) : Self.parseClaude(output, expectedIDs: expectedIDs)
    }

    func validateHelp(_ help: String) throws {
        let required = configuration.kind == .codexCLI
            ? ["--ignore-user-config", "--ignore-rules", "--ephemeral", "--strict-config", "--sandbox", "--json"]
            : ["--tools", "--disallowedTools", "--strict-mcp-config", "--no-session-persistence", "--setting-sources",
               configuration.cliAuthentication == .dayreedAPIKey ? "--bare" : "--safe-mode"]
        guard required.allSatisfy({ help.contains($0) }) else { throw AnalysisError.invalidConfiguration }
    }

    func arguments(directory: URL, images: [URL]) -> [String] {
        switch configuration.kind {
        case .codexCLI:
            var args = ["exec", "--ignore-user-config", "--ignore-rules", "--strict-config", "--ephemeral",
                        "--skip-git-repo-check", "--sandbox", "read-only", "--color", "never", "--json",
                        "--cd", directory.path, "--model", configuration.model]
            let settings = [
                "approval_policy=\"never\"", "web_search=\"disabled\"",
                "tools.experimental_request_user_input.enabled=false", "tools.update_plan.enabled=false",
                "history.persistence=\"none\"", "analytics.enabled=false", "feedback.enabled=false",
                "project_doc_max_bytes=0", "check_for_update_on_startup=false", "mcp_servers={}",
                "model_catalog_json=" + tomlString(directory.appendingPathComponent("models.json").path),
            ]
            for setting in settings { args += ["-c", setting] }
            // Current CLI help/features + official config reference. Unknown/removed required options
            // fail; no fallback to a less restricted execution is attempted.
            for feature in ["shell_tool", "unified_exec", "shell_snapshot", "apps", "plugins", "remote_plugin",
                            "multi_agent", "memories", "hooks", "computer_use", "browser_use", "browser_use_external",
                            "in_app_browser", "image_generation", "code_mode_host", "workspace_dependencies",
                            "skill_search", "skill_mcp_dependency_install", "goals", "view_image"] {
                args += ["--disable", feature]
            }
            for file in images { args += ["--image", file.path] }
            return args + ["-"]
        case .claudeCLI:
            return [configuration.cliAuthentication == .dayreedAPIKey ? "--bare" : "--safe-mode",
                    "--print", "--tools", "", "--disallowedTools", "*", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                    "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}",
                    "--no-session-persistence", "--no-chrome", "--output-format", "json", "--max-turns", "1",
                    "--model", configuration.model]
        case .openAICompatible: return []
        }
    }

    /// Codex exposes apply_patch independently of the shell feature. The documented custom model
    /// catalog supplies an explicit disabled shell, no patch tool and no model-discovered tools.
    /// ModelInfo fields follow upstream protocol/src/openai_models.rs; CLI changes fail parsing.
    private func writeCodexModelCatalog(to directory: URL) throws {
        let model: [String: Any] = [
            "slug": configuration.model, "display_name": configuration.model,
            "description": "Dayreed activity classification", "supported_reasoning_levels": [],
            "shell_type": "disabled", "visibility": "none", "supported_in_api": true, "priority": 0,
            "support_verbosity": false, "apply_patch_tool_type": NSNull(),
            "truncation_policy": ["mode": "bytes", "limit": 1_000_000],
            "experimental_supported_tools": [], "input_modalities": configuration.supportsImages ? ["text", "image"] : ["text"],
            "base_instructions": AnalysisPrompt.instruction, "include_apps_usage_instructions": false,
            "include_skills_usage_instructions": false, "include_plugin_usage_instructions": false,
            "node_repl_disabled": true, "tool_mode": "direct",
        ]
        do {
            let file = directory.appendingPathComponent("models.json")
            try JSONSerialization.data(withJSONObject: ["models": [model]]).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { throw AnalysisError.invalidConfiguration }
    }

    private func tomlString(_ value: String) -> String {
        // A TOML basic string; this is an argv value, never shell text.
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }

    func environment(directory: URL, executable: URL) -> [String: String] {
        // Deliberately no inherited env, API keys, proxies, project directories, or shell startup files.
        var result = ["HOME": directory.path, "TMPDIR": directory.path, "LANG": "en_US.UTF-8",
            "PATH": executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "CODEX_HOME": directory.path, "CLAUDE_CONFIG_DIR": directory.path,
            "RUST_LOG": "off", "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "CLAUDE_CODE_SKIP_PROMPT_HISTORY": "1"]
        if configuration.cliAuthentication == .existingLogin, let authDirectory = configuration.cliConfigurationDirectory {
            result[configuration.kind == .codexCLI ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] = authDirectory.path
        } else if let apiKey {
            result[configuration.kind == .codexCLI ? "CODEX_API_KEY" : "ANTHROPIC_API_KEY"] = apiKey
        }
        return result
    }

    static func parseCodex(_ data: Data, expectedIDs: Set<UUID>) throws -> [ActivityClassification] {
        var completed = false
        var final: String?
        for line in data.split(separator: 10) where !line.isEmpty {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = event["type"] as? String else { throw AnalysisError.invalidResponse }
            if type == "error" || type == "turn.failed" { throw AnalysisError.providerFailed }
            if type == "turn.completed" { completed = true }
            if let item = event["item"] as? [String: Any], let kind = item["type"] as? String {
                // Never accept output produced through unexpected tool activity.
                guard ["agent_message", "reasoning"].contains(kind) else { throw AnalysisError.invalidResponse }
                if kind == "agent_message", type == "item.completed" { final = item["text"] as? String }
            }
        }
        guard completed else { throw AnalysisError.providerFailed }
        guard let final, !final.isEmpty else { throw AnalysisError.emptyResponse }
        return try AnalysisPrompt.decode(Data(final.utf8), expectedIDs: expectedIDs)
    }

    static func parseClaude(_ data: Data, expectedIDs: Set<UUID>) throws -> [ActivityClassification] {
        guard let output = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              output["type"] as? String == "result" else { throw AnalysisError.invalidResponse }
        guard output["is_error"] as? Bool == false, output["subtype"] as? String == "success" else { throw AnalysisError.providerFailed }
        guard let result = output["result"] as? String, !result.isEmpty else { throw AnalysisError.emptyResponse }
        return try AnalysisPrompt.decode(Data(result.utf8), expectedIDs: expectedIDs)
    }
}
