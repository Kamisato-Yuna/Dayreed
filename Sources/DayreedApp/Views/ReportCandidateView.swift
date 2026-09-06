import SwiftUI

struct ReportCandidateView: View {
    let candidate: ReviewReportCandidate
    @Bindable var store: ReviewStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("审查候选稿").font(.title2)
            Text("现有报告仍保留。采用此候选稿才会替换报告；如果来源或报告已有新修改，需要重新生成候选。").font(.callout).foregroundStyle(.secondary)
            ScrollView { MarkdownPreview(markdown: candidate.markdown).padding() }
            if let failure = store.failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Button("丢弃候选稿", role: .destructive) { Task { await store.reviewCandidate(candidate, accept: false); closeIfRemoved() } }
                Spacer()
                Button("稍后审查") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("采用并替换报告…") { confirm = true }.buttonStyle(.borderedProminent)
            }.disabled(store.isWorking || store.isDirty)
        }.padding(24).frame(minWidth: 620, minHeight: 500)
        .interactiveDismissDisabled(store.isWorking)
        .confirmationDialog("采用候选稿并替换报告？", isPresented: $confirm, titleVisibility: .visible) {
            Button("替换报告") { Task { await store.reviewCandidate(candidate, accept: true); closeIfRemoved() } }
            Button("取消", role: .cancel) { }
        } message: { Text("已经保存的手工报告内容也会被此候选稿替换。") }
    }
    private func closeIfRemoved() {
        if !store.snapshot.candidates.contains(where: { $0.id == candidate.id }) { dismiss() }
    }
}
