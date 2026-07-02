import SwiftUI

struct StageBadge: View {
    let stage: OpportunityStage

    var body: some View {
        Label(stage.title, systemImage: stage.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(stage.tint)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(stage.tint.opacity(0.12), in: Capsule())
    }
}

struct TagStrip: View {
    let tags: [String]

    var body: some View {
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
    }
}
