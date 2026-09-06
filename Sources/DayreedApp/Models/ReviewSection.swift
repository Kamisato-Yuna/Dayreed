enum ReviewSection: String, CaseIterable, Identifiable {
    case timeline, daily, weekly

    var id: Self { self }

    var title: String {
        switch self {
        case .timeline: "时间线"
        case .daily: "日报"
        case .weekly: "周报"
        }
    }

    var symbol: String {
        switch self {
        case .timeline: "clock"
        case .daily: "doc.text"
        case .weekly: "calendar"
        }
    }
}
