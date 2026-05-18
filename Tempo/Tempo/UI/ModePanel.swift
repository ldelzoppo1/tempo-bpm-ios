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
        return Button {
            state.detectionMode = mode
        } label: {
            Text(label)
                .font(.system(size: 16))
                .foregroundStyle(isSelected ? Color.tempoAccent : Color.tempoMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.tempoAccent.opacity(0.08) : Color.tempoDark)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
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
