import SwiftUI

struct ReportView: View {
    @Bindable var store: ReviewStore
    let kind: ReportKind
    @State private var preview = true
    @State private var candidate: ReviewReportCandidate?
    @State private var showSources = false
    private var title: String { kind == .daily ? "每日回顾" : "每周回顾" }
    private var emptyPeriod: String { kind == .weekly ? "这一周" : Calendar.current.isDateInToday(store.query.date) ? "今天" : "这一天" }
    private var dateLabel: String {
        let interval = store.query.interval
        if kind == .daily { return interval.start.formatted(.dateTime.year().month().day().weekday()) }
        let end = Calendar.current.date(byAdding: .day, value: -1, to: interval.end)!
        return "\(interval.start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.snapshot.report?.needsReview == true {
                StatusBanner(text: "关联活动已纠正，请复核报告；手工内容已保留。", symbol: "exclamationmark.circle")
            }
            if !store.snapshot.candidates.isEmpty { candidateNotice }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(.largeTitle.weight(.semibold))
                        Spacer()
                        Label(store.isDirty ? "未保存" : store.snapshot.report == nil ? "尚未保存" : "已保存",
                              systemImage: store.isDirty ? "circle.fill" : "checkmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("report.saveStatus")
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        HStack {
                            Text(dateLabel).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: kind == .daily ? "sun.max" : "calendar")
                                .foregroundStyle(kind == .daily ? Color.blue : Color.purple).accessibilityHidden(true)
                        }
                        if preview {
                            if store.draft.isEmpty {
                                VStack(alignment: .leading, spacing: 16) {
                                    Text("留一页给\(emptyPeriod)").font(.title2)
                                    Divider()
                                    Text("写下完成的事情、遇到的问题，以及下一步。也可以从已保存的活动摘要生成候选稿。")
                                        .foregroundStyle(.secondary).lineSpacing(6)
                                    if store.service.capabilities.saveReport {
                                        Button("开始写回顾", systemImage: "square.and.pencil") { preview = false }
                                            .accessibilityIdentifier("report.startEditing")
                                    }
                                }.frame(minHeight: 220, alignment: .topLeading)
                                .accessibilityIdentifier("report.empty")
                            } else {
                                MarkdownPreview(markdown: store.draft)
                                    .frame(minHeight: 240, alignment: .topLeading)
                                    .accessibilityIdentifier("report.preview")
                            }
                        } else {
                            Text("Markdown 编辑").font(.headline)
                            Divider()
                            TextEditor(text: $store.draft)
                                .font(.system(.body, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 340)
                                .accessibilityLabel("\(kind == .daily ? "日报" : "周报") Markdown 内容")
                                .accessibilityIdentifier("report.editor")
                                .disabled(!store.service.capabilities.saveReport || store.isWorking)
                        }
                        Divider()
                        HStack {
                            Text(store.snapshot.report?.isEdited == true ? "手工整理 · 内容存储在本机" : "内容存储在本机")
                            Spacer()
                            if let report = store.snapshot.report {
                                Text("更新于 \(report.updatedAt.formatted(date: .omitted, time: .shortened))")
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
                    DisclosureGroup("关联来源 · \(store.snapshot.report?.sources.count ?? 0)", isExpanded: $showSources) {
                        EvidenceList(evidence: store.snapshot.report?.sources ?? [], canOpen: store.service.capabilities.openEvidence) { item in
                            Task { await store.open(item) }
                        }.padding(.top, 16)
                    }.accessibilityIdentifier("report.sources")
                }.padding(28).frame(maxWidth: 840, alignment: .leading).frame(maxWidth: .infinity)
            }.background(Color(nsColor: .underPageBackgroundColor))
            HStack(spacing: 16) {
                Picker("内容模式", selection: $preview) {
                    Text("阅读").tag(true)
                    Text("编辑").tag(false)
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("内容模式")
                    .frame(width: 140).accessibilityIdentifier("report.mode")
                if store.isWorking { ProgressView().controlSize(.small) }
                Spacer()
                if store.service.capabilities.saveReport {
                    Button("保存", systemImage: "square.and.arrow.down") { Task { await store.save() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!store.isDirty || store.isWorking)
                        .accessibilityIdentifier("report.save")
                } else { Text("当前连接只读").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 24).padding(.vertical, 12)
        }.sheet(item: $candidate) { ReportCandidateView(candidate: $0, store: store) }
    }

    private var candidateNotice: some View {
        HStack {
            Label("\(store.snapshot.candidates.count) 份候选稿等待审查", systemImage: "doc.badge.clock")
                .font(.callout)
            Spacer()
            Menu("审查候选稿") {
                ForEach(store.snapshot.candidates) { item in
                    Button(item.createdAt.formatted(date: .abbreviated, time: .standard)) { candidate = item }
                }
            }.disabled(store.isDirty || store.isWorking).accessibilityIdentifier("report.candidates")
                .help(store.isDirty ? "请先保存修改再审查候选稿" : "审查后决定是否替换当前报告")
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }
}

/// Native selectable Markdown with readable headings and paragraph spacing.
struct MarkdownPreview: View {
    let markdown: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("### ") { inline(String(line.dropFirst(4))).font(.headline).padding(.top, 6) }
                else if line.hasPrefix("## ") {
                    Divider().padding(.vertical, 4)
                    inline(String(line.dropFirst(3))).font(.title3.weight(.semibold))
                }
                else if line.hasPrefix("# ") { inline(String(line.dropFirst(2))).font(.system(.title, design: .serif).weight(.medium)) }
                else if line == "---" || line == "***" { Divider().padding(.vertical, 4) }
                else if line.hasPrefix("- ") { HStack(alignment: .top, spacing: 10) { Text("•").foregroundStyle(.secondary); inline(String(line.dropFirst(2))) } }
                else if line.isEmpty { Color.clear.frame(height: 3).accessibilityHidden(true) }
                else { inline(line) }
            }
        }.font(.body).lineSpacing(6).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }
    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }
}
