import SwiftUI

struct ContentView: View {
    @SceneStorage("reviewSection") private var selection = ReviewSection.timeline.rawValue

    private var selectedSection: ReviewSection {
        ReviewSection(rawValue: selection) ?? .timeline
    }

    var body: some View {
        NavigationSplitView {
            List(ReviewSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section.rawValue)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 260)
        } detail: {
            ReviewView(section: selectedSection)
                .navigationTitle(selectedSection.title)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                SettingsLink {
                    Label("设置", systemImage: "gearshape")
                }
                .help("设置（⌘,）")
            }
        }
    }
}
