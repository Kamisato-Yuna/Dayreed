import SwiftUI

struct ReviewView: View {
    let section: ReviewSection
    @Bindable var store: ReviewStore
    @State private var confirmRegeneration = false

    var body: some View {
        VStack(spacing: 0) {
            if section == .timeline, let live = store.service as? LiveReviewService, let analysis = live.analysis {
                AnalysisStatusView(service: live, review: store, analysis: analysis)
            }
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
                if store.canGenerate {
                    Button(section == .timeline ? "重新分析" : "重新生成", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
                        confirmRegeneration = true
                    }.disabled(store.isWorking || store.isLoading || store.isDirty || !store.loaded)
                    .help(store.isDirty ? "请先保存修改" : (section == .timeline ? "分析已启用来源" : "从已保存摘要生成候选报告"))
                }
            }
        }
        .confirmationDialog("\(section == .timeline ? "重新分析活动" : "重新生成报告")？", isPresented: $confirmRegeneration, titleVisibility: .visible) {
            Button("继续生成") { Task { await store.regenerate() } }
            Button("取消", role: .cancel) { }
        } message: {
            Text(section == .timeline ? "选定的 Provider 将分析本时段已启用的来源，保留人工纠正。" : "将本时段已保存的活动摘要整理为报告候选稿。原报告保持不变，由你审查后决定是否替换。")
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
