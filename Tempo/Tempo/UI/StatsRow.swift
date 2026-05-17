import SwiftUI

struct StatsRow: View {
    @Environment(BeatState.self) private var state

    var body: some View {
        HStack(spacing: 8) {
            StatCard(label: "BPM MIN",
                     value: state.minBPM > 0 ? String(format: "%.1f", state.minBPM) : "—",
                     color: .tempoAccent)
            StatCard(label: "BPM MAX",
                     value: state.maxBPM > 0 ? String(format: "%.1f", state.maxBPM) : "—",
                     color: .tempoGreen)
            StatCard(label: "BPM AVG",
                     value: state.avgBPM > 0 ? String(format: "%.1f", state.avgBPM) : "—",
                     color: .tempoText)
        }
    }
}

private struct StatCard: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(color)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(Color.tempoMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(Color.tempoPanel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.tempoBorder, lineWidth: 1)
        )
    }
}

#Preview {
    StatsRow()
        .environment({
            let s = BeatState()
            s.minBPM = 115.2; s.maxBPM = 124.8; s.avgBPM = 120.1
            return s
        }())
        .background(Color.tempoBg)
        .padding()
}
