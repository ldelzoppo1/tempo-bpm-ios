import SwiftUI

struct ContentView: View {
    @Environment(BeatState.self) private var state
    var onToggle: () -> Void = {}

    var body: some View {
        ZStack {
            Color.tempoBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 8) {
                    header
                    BPMPanel()
                    EnergyPanel()
                    StatsRow()
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
            Text("TEMPO")
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
                RoundedRectangle(cornerRadius: 8)
                    .fill((state.isListening ? Color.tempoGreen : Color.tempoAccent).opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(state.isListening ? Color.tempoGreen : Color.tempoAccent, lineWidth: 2)
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
