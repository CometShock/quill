import SwiftUI

/// The live panel's content: settled utterances, then a dimmed italic
/// in-flight line per speaker, auto-pinned to the bottom until the user
/// scrolls away (then a jump-back button appears).
struct LiveTranscriptView: View {
    let store: LiveTranscriptStore
    /// Bump when the surrounding layout resizes the scroll container (tray
    /// open/close). During the grace that follows, geometry churn can't
    /// unpin — only the user scrolling away can, once geometry has settled
    /// near the bottom again.
    var layoutEpoch = 0
    @State private var pinned = true
    @State private var settlingAfterRelayout = false

    private static let bottomID = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(store.utterances) { utterance in
                        row(speaker: utterance.speaker, text: utterance.text, dimmed: false)
                    }
                    ForEach(store.partials.keys.sorted(), id: \.self) { speaker in
                        row(speaker: speaker, text: store.partials[speaker] ?? "", dimmed: true)
                    }
                    if let notice = store.notice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 4)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(10)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 40
            } action: { _, nearBottom in
                if settlingAfterRelayout {
                    if nearBottom { settlingAfterRelayout = false }
                } else {
                    pinned = nearBottom
                }
            }
            .onChange(of: store.utterances.count) {
                if pinned { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: store.partials) {
                if pinned { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: layoutEpoch) {
                if pinned {
                    settlingAfterRelayout = true
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !pinned {
                    Button("Jump to latest") {
                        pinned = true
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(8)
                }
            }
        }
        .frame(minWidth: 260, minHeight: 180)
    }

    private func row(speaker: String, text: String, dimmed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(speaker)
                .font(.caption.weight(.semibold))
                .foregroundStyle(speaker == "me" ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 38, alignment: .trailing)
            Text(text)
                .font(.callout)
                .italic(dimmed)
                .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}
