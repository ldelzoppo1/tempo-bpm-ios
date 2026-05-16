import SwiftUI

// MARK: - Color tokens
// Color(hex:) è definita in BPMPanel.swift a livello di modulo — non ridichiarare.

private extension Color {
    static let bgCard       = Color(hex: "#111111")
    static let borderCard   = Color(hex: "#1E1E1E")
    static let accentRed    = Color(hex: "#FF3C00")
    static let accentGreen  = Color(hex: "#00FF88")
    static let textPrimary  = Color(hex: "#E8E8E8")
    static let textSecondary = Color(hex: "#444444")
}

// MARK: - StatsRow

/// Riga con tre card affiancate: BPM MIN, MAX, AVG.
/// Consuma BeatState in sola lettura via @Environment.
struct StatsRow: View {
    @Environment(BeatState.self) private var beatState

    var body: some View {
        HStack(spacing: 8) {
            StatCard(
                value: beatState.minBPM,
                label: "BPM MIN",
                valueColor: .accentRed
            )
            StatCard(
                value: beatState.maxBPM,
                label: "BPM MAX",
                valueColor: .accentGreen
            )
            StatCard(
                value: beatState.avgBPM,
                label: "BPM AVG",
                valueColor: .textPrimary
            )
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - StatCard

private struct StatCard: View {
    let value: Double
    let label: String
    let valueColor: Color

    private var displayText: String {
        value > 0 ? "\(Int(value.rounded()))" : "---"
    }

    var body: some View {
        VStack(alignment: .center, spacing: 3) {
            Text(displayText)
                .font(.system(size: 20, weight: .regular, design: .default))
                .foregroundStyle(valueColor)
                .frame(maxWidth: .infinity, alignment: .center)
                .contentTransition(.numericText())
                .animation(.spring(duration: 0.3), value: value)

            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(Color.textSecondary)
                .tracking(1)
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.borderCard, lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Preview

#Preview("Sessione attiva") {
    let state = BeatState()
    state.minBPM = 95
    state.maxBPM = 128
    state.avgBPM = 112
    return StatsRow()
        .environment(state)
        .padding(20)
        .background(Color.black)
}

#Preview("Nessun dato") {
    let state = BeatState()
    state.minBPM = 0
    state.maxBPM = 0
    state.avgBPM = 0
    return StatsRow()
        .environment(state)
        .padding(20)
        .background(Color.black)
}
