import DayreedCore
import SwiftUI

private struct ProviderEditorSelection: Identifiable {
    let id = UUID()
    let configuration: ProviderConfiguration?
}

struct ProviderSettingsView: View {
    let service: LiveReviewService
    @Bindable var analysis: LiveAnalysisController
    @State private var editor: ProviderEditorSelection?
    @State private var removing: ProviderConfiguration?
    @State private var interval = 300.0
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Section("分析 Provider") {
            Picker("选定 Provider", selection: Binding(get: { analysis.selectedID }, set: { id in run { try await analysis.select(id) } })) {
                Text("不使用").tag(UUID?.none)
                ForEach(analysis.configurations) { Text($0.name).tag(Optional($0.id)) }
            }.disabled(working || analysis.isConfiguring)
            ForEach(analysis.configurations) { configuration in
                HStack {
                    VStack(alignment: .leading) {
                        Text(configuration.name)
                        Text(configuration.model).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("编辑") { editor = ProviderEditorSelection(configuration: configuration) }
                    Button("删除", role: .destructive) { removing = configuration }
                }.disabled(working || analysis.isConfiguring)
            }
            Button("添加 Provider…") { editor = ProviderEditorSelection(configuration: nil) }.disabled(working || analysis.isConfiguring)
            if let failure = analysis.configurationFailure { Text(failure).foregroundStyle(.red) }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
        }
        Section("实际发送范围") {
            LabeledContent("已应用的来源", value: service.enabledSourceDescription)
            Text("只分析已应用并启用的来源。截图和原文只交给你选定的 Provider；没有选择 Provider 时不开始分析。API Key 不进入 UserDefaults、报告或日志。").font(.callout).foregroundStyle(.secondary)
        }
        Section("自动分析") {
            Toggle("自动分析新记录", isOn: Binding(get: { analysis.schedule.enabled }, set: { enabled in
                run { try await analysis.configureSchedule(enabled: enabled, everySeconds: interval) }
            })).disabled(working || analysis.isConfiguring || (analysis.selectedID == nil && !analysis.schedule.enabled))
            LabeledContent("调度时区", value: analysis.schedule.timeZoneIdentifier)
            TextField("检查间隔秒数（5–86400）", value: $interval, format: .number)
            Button("应用间隔") { run { try await analysis.configureSchedule(enabled: analysis.schedule.enabled, everySeconds: interval) } }
                .disabled(working || analysis.isConfiguring || interval == analysis.schedule.everySeconds)
            Text("默认关闭。开启后按所示时区处理当天尚未分析的记录；暂停、停止或全关时不发送请求，不覆盖人工纠正，也不自动生成报告候选。").font(.caption).foregroundStyle(.secondary)
        }
        Section("分析状态") {
            Text(analysis.statusText)
            if analysis.status.phase == .running {
                Button("取消当前分析") { run { try await analysis.cancel() } }
            }
        }
        .task {
            interval = analysis.schedule.everySeconds
            while !Task.isCancelled {
                await analysis.refreshStatus()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .sheet(item: $editor) { item in
            ProviderEditorView(configuration: item.configuration) { configuration, key in
                try await analysis.save(configuration, key: key)
                message = "Provider 已保存；请在列表中选定用于分析的配置。"
            }
        }
        .confirmationDialog("删除此 Provider？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let removing { Button("删除 \(removing.name)", role: .destructive) { run { try await analysis.remove(removing.id) } } }
            Button("取消", role: .cancel) { }
        } message: { Text("移除此 Provider 配置及其 Dayreed Keychain 密钥，已保存的时间线和报告仍保留。") }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        working = true; message = nil
        Task {
            defer { working = false }
            do { try await operation(); message = "设置已保存" }
            catch { message = (error as? ReviewServiceError)?.errorDescription ?? ReviewServiceError.failed.errorDescription }
        }
    }
}
