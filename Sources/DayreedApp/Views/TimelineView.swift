import SwiftUI

struct TimelineView: View {
    @Bindable var store: ReviewStore
    @State private var correction: ReviewEvent?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var events: [ReviewEvent] { store.snapshot.events.sorted { $0.start < $1.start } }

    var body: some View {
        Group {
            if events.isEmpty {
                ContentUnavailableView {
                    Label("这一天没有活动记录", systemImage: "clock")
                } description: {
                    Text("选择其他日期，或在设置中查看来源开关。所有来源均可关闭。")
                } actions: { SettingsLink { Text("采集与隐私设置") } }
                .accessibilityIdentifier("timeline.empty")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("这一天的足迹").font(.largeTitle.weight(.semibold))
                            Text("\(events.count) 条活动 · 展开查看摘要与记录依据")
                                .font(.callout).foregroundStyle(.secondary)
                        }.padding(.leading, 24)
                        LazyVStack(spacing: 0) {
                            ForEach(events) { event in
                                TimelineActivityCard(event: event,
                                    expanded: store.selectedEventID == event.id,
                                    isLast: event.id == events.last?.id,
                                    canCorrect: store.service.capabilities.correctEvent && event.isCorrectable,
                                    isWorking: store.isWorking,
                                    canOpenEvidence: store.service.capabilities.openEvidence,
                                    toggle: {
                                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                            store.selectedEventID = store.selectedEventID == event.id ? nil : event.id
                                        }
                                    },
                                    correct: { correction = event },
                                    open: { item in Task { await store.open(item) } })
                            }
                        }
                    }.padding(28).frame(maxWidth: 920, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }.accessibilityIdentifier("timeline.activities")
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .sheet(item: $correction) { event in EventCorrectionView(event: event, store: store) }
    }
}

private struct TimelineActivityCard: View {
    let event: ReviewEvent
    let expanded: Bool
    let isLast: Bool
    let canCorrect: Bool
    let isWorking: Bool
    let canOpenEvidence: Bool
    let toggle: () -> Void
    let correct: () -> Void
    let open: (ReviewEvidence) -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    // Colors describe the available evidence, without inferring an activity category.
    private var accent: Color {
        event.evidence.contains { $0.source == .screenshot } ? .blue :
        event.evidence.contains { $0.source == .accessibility } ? .purple : .green
    }
    private var symbol: String {
        event.evidence.contains { $0.source == .screenshot } ? "photo" :
        event.evidence.contains { $0.source == .accessibility } ? "text.alignleft" : "app"
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Rectangle().fill(.separator).frame(width: 1, height: 26)
                Circle().fill(accent).frame(width: 8, height: 8)
                    .padding(3).background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(Circle().strokeBorder(accent.opacity(0.25)))
                Rectangle().fill(isLast ? Color.clear : Color(nsColor: .separatorColor)).frame(width: 1)
            }.frame(width: 12).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Button(action: toggle) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            timeColumn.frame(width: 58)
                            icon
                            summary
                            chevron
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { timeColumn; Spacer(); icon; chevron }
                            summary
                        }
                    }.padding(20).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .focused($focused)
                    .onHover { hovered = $0 }
                    .background(accent.opacity(hovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(focused ? accent : .clear, lineWidth: 2))
                    .accessibilityLabel("\(event.start.formatted(date: .omitted, time: .shortened))，\(event.title)")
                    .accessibilityValue(expanded ? "已展开" : "已收起")
                    .accessibilityHint("展开或收起活动详情")
                    .accessibilityIdentifier("timeline.activity.\(event.id)")
                if expanded {
                    VStack(alignment: .leading, spacing: 18) {
                        Divider()
                        Text(event.summary).lineSpacing(5).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !event.stateTitle.isEmpty {
                            Label(event.stateTitle, systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if canCorrect {
                            Button("纠正记录…", systemImage: "square.and.pencil", action: correct)
                                .disabled(isWorking).accessibilityIdentifier("timeline.correct.\(event.id)")
                        }
                        Divider()
                        EvidenceList(evidence: event.evidence, canOpen: canOpenEvidence, open: open)
                    }.padding([.horizontal, .bottom], 20)
                    .accessibilityIdentifier("timeline.detail.\(event.id)")
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(expanded ? accent.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.5)))
            .padding(.bottom, 14)
        }.fixedSize(horizontal: false, vertical: true)
    }
    private var timeColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.start, format: .dateTime.hour().minute()).foregroundStyle(.primary)
            if event.end > event.start {
                Text(event.end, format: .dateTime.hour().minute()).foregroundStyle(.secondary)
            }
        }.font(.caption.monospacedDigit()).fixedSize()
    }
    private var icon: some View {
        Image(systemName: symbol).font(.title3).foregroundStyle(accent)
            .frame(width: 38, height: 40)
            .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            .accessibilityHidden(true)
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(event.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            if !expanded { Text(event.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            Text(event.application).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var chevron: some View {
        Image(systemName: expanded ? "chevron.up" : "chevron.down")
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
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
            TextField("标题", text: $title).textFieldStyle(.roundedBorder).accessibilityIdentifier("correction.title")
            Text("摘要").font(.headline)
            TextEditor(text: $summary).frame(minHeight: 160).border(.separator).accessibilityLabel("纠正摘要").accessibilityIdentifier("correction.summary")
            Text("只修改活动的标题和摘要，记录依据由数据服务保留。").font(.caption).foregroundStyle(.secondary)
            if let failure = store.failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.isWorking)
                    .accessibilityIdentifier("correction.cancel")
                Button("保存纠正") {
                    Task { if await store.correct(event, title: title.trimmingCharacters(in: .whitespacesAndNewlines), summary: summary) { dismiss() } }
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("correction.save")
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isWorking)
            }
        }.padding(24).frame(width: 480).interactiveDismissDisabled(store.isWorking)
    }
}
