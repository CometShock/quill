import SwiftUI

/// The persistent panel's three zones: transcript (or idle placeholder),
/// the slide-up settings tray, and the transport bar. Layout is a plain
/// VStack — the tray "slides" by being inserted above the transport bar
/// with a move-from-bottom transition.
struct QuillPanelView: View {
    let model: PanelModel

    var body: some View {
        VStack(spacing: 0) {
            transcriptZone
            if model.trayExpanded {
                Divider()
                ConfigTrayView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Divider()
            transportBar
        }
        .frame(minWidth: 280, minHeight: 240)
    }

    @ViewBuilder
    private var transcriptZone: some View {
        if let store = model.currentStore {
            LiveTranscriptView(store: store, layoutEpoch: model.trayExpanded ? 1 : 0)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text(model.recording ? "recording — live transcript off" : "not recording")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var transportBar: some View {
        HStack(spacing: 10) {
            Button {
                model.onToggleRecording?()
            } label: {
                Image(systemName: model.recording ? "stop.circle.fill" : "record.circle")
                    .font(.title2)
                    .foregroundStyle(model.recording ? Color.primary : Color.red)
            }
            .buttonStyle(.plain)
            .help(model.recording ? "Stop recording" : "Start recording")

            if let elapsed = model.elapsed {
                Text(elapsed)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    model.trayExpanded.toggle()
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.body)
                    .foregroundStyle(model.trayExpanded ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
