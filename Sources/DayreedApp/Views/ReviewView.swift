import SwiftUI

struct ReviewView: View {
    let section: ReviewSection
    @Bindable var store: ReviewStore
    @State private var confirmRegeneration = false

    var body: some View {
        VStack(spacing: 0) {
            if let failure = store.failure {
                StatusBanner(text: failure, symbol: "exclamationmark.triangle")
            } else if let message = store.message {
                StatusBanner(text: message, symbol: "checkmark.circle")
            }
            if !store.service.capabilities.read {
                ContentUnavailableView {
                    Label("记录尚未连接", systemImage: section.symbol)
                } description: {
                    Text(store.service.unavailableReason ?? "本地记录服务不可用。")
                } actions: { SettingsLink { Text("查看采集与隐私设置") } }
            } else if store.isLoading {
                ProgressView("正在读取\(section.title)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !store.loaded {
                ContentUnavailableView("未能载入记录", systemImage: "externaldrive.badge.exclamationmark", description: Text("可使用工具栏刷新重试。"))
            } else if section == .timeline {
                TimelineView(store: store)
            } else {
                ReportView(store: store, kind: section == .daily ? .daily : .weekly)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if store.service.capabilities.regenerate {
                    Button(section == .timeline ? "重新分析" : "重新生成", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
                        confirmRegeneration = true
                    }.disabled(store.isWorking || store.isLoading || store.isDirty || !store.loaded)
                    .help(store.isDirty ? "请先保存修改" : "使用当前 Provider 和已启用的来源重新生成")
                }
            }
        }
        .confirmationDialog("\(section == .timeline ? "重新分析活动" : "重新生成报告")？", isPresented: $confirmRegeneration, titleVisibility: .visible) {
            Button("继续生成") { Task { await store.regenerate() } }
            Button("取消", role: .cancel) { }
        } message: {
            Text("选定的 Provider 将分析本时段已启用的来源，并替换当前\(section == .timeline ? "分析结果" : "报告内容")。")
        }
    }
}

struct StatusBanner: View {
    let text: String
    let symbol: String
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal).padding(.vertical, 10)
            .background(.quaternary.opacity(0.4))
            .accessibilityElement(children: .combine)
    }
}
