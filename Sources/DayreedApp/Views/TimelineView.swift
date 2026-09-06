import SwiftUI

struct TimelineView: View {
    @Bindable var store: ReviewStore
    @State private var selection: String?
    @State private var correction: ReviewEvent?
    private var selected: ReviewEvent? { store.snapshot.events.first { $0.id == selection } }

    var body: some View {
        if store.snapshot.events.isEmpty {
            ContentUnavailableView {
                Label("这一天没有活动记录", systemImage: "clock")
            } description: {
                Text("选择其他日期，或在设置中查看来源开关。所有来源均可关闭。")
            } actions: { SettingsLink { Text("采集与隐私设置") } }
        } else {
            HSplitView {
                List(store.snapshot.events.sorted { $0.start < $1.start }, selection: $selection) { event in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(event.start, style: .time).monospacedDigit()
                            Text("–")
                            Text(event.end, style: .time).monospacedDigit()
                        }.font(.caption).foregroundStyle(.secondary)
                        Text(event.title).font(.headline).lineLimit(2)
                        Text(event.application).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.padding(.vertical, 6).tag(event.id)
                    .accessibilityElement(children: .combine)
                    .contextMenu {
                        if store.service.capabilities.correctEvent {
                            Button("纠正记录…") { correction = event }
                        }
                    }
                }.frame(minWidth: 230, idealWidth: 300)
                Group {
                    if let selected {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 22) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(selected.title).font(.title2).textSelection(.enabled)
                                    Label(selected.application, systemImage: "app").foregroundStyle(.secondary)
                                    Text("\(selected.start.formatted(date: .omitted, time: .shortened)) – \(selected.end.formatted(date: .omitted, time: .shortened))")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                Text(selected.summary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                if store.service.capabilities.correctEvent {
                                    Button("纠正记录…", systemImage: "square.and.pencil") { correction = selected }
                                        .disabled(store.isWorking)
                                }
                                Divider()
                                EvidenceList(evidence: selected.evidence, canOpen: store.service.capabilities.openEvidence) { item in
                                    Task { await store.open(item) }
                                }
                            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        ContentUnavailableView("选择一条活动", systemImage: "sidebar.right", description: Text("查看摘要、纠正内容和记录依据。"))
                    }
                }.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }
            .onChange(of: store.query) { selection = nil }
            .sheet(item: $correction) { event in
                EventCorrectionView(event: event, store: store)
            }
        }
    }
}

struct EventCorrectionView: View {
    let event: ReviewEvent
    let store: ReviewStore
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var summary: String
    init(event: ReviewEvent, store: ReviewStore) {
        self.event = event; self.store = store
        _title = State(initialValue: event.title); _summary = State(initialValue: event.summary)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("纠正记录").font(.title2)
            TextField("标题", text: $title).textFieldStyle(.roundedBorder)
            Text("摘要").font(.headline)
            TextEditor(text: $summary).frame(minHeight: 160).border(.separator)
            Text("只修改活动的标题和摘要，记录依据由数据服务保留。").font(.caption).foregroundStyle(.secondary)
            if let failure = store.failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存纠正") {
                    Task { if await store.correct(event, title: title.trimmingCharacters(in: .whitespacesAndNewlines), summary: summary) { dismiss() } }
                }.keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isWorking)
            }
        }.padding(24).frame(width: 480).interactiveDismissDisabled(store.isWorking)
    }
}
