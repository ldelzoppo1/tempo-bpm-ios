import SwiftUI

// MARK: - Color tokens (EnergyPanel-private)

private extension Color {
    static let epBgCard    = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
    static let epBorderCard = Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)
    static let epLabel     = Color(red: 68 / 255, green: 68 / 255, blue: 68 / 255)
    static let epAccent    = Color(red: 1.0, green: 60 / 255, blue: 0)
}

// MARK: - EnergyPanel

/// Mostra la waveform dell'energia in banda bassa (20–200 Hz) come 46 barre verticali
/// animate. Consuma `BeatState.energyBands` in sola lettura via @Environment.
struct EnergyPanel: View {
    @Environment(BeatState.self) private var beatState

    var body: some View {
        ZStack {
            // Card background
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.epBgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.epBorderCard, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 6) {
                // Header label
                Text("ENERGIA — BASSA FREQUENZA")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(Color.epLabel)

                // Waveform
                WaveformView(energyBands: beatState.energyBands)
                    .frame(height: 50)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - WaveformView

/// HStack di 46 RoundedRectangle allineate al basso, animate con easeOut.
private struct WaveformView: View {
    let energyBands: [Float]

    // The max content height for the bars (matches the .frame(height: 50) on the container)
    private let maxBarHeight: CGFloat = 50

    var body: some View {
        GeometryReader { geo in
            let barCount = 46
            let totalSpacing = CGFloat(barCount - 1) * 2   // spacing: 2pt between bars
            let barWidth = max(1, (geo.size.width - totalSpacing) / CGFloat(barCount))

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0 ..< barCount, id: \.self) { i in
                    let value: Float = i < energyBands.count ? max(0, min(1, energyBands[i])) : 0
                    let barHeight: CGFloat = value > 0
                        ? max(2, CGFloat(value) * maxBarHeight)
                        : 2
                    let opacity: Double = value > 0
                        ? Double(0.46 + value * 0.50)
                        : 0.2

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.epAccent.opacity(opacity))
                        .frame(width: barWidth, height: barHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .animation(.easeOut(duration: 0.05), value: energyBands)
    }
}

// MARK: - Preview

#Preview("Ascolto attivo — valori reali") {
    let state = BeatState()
    // 46 valori che riproducono una curva a campana simile al design Figma
    state.energyBands = (0 ..< 46).map { i in
        let x = Float(i) / 45.0
        let bell = Float(sin(Double.pi * Double(x)))
        return 0.05 + bell * 0.90
    }
    return EnergyPanel()
        .environment(state)
        .padding(20)
        .background(Color.black)
}

#Preview("Placeholder — prima dell'avvio") {
    let state = BeatState()
    state.energyBands = []
    return EnergyPanel()
        .environment(state)
        .padding(20)
        .background(Color.black)
}

#Preview("Valori casuali") {
    let state = BeatState()
    state.energyBands = (0 ..< 46).map { _ in Float.random(in: 0 ..< 1) }
    return EnergyPanel()
        .environment(state)
        .padding(20)
        .background(Color.black)
}
