import SwiftUI

// MARK: - Color tokens (TapPanel-private)
// Color(hex:) è definita in BPMPanel.swift a livello di modulo — non ridichiarare.

private extension Color {
    static let tpBgCard      = Color(hex: "#111111")
    static let tpBorderCard  = Color(hex: "#1E1E1E")
    static let tpBgButton    = Color(hex: "#222222")
    static let tpTextLabel   = Color(hex: "#444444")
    static let tpTextButton  = Color(hex: "#E8E8E8")
    static let tpAccentBPM   = Color(hex: "#FF9500")
}

// MARK: - TapPanel

/// Componente UI per il tap tempo.
/// Mostra un'intestazione con il contatore tap, il pulsante TAP e,
/// quando attivo, il BPM rilevato dai tap in arancione.
/// Non conosce TapTempo — riceve un callback onTap iniettato dall'esterno.
struct TapPanel: View {
    @Environment(BeatState.self) private var beatState

    /// Callback chiamato ad ogni pressione del pulsante TAP.
    /// Iniettato da ContentView / TempoBPMApp. Default no-op per compatibilità
    /// con il sito di chiamata `TapPanel()` esistente in ContentView.
    var onTap: () -> Void = {}

    @State private var tapOpacity: Double = 1.0

    var body: some View {
        VStack(spacing: 8) {
            // MARK: Header row
            HStack {
                Text("TAP TEMPO")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(Color.tpTextLabel)

                Spacer()

                Text("\(beatState.tapCount) tap")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(Color.tpTextLabel)
            }

            // MARK: TAP button
            Button {
                // Feedback visivo: opacity cala a 0.6 e torna a 1.0
                withAnimation(.easeOut(duration: 0.15)) {
                    tapOpacity = 0.6
                }
                withAnimation(.easeOut(duration: 0.15).delay(0.15)) {
                    tapOpacity = 1.0
                }
                onTap()
            } label: {
                Text("TAP")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color.tpTextButton)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.tpBgButton)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.tpBorderCard, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .opacity(tapOpacity)

            // MARK: BPM override display
            // Sempre presente nel layout — opacity usata per non spostare gli elementi
            Text(String(format: "%.0f BPM", beatState.tapBPM))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.tpAccentBPM)
                .frame(maxWidth: .infinity, alignment: .center)
                .opacity(beatState.tapOverrideActive ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.tpBgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.tpBorderCard, lineWidth: 1)
                )
        )
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Previews

#Preview("Idle — nessun tap") {
    let state = BeatState()
    state.tapCount = 0
    state.tapBPM = 0
    state.tapOverrideActive = false
    return TapPanel(onTap: {})
        .environment(state)
        .padding(20)
        .background(Color(hex: "#0A0A0A"))
}

#Preview("Override attivo — 120 BPM") {
    let state = BeatState()
    state.tapCount = 3
    state.tapBPM = 120
    state.tapOverrideActive = true
    return TapPanel(onTap: {})
        .environment(state)
        .padding(20)
        .background(Color(hex: "#0A0A0A"))
}

#Preview("N tap — contatore") {
    let state = BeatState()
    state.tapCount = 7
    state.tapBPM = 98
    state.tapOverrideActive = true
    return TapPanel(onTap: {})
        .environment(state)
        .padding(20)
        .background(Color(hex: "#0A0A0A"))
}
