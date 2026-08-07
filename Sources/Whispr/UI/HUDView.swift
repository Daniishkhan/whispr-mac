import SwiftUI

/// Recording HUD: status, live transcript, mic level, stop/cancel.
struct HUDView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.phase == .recording ? Color.red : Color.orange)
                    .frame(width: 10, height: 10)
                Text(state.statusLine.isEmpty ? "…" : state.statusLine)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                LevelMeter(level: state.micLevel)
                    .frame(width: 90, height: 8)
                Button {
                    state.cancelSession()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Cancel dictation")
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(state.liveText.isEmpty
                         ? "Speak now — your words will appear here."
                         : state.liveText)
                        .font(.system(size: 15))
                        .foregroundStyle(state.liveText.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .onChange(of: state.liveText) { _, _ in
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            HStack {
                Text(state.recordingHintText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop") {
                    state.stopFromMenu()
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(8)
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.green)
                    .frame(width: geometry.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}
