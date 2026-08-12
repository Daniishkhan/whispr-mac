import SwiftUI

/// Lightweight panel shown while the initial polish call runs before preview.
struct PolishingView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            VStack(alignment: .leading, spacing: 3) {
                Text("Polishing…")
                    .font(.headline)
                Text("Correcting dictation and grammar before preview.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                state.cancelPolish()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Cancel polishing (Esc)")
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(8)
    }
}
