import SwiftUI

// MARK: - Color tokens

private extension Color {
    static let bgCard       = Color(hex: "#111111")
    static let borderCard   = Color(hex: "#1E1E1E")
    static let accentRed    = Color(hex: "#FF3C00")
    static let accentOrange = Color(hex: "#FF9500")
    static let accentGreen  = Color(hex: "#00FF88")
    static let textPrimary  = Color(hex: "#E8E8E8")
    static let textSecondary = Color(hex: "#444444")
    static let pillInactive = Color(hex: "#222222")
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - BPMPanel

/// Mostra il BPM corrente, le pills dei valori recenti, i dots e la barra di stabilità.
/// Consuma BeatState in sola lettura via @Environment.
struct BPMPanel: View {
    @Environment(BeatState.self) private var beatState

    var body: some View {
        ZStack(alignment: .top) {
            // Card background + border
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.borderCard, lineWidth: 1)
                )

            VStack(spacing: 0) {
                // 1. Accent-bar — rossa, full-width, 2pt, zero padding orizzontale
                Color.accentRed
                    .frame(height: 2)

                // Card body con padding interno
                VStack(spacing: 6) {
                    // 2. Numero BPM
                    BPMNumber(
                        bpm: beatState.currentBPM,
                        beatFlash: beatState.beatFlash
                    )

                    // 3. Label "BPM"
                    Text("BPM")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    // 4. Pills
                    PillsRow(recentBPMs: beatState.recentBPMs)

                    // 5. Dots
                    DotsRow(currentBPM: beatState.currentBPM)

                    // 6. Riga stabilità
                    StabilityRow(stability: beatState.stability)
                }
                .padding(12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity)
    }
}

// MARK: - BPMNumber

private struct BPMNumber: View {
    let bpm: Double
    let beatFlash: Bool

    private var displayText: String {
        bpm > 0 ? "\(Int(bpm.rounded()))" : "---"
    }

    var body: some View {
        Text(displayText)
            .font(.system(size: 108, weight: .thin, design: .default))
            .foregroundStyle(Color.textPrimary)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentTransition(.numericText())
            .animation(.spring(duration: 0.2), value: bpm)
            .scaleEffect(beatFlash ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.1), value: beatFlash)
    }
}

// MARK: - PillsRow

private struct PillsRow: View {
    let recentBPMs: [Double]

    /// Sempre 4 slot: se ci sono meno di 4 valori, riempi con nil
    private var slots: [Double?] {
        let count = recentBPMs.count
        if count == 0 {
            return [nil, nil, nil, nil]
        }
        // Mostra al massimo 4, i più vecchi prima, il più recente in ultima posizione
        let visible = Array(recentBPMs.suffix(4))
        let padding = Array(repeating: nil as Double?, count: max(0, 4 - visible.count))
        return padding + visible.map { Optional($0) }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, value in
                PillView(value: value, isLatest: index == slots.count - 1 && value != nil)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - PillView

private struct PillView: View {
    let value: Double?
    let isLatest: Bool

    private var label: String {
        guard let v = value else { return "—" }
        return String(format: "%.1f", v)
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .regular, design: .monospaced))
            .foregroundStyle(isLatest ? Color.accentOrange : Color.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isLatest ? Color.accentOrange.opacity(0.12) : Color.pillInactive)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(
                                isLatest ? Color.accentOrange : Color.borderCard,
                                lineWidth: 1
                            )
                    )
            )
    }
}

// MARK: - DotsRow

private struct DotsRow: View {
    let currentBPM: Double

    /// Indice del dot attivo. -1 se nessun dot attivo (BPM == 0)
    private var activeDot: Int {
        guard currentBPM > 0 else { return -1 }
        // TODO(TBD-44): placeholder — mappatura BPM→dot da sostituire con logica beat-phase definitiva (TBD-4)
        return Int(currentBPM / 30) % 8
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<8, id: \.self) { index in
                Circle()
                    .fill(index == activeDot ? Color.accentOrange : Color.pillInactive)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - StabilityRow

private struct StabilityRow: View {
    let stability: Double

    var body: some View {
        HStack(spacing: 8) {
            Text("STABILITÀ")
                .font(.system(size: 8, weight: .regular))
                .foregroundStyle(Color.textSecondary)
                .fixedSize()

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.pillInactive)
                        .frame(height: 3)

                    // Fill
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentOrange)
                        .frame(width: geo.size.width * stability, height: 3)
                        .animation(.linear(duration: 0.3), value: stability)
                }
                .frame(height: 3)
            }
            .frame(height: 3)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

#Preview("Default — ascolto attivo") {
    let state = BeatState()
    state.currentBPM = 120.4
    state.recentBPMs = [119.8, 120.1, 120.6, 120.4]
    state.stability = 0.82
    state.beatFlash = false
    state.isListening = true
    return BPMPanel()
        .environment(state)
        .padding(20)
        .background(Color.black)
}

#Preview("Nessun beat — in attesa") {
    let state = BeatState()
    state.currentBPM = 0
    state.recentBPMs = []
    state.stability = 0
    return BPMPanel()
        .environment(state)
        .padding(20)
        .background(Color.black)
}

#Preview("Beat flash") {
    let state = BeatState()
    state.currentBPM = 98
    state.recentBPMs = [97.5, 98.2, 98.0]
    state.stability = 0.55
    state.beatFlash = true
    return BPMPanel()
        .environment(state)
        .padding(20)
        .background(Color.black)
}
