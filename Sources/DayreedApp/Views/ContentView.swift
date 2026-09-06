import SwiftUI

struct ContentView: View {
    @SceneStorage("reviewSection") private var selection = ReviewSection.timeline.rawValue
    @State private var store: ReviewStore
    @State private var pendingQuery: ReviewQuery?
    @State private var pendingSection: ReviewSection?
    @State private var showDiscard = false

    init(service: any ReviewService) { _store = State(initialValue: ReviewStore(service: service)) }
    init(store: ReviewStore) { _store = State(initialValue: store) }
    private var section: ReviewSection { ReviewSection(rawValue: selection) ?? .timeline }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { selection }, set: { choose($0) })) {
                Section("回顾") {
                    ForEach(ReviewSection.allCases) { item in
                        Label(item.title, systemImage: item.symbol).tag(item.rawValue)
                            .accessibilityIdentifier("navigation.\(item.rawValue)")
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 190, max: 250)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Label("Dayreed", systemImage: "leaf")
                    Spacer()
                    SettingsLink { Image(systemName: "gearshape") }.help("设置（⌘,）")
                }.font(.callout).foregroundStyle(.secondary).padding()
            }
        } detail: {
            ReviewView(section: section, store: store)
                .navigationTitle(section.title)
                .navigationSubtitle(subtitle)
                .toolbar { dateToolbar }
        }
        .onChange(of: (store.service as? LiveReviewService)?.revision) { _, _ in Task { await store.refreshAfterDeletion() } }
        .onChange(of: (store.service as? LiveReviewService)?.coordinator?.state.lastRecordID) { _, _ in Task { await store.reload() } }
        .task { await store.navigate(to: query(for: section, date: store.query.date)) }
        .confirmationDialog("保留未保存的修改？", isPresented: $showDiscard, titleVisibility: .visible) {
            Button("放弃修改并继续", role: .destructive) {
                store.discardDraft()
                if let pendingSection { selection = pendingSection.rawValue }
                if let pendingQuery { Task { await store.navigate(to: pendingQuery) } }
            }.accessibilityIdentifier("navigation.discardChanges")
            Button("继续编辑", role: .cancel) { pendingQuery = nil; pendingSection = nil }
                .accessibilityIdentifier("navigation.keepEditing")
        } message: { Text("当前 Markdown 草稿尚未保存。继续编辑可保留草稿。") }
        .background {
            // Menu shortcuts remain available when the sidebar is collapsed.
            ForEach(Array(ReviewSection.allCases.enumerated()), id: \.element.id) { index, item in
                Button(item.title) { choose(item.rawValue) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .hidden()
            }
        }
    }

    private var subtitle: String {
        if section == .weekly {
            let interval = store.query.interval
            let end = Calendar.current.date(byAdding: .day, value: -1, to: interval.end)!
            return "\(interval.start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
        }
        return store.query.date.formatted(.dateTime.year().month().day().weekday())
    }

    @ToolbarContentBuilder private var dateToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("上一\(section == .weekly ? "周" : "天")", systemImage: "chevron.left") { move(-1) }
                .keyboardShortcut("[", modifiers: .command).accessibilityIdentifier("date.previous")
            DatePicker("浏览日期", selection: Binding(get: { store.query.date }, set: { request(query(for: section, date: $0)) }), displayedComponents: .date)
                .accessibilityIdentifier("date.picker").labelsHidden().help("选择回顾日期")
            Button("下一\(section == .weekly ? "周" : "天")", systemImage: "chevron.right") { move(1) }
                .keyboardShortcut("]", modifiers: .command).accessibilityIdentifier("date.next")
            Button("今天") { request(query(for: section, date: .now)) }
                .keyboardShortcut("t", modifiers: [.command, .shift]).accessibilityIdentifier("date.today")
        }
        ToolbarItem(placement: .automatic) {
            Button("刷新", systemImage: "arrow.clockwise") { Task { await store.reload() } }
                .disabled(!store.service.capabilities.read || store.isDirty || store.isLoading || store.isWorking)
                .accessibilityIdentifier("review.refresh")
                .help(store.isDirty ? "请先保存草稿" : "重新载入当前日期")
        }
    }

    private func query(for section: ReviewSection, date: Date) -> ReviewQuery {
        ReviewQuery(date: date, kind: section == .timeline ? nil : section == .daily ? .daily : .weekly)
    }
    private func choose(_ raw: String) {
        guard let next = ReviewSection(rawValue: raw), next != section, !store.isWorking else { return }
        request(query(for: next, date: store.query.date), section: next)
    }
    private func move(_ delta: Int) {
        let date = Calendar.current.date(byAdding: .day, value: delta * (section == .weekly ? 7 : 1), to: store.query.date)!
        request(query(for: section, date: date))
    }
    private func request(_ next: ReviewQuery, section: ReviewSection? = nil) {
        guard !store.isWorking else { return }
        if store.isDirty {
            pendingQuery = next; pendingSection = section; showDiscard = true
        } else {
            if let section { selection = section.rawValue }
            Task { await store.navigate(to: next) }
        }
    }
}
