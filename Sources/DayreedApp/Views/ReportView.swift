import SwiftUI

struct ReportView: View {
    @Bindable var store: ReviewStore
    let kind: ReportKind
    @State private var preview = false
    @State private var showSources = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(store.snapshot.report == nil ? "新建\(kind == .daily ? "日报" : "周报")" : "\(kind == .daily ? "每日" : "每周")回顾", systemImage: "doc.text")
                    .font(.headline)
                Spacer()
                if store.isWorking { ProgressView().controlSize(.small) }
                Text(store.isDirty ? "未保存" : store.snapshot.report == nil ? "尚未保存" : "已保存")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("内容模式", selection: $preview) {
                    Text("编辑").tag(false)
                    Text("预览").tag(true)
                }.pickerStyle(.segmented).frame(width: 130)
            }.padding()
            Divider()
            if preview {
                ScrollView {
                    if store.draft.isEmpty {
                        ContentUnavailableView("尚无内容", systemImage: "doc", description: Text("切换到编辑，写下这段时间的回顾。"))
                    } else {
                        MarkdownPreview(markdown: store.draft).padding(24)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $store.draft)
                        .font(.system(.body, design: .monospaced))
                        .padding(12)
                        .accessibilityLabel("\(kind == .daily ? "日报" : "周报") Markdown 内容")
                        .disabled(!store.service.capabilities.saveReport || store.isWorking)
                    if store.draft.isEmpty {
                        Text("使用 Markdown 写下回顾…")
                            .foregroundStyle(.tertiary).padding(.horizontal, 18).padding(.top, 14)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            ScrollView {
                DisclosureGroup("关联来源", isExpanded: $showSources) {
                    EvidenceList(evidence: store.snapshot.report?.sources ?? [], canOpen: store.service.capabilities.openEvidence) { item in
                        Task { await store.open(item) }
                    }.padding(.top, 12)
                }.padding()
            }.frame(maxHeight: showSources ? 180 : 48)
            HStack {
                if let report = store.snapshot.report {
                    Text("更新于 \(report.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                } else { Text("内容存储在本机").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if store.service.capabilities.saveReport {
                    Button("保存", systemImage: "square.and.arrow.down") { Task { await store.save() } }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!store.isDirty || store.isWorking)
                } else { Text("当前连接只读").font(.caption).foregroundStyle(.secondary) }
            }.padding()
        }
    }
}

/// Native selectable Markdown. Block separators are preserved instead of flattening the document into one Text.
struct MarkdownPreview: View {
    let markdown: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("### ") { inline(String(line.dropFirst(4))).font(.headline) }
                else if line.hasPrefix("## ") { inline(String(line.dropFirst(3))).font(.title2) }
                else if line.hasPrefix("# ") { inline(String(line.dropFirst(2))).font(.title) }
                else if line.hasPrefix("- ") { HStack(alignment: .top) { Text("•"); inline(String(line.dropFirst(2))) } }
                else { inline(line.isEmpty ? " " : line) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }
    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }
}
