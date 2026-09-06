import DayreedCore
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, privacy, provider, agent, updates
    var id: Self { self }
    var title: String {
        switch self {
        case .general: "一般"
        case .privacy: "采集与隐私"
        case .provider: "AI Provider"
        case .agent: "Agent"
        case .updates: "更新"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .privacy: "hand.raised"
        case .provider: "cpu"
        case .agent: "terminal"
        case .updates: "arrow.down.circle"
        }
    }
}

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @AppStorage("showMenuBar") private var showMenuBar = false
    @State private var section: SettingsSection = .general
    @State private var store: SettingsStore
    @State private var confirmPrivacy = false
    init(service: any ReviewService) { _store = State(initialValue: SettingsStore(service: service)) }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }.navigationSplitViewColumnWidth(170)
        } detail: {
            VStack(spacing: 0) {
                Form {
                    switch section {
                    case .general: general
                    case .privacy: privacy
                    case .provider: provider
                    case .agent: agent
                    case .updates: updates
                    }
                }.formStyle(.grouped)
                if let message = store.message {
                    StatusBanner(text: message, symbol: store.failed ? "exclamationmark.triangle" : "checkmark.circle")
                }
                if store.isDirty {
                    Divider()
                    HStack {
                        Text("有未应用的设置").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("还原") { store.discard() }
                        Button("应用设置") { confirmPrivacy = true }
                            .buttonStyle(.borderedProminent)
                    }.padding().disabled(store.isWorking)
                }
            }.navigationTitle(section.title)
        }
        .frame(minWidth: 680, idealWidth: 740, minHeight: 460, idealHeight: 560)
        .task { await store.load() }
        .confirmationDialog("应用这些设置？", isPresented: $confirmPrivacy, titleVisibility: .visible) {
            Button("应用") { Task { await store.save() } }
            Button("取消", role: .cancel) { }
        } message: {
            Text("启用的来源：\(enabledSources)。Provider 仅可分析这些来源。Agent \(store.draft.agentAllowsChanges ? "允许修改" : "保持只读")，\(store.draft.agentIncludesRawContent ? "允许输出原始内容" : "不输出原始内容")。系统权限仍由你决定。")
        }
    }

    private var enabledSources: String {
        let titles = store.draft.sources.filter(\.enabled).map { $0.source.title }
        return titles.isEmpty ? "全部关闭" : titles.joined(separator: "、")
    }
    @ViewBuilder private var general: some View {
        Section("外观") {
            Picker("主题", selection: $appearance) {
                ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Text("字体、透明度与动态效果遵循系统辅助功能设置。").font(.caption).foregroundStyle(.secondary)
        }
        Section("菜单栏") {
            Toggle("在菜单栏显示 Dayreed", isOn: $showMenuBar)
        }
        Section("关于 Dayreed") {
            LabeledContent("版本", value: "\(ProductInfo.version) (\(ProductInfo.build))")
            Text("安静地记录，清晰地回顾。个人时间线、日报与周报。").foregroundStyle(.secondary)
            LabeledContent("许可", value: "MIT")
            Link("GitHub 项目", destination: URL(string: ProductInfo.repository)!)
        }
        Section("键盘") {
            LabeledContent("时间线 / 日报 / 周报", value: "⌘1 / ⌘2 / ⌘3")
            LabeledContent("前后日期", value: "⌘[ / ⌘]")
            LabeledContent("回到今天 / 保存报告", value: "⇧⌘T / ⌘S")
        }
    }
    @ViewBuilder private var privacy: some View {
        Section {
            Text(store.draft.status).foregroundStyle(.secondary)
            Text("每种来源独立选择，也可以全部关闭。启用开关不代表系统权限已授予。").font(.callout)
        }
        Section("采集来源") {
            ForEach($store.draft.sources) { $source in
                Toggle(isOn: $source.enabled) {
                    Label(source.source.title, systemImage: source.source.symbol)
                    Text("权限：\(source.permission)").font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(!store.service.capabilities.configure || store.isWorking)
        }
        Section("保留时间") {
            Picker("原始内容保留", selection: $store.draft.retentionDays) {
                Text("7 天").tag(7)
                Text("30 天").tag(30)
                Text("90 天").tag(90)
                if ![7, 30, 90].contains(store.draft.retentionDays) {
                    Text("\(store.draft.retentionDays) 天").tag(store.draft.retentionDays)
                }
            }.disabled(!store.service.capabilities.configure || store.isWorking)
            Text("缩短保留时间可能清除到期原始内容。具体清理结果由本地存储服务确认。").font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var provider: some View {
        Section("分析服务") {
            if store.draft.providers.isEmpty {
                Text("尚未配置 Provider").font(.headline)
                Text("连接 Provider 配置服务后，这里会显示可选模型与凭据状态。当前不会发送任何内容。").foregroundStyle(.secondary)
            } else {
                Picker("选定 Provider", selection: $store.draft.selectedProviderID) {
                    Text("不使用").tag(String?.none)
                    ForEach(store.draft.providers) { Text($0.name).tag(Optional($0.id)) }
                }.disabled(!store.service.capabilities.configure || store.isWorking)
                if let choice = store.draft.providers.first(where: { $0.id == store.draft.selectedProviderID }) {
                    Text(choice.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Section("来源范围") {
            LabeledContent("可分析来源", value: enabledSources)
            Text("截图、应用切换、窗口标题和辅助功能文本只在各自启用后供选定的 Provider 分析。凭据由系统 Keychain 管理，不显示在回顾页面或日志中。").font(.callout).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var agent: some View {
        Section("本机 Agent") {
            Toggle("允许 Agent 访问", isOn: $store.draft.agentEnabled)
            Text("默认关闭。启用后默认只读，不输出原始截图或原始文本。").font(.caption).foregroundStyle(.secondary)
        }.disabled(!store.service.capabilities.configure || store.isWorking)
        Section("访问范围") {
            Toggle("允许修改整理结果", isOn: $store.draft.agentAllowsChanges)
            Toggle("允许输出原始内容", isOn: $store.draft.agentIncludesRawContent)
            Text("扩大范围会增加可访问的数据。应用设置前将再次列出你的选择。").font(.caption).foregroundStyle(.secondary)
        }.disabled(!store.service.capabilities.configure || !store.draft.agentEnabled || store.isWorking)
    }
    @ViewBuilder private var updates: some View {
        Section("应用更新") {
            LabeledContent("当前版本", value: "\(ProductInfo.version) (\(ProductInfo.build))")
            if store.service.capabilities.checkUpdates {
                Button("检查更新") { Task { await store.checkUpdates() } }.disabled(store.isWorking)
            } else {
                Text("自动更新服务尚未连接。可前往项目发布页查看正式版本。").foregroundStyle(.secondary)
            }
            Link("打开发布页", destination: URL(string: ProductInfo.repository + "/releases")!)
        }
    }
}
