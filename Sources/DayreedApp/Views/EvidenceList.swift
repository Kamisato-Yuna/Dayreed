import SwiftUI

struct EvidenceList: View {
    let evidence: [ReviewEvidence]
    let canOpen: Bool
    let open: (ReviewEvidence) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("记录依据 · \(evidence.count)").font(.headline)
            if evidence.isEmpty {
                Text("没有关联的来源。").foregroundStyle(.secondary)
            } else {
                Text("仅在你打开时查看原始依据。").font(.caption).foregroundStyle(.secondary)
                ForEach(evidence) { item in
                    HStack(alignment: .top) {
                        Image(systemName: item.source.symbol).frame(width: 20).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.label)
                            Text("\(item.source.title) · \(item.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if canOpen {
                            Button("查看") { open(item) }.accessibilityLabel("查看\(item.source.title)依据")
                        }
                    }
                }
                if !canOpen { Text("此连接暂不支持打开原始依据。").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
