import SwiftUI

struct ReviewView: View {
    let section: ReviewSection

    var body: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: section.symbol)
        } description: {
            Text(emptyDescription)
        }
    }

    private var emptyTitle: String {
        switch section {
        case .timeline: "尚无活动记录"
        case .daily: "尚无日报"
        case .weekly: "尚无周报"
        }
    }

    private var emptyDescription: String {
        switch section {
        case .timeline: "这里用于回顾一天的活动与记录依据。"
        case .daily: "这里用于检查和整理每天的工作记录。"
        case .weekly: "这里用于回顾一周的工作与变化。"
        }
    }
}
