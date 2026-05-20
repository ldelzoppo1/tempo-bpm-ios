import SwiftUI

struct ModePanel: View {
    @Environment(BeatState.self) private var state

    var body: some View {
        HStack(spacing: 8) {
            modeButton("SOLO", mode: .solo)
            modeButton("LIVE", mode: .live)
        }
    }

    private func modeButton(_ label: String, mode: DetectionMode) -> some View {
        let isSelected = state.detectionMode == mode
        let subtitle = mode == .solo ? "sala prove" : "sul palco"
        return Button {
            state.detectionMode = mode
        } label: {
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.tempoAccent : Color.tempoMuted)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? Color.tempoAccent.opacity(0.6) : Color.tempoMuted.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                isSelected
                                    ? LinearGradient(
                                        colors: [Color.tempoAccent.opacity(0.20), Color.tempoAccent.opacity(0.06)],
                                        startPoint: .top, endPoint: .bottom
                                      )
                                    : LinearGradient(
                                        colors: [Color.clear, Color.clear],
                                        startPoint: .top, endPoint: .bottom
                                      )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.tempoAccent : Color.tempoBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ModePanel()
        .environment(BeatState())
        .background(Color.tempoBg)
        .padding()
}
