import SwiftUI

struct AnalysisStatusView: View {
    let service: LiveReviewService
    let review: ReviewStore
    @Bindable var analysis: LiveAnalysisController
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(analysis.statusText)
                Text(analysis.guidanceText).font(.caption).foregroundStyle(.secondary)
                Text("已应用来源：\(service.enabledSourceDescription)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if analysis.selectedID == nil { SettingsLink { Text("配置 Provider") } }
            if analysis.status.phase == .running {
                Button("取消分析") { Task { try? await analysis.cancel() } }
            }
        }.font(.callout).padding(.horizontal).padding(.vertical, 8)
        .onChange(of: analysis.status.updatedAt) { _, _ in
            if analysis.status.phase == .completed && analysis.status.processedRecords > 0 {
                Task { await review.reload() }
            }
        }
        .task {
            while !Task.isCancelled {
                await analysis.refreshStatus()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}
