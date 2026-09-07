import AppKit
import DayreedCore
import SwiftUI

struct ProviderEditorView: View {
    let existing: ProviderConfiguration?
    let onSave: (ProviderConfiguration, String?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProviderDraft
    @State private var apiKey = ""
    @State private var working = false
    @State private var failure: String?

    init(configuration: ProviderConfiguration?, onSave: @escaping (ProviderConfiguration, String?) async throws -> Void) {
        existing = configuration
        self.onSave = onSave
        _draft = State(initialValue: ProviderDraft(configuration: configuration))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(existing == nil ? "添加 Provider" : "编辑 Provider") {
                    TextField("名称", text: $draft.name)
                    Picker("类型", selection: $draft.kind) {
                        Text("OpenAI 兼容接口").tag(ProviderConfiguration.Kind.openAICompatible)
                        Text("本机 Codex CLI").tag(ProviderConfiguration.Kind.codexCLI)
                        Text("本机 Claude CLI").tag(ProviderConfiguration.Kind.claudeCLI)
                    }
                    TextField("模型", text: $draft.model)
                    if draft.kind == .openAICompatible {
                        TextField("完整 chat/completions URL", text: $draft.endpoint, prompt: Text("https://…/v1/chat/completions"))
                        Text("使用 HTTPS；本机 localhost / 127.0.0.1 接口可以使用 HTTP。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            TextField("CLI 可执行文件的完整路径", text: $draft.executablePath)
                            Button("选择…") { choosePath(directory: false) { draft.executablePath = $0 } }
                        }
                        Picker("认证方式", selection: $draft.authentication) {
                            Text("Dayreed Keychain API Key").tag(ProviderConfiguration.CLIAuthentication.dayreedAPIKey)
                            Text("使用指定 CLI 目录的现有登录").tag(ProviderConfiguration.CLIAuthentication.existingLogin)
                        }
                        if draft.authentication == .existingLogin {
                            HStack {
                                TextField("CLI 登录配置目录的完整路径", text: $draft.loginDirectory)
                                Button("选择…") { choosePath(directory: true) { draft.loginDirectory = $0 } }
                            }
                            Text("只使用你指定目录里的 CLI 认证。已启用的采集来源将交给此 CLI 和其配置的服务；Dayreed 不自动发现其他登录。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if draft.kind == .openAICompatible || draft.authentication == .dayreedAPIKey {
                    Section("凭据") {
                        SecureField("API Key", text: $apiKey)
                        Text(existing == nil ? "密钥只保存到 Dayreed 专用系统 Keychain。" : "留空保留已有密钥；输入新密钥将更新 Dayreed Keychain。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("能力与等待时间") {
                    Toggle("模型支持截图输入", isOn: $draft.supportsImages).disabled(draft.kind == .claudeCLI)
                    if draft.kind == .claudeCLI {
                        Text("Claude CLI 当前只支持文本来源。截图可继续本地采集，但该 Provider 无法分析截图。").font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("超时秒数（1–600）", value: $draft.timeoutSeconds, format: .number)
                    Text("保存配置不发送记录。分析仅由选定 Provider 处理已启用的来源；自动分析需要单独开启。").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).disabled(working)
            if let failure { Text(failure).foregroundStyle(.red).padding(.horizontal) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { apiKey = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存 Provider") {
                    working = true; failure = nil
                    Task {
                        defer { working = false }
                        do {
                            let configuration = try draft.configuration()
                            let key = apiKey.isEmpty ? nil : apiKey
                            try await onSave(configuration, key)
                            apiKey = ""; dismiss()
                        } catch {
                            failure = (error as? ReviewServiceError)?.errorDescription ?? ReviewServiceError.failed.errorDescription
                        }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding().disabled(working)
        }.frame(width: 660, height: 640)
        .interactiveDismissDisabled(working)
        .onChange(of: draft.kind) { _, new in apiKey = ""; if new == .claudeCLI { draft.supportsImages = false } }
        .onChange(of: draft.authentication) { _, _ in apiKey = "" }
        .onDisappear { apiKey = "" }
    }

    private func choosePath(directory: Bool, selected: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url { selected(url.path) }
    }
}
