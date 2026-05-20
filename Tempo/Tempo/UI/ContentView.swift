import SwiftUI

struct ContentView: View {
    @Environment(BeatState.self) private var state
    var onToggle: () -> Void = {}

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.tempoGradTop, .tempoGradMid, .tempoGradBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            VStack(spacing: 6) {
                header
                BPMPanel()
                EnergyPanel()
                StatsRow()
                TapPanel()
                CronoPanel()
                toggleButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("KICKLINE")
                .font(.system(size: 26))
                .foregroundStyle(Color.tempoAccent)
            Spacer()
            modeToggle
            statusIndicator
        }
        .padding(.bottom, 2)
    }

    private var modeToggle: some View {
        HStack(spacing: 4) {
            modeButton("SOLO", mode: .solo)
            modeButton("LIVE", mode: .live)
        }
    }

    private func modeButton(_ label: String, mode: DetectionMode) -> some View {
        let isSelected = state.detectionMode == mode
        return Button { state.detectionMode = mode } label: {
            Text(label)
                .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.tempoAccent : Color.tempoMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.tempoAccent : Color.tempoBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var statusIndicator: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(state.isListening ? Color.tempoGreen : Color.tempoMuted)
                .frame(width: 8, height: 8)
            Text(state.isListening ? "IN ASCOLTO" : "FERMATO")
                .font(.system(size: 9))
                .foregroundStyle(state.isListening ? Color.tempoGreen : Color.tempoMuted)
        }
    }

    private var toggleButton: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Text(state.isListening ? "■" : "▶")
                Text(state.isListening ? "FERMA" : "AVVIA")
            }
            .font(.system(size: 18))
            .foregroundStyle(state.isListening ? Color.tempoGreen : Color.tempoAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.tempoPanel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        (state.isListening ? Color.tempoGreen : Color.tempoAccent).opacity(0.18),
                                        (state.isListening ? Color.tempoGreen : Color.tempoAccent).opacity(0.06),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(state.isListening ? Color.tempoGreen : Color.tempoAccent, lineWidth: 1.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
        .environment({
            let s = BeatState()
            s.isListening = true
            s.currentBPM = 120.4
            return s
        }())
}
