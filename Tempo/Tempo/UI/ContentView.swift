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
            ScrollView {
                VStack(spacing: 8) {
                    header
                    BPMPanel()
                    EnergyPanel()
                    StatsRow()
                    ModePanel()
                    TapPanel()
                    CronoPanel()
                    toggleButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("KICKLINE")
                .font(.system(size: 26))
                .foregroundStyle(Color.tempoAccent)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(state.isListening ? Color.tempoGreen : Color.tempoMuted)
                    .frame(width: 8, height: 8)
                Text(state.isListening ? "IN ASCOLTO" : "FERMATO")
                    .font(.system(size: 9))
                    .foregroundStyle(state.isListening ? Color.tempoGreen : Color.tempoMuted)
            }
        }
        .padding(.bottom, 4)
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
                    .fill(.ultraThinMaterial)
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
