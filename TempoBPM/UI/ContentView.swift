import SwiftUI

// MARK: - Color tokens (ContentView-private)
// Color(hex:) è definita in BPMPanel.swift a livello di modulo — non ridichiarare.

private extension Color {
    static let bgScreen      = Color(hex: "#0A0A0A")
    static let cvTextPrimary = Color(hex: "#E8E8E8")
    static let cvAccentRed   = Color(hex: "#FF3C00")
    static let cvAccentGreen = Color(hex: "#00FF88")
    static let cvTextSecondary = Color(hex: "#444444")
}

// MARK: - ContentView

/// Root view dell'app. Compone l'header e tutti i panel.
/// BeatState viene iniettato da TempoBPMApp via .environment(beatState).
struct ContentView: View {
    @Environment(BeatState.self) private var beatState

    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        ZStack(alignment: .top) {
            // Sfondo schermo full-screen
            Color.bgScreen
                .ignoresSafeArea()

            VStack(spacing: 8) {
                // 1. Header
                HeaderView(
                    isListening: beatState.isListening,
                    pulseOpacity: $pulseOpacity
                )

                // 2–4. Pannelli principali — scrollabili su iPhone SE
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        BPMPanel()
                        EnergyPanel()
                        StatsRow()
                    }
                }

                // 5. TapPanel placeholder (TBD-5)
                TapPanel()

                // 6. CronoPanel placeholder (TBD-4)
                CronoPanel()

                // 7. Pulsante FERMA / AVVIA (TBD-47)
                StartButton()
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 52)
            .padding(.bottom, 20)
        }
        .ignoresSafeArea(.all, edges: .bottom)
    }
}

// MARK: - HeaderView

private struct HeaderView: View {
    let isListening: Bool
    @Binding var pulseOpacity: Double

    var body: some View {
        HStack {
            // LEFT: App title
            Text("TEMPO")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Color.cvAccentRed)

            Spacer()

            // RIGHT: Listening status indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(isListening ? Color.cvAccentGreen : Color.cvTextSecondary)
                    .frame(width: 8, height: 8)
                    .opacity(isListening ? pulseOpacity : 1.0)
                    .onAppear {
                        guard isListening else { return }
                        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                            pulseOpacity = 0.3
                        }
                    }
                    .onChange(of: isListening) { _, newVal in
                        if newVal {
                            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                pulseOpacity = 0.3
                            }
                        } else {
                            pulseOpacity = 1.0
                        }
                    }

                Text("IN ASCOLTO")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(isListening ? Color.cvAccentGreen : Color.cvTextSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - StartButton

/// Pulsante principale FERMA / AVVIA (TBD-47).
/// Scrive solo beatState.isListening — la pipeline audio viene avviata/fermata
/// da TempoBPMApp tramite .onChange(of: beatState.isListening).
private struct StartButton: View {
    @Environment(BeatState.self) private var beatState

    var body: some View {
        Button {
            beatState.isListening.toggle()
        } label: {
            Text(beatState.isListening ? "FERMA" : "AVVIA")
                .font(.system(size: 16, weight: .semibold))
                .tracking(2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .foregroundStyle(
                    beatState.isListening ? Color.cvAccentRed : Color.cvAccentGreen
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            beatState.isListening
                                ? Color.cvAccentRed
                                : Color.cvAccentGreen,
                            lineWidth: 2
                        )
                )
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            beatState.isListening
                                ? Color.cvAccentRed.opacity(0.06)
                                : Color.cvAccentGreen.opacity(0.06)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview("In ascolto — FERMA") {
    let state = BeatState()
    state.isListening = true
    state.currentBPM = 127
    state.recentBPMs = [126.2, 126.8, 127.3, 127.0]
    state.stability = 0.76
    state.minBPM = 120
    state.maxBPM = 132
    state.avgBPM = 126
    state.energyBands = (0 ..< 46).map { i in
        let x = Float(i) / 45.0
        return 0.1 + Float(sin(Double.pi * Double(x))) * 0.85
    }
    return ContentView()
        .environment(state)
}

#Preview("In pausa — AVVIA") {
    let state = BeatState()
    state.isListening = false
    state.currentBPM = 0
    return ContentView()
        .environment(state)
}
