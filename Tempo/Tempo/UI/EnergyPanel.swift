import SwiftUI

struct EnergyPanel: View {
    @Environment(BeatState.self) private var state

    private let bandCount = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ENERGIA — BASSA FREQUENZA")
                .font(.system(size: 9))
                .foregroundStyle(Color.tempoMuted)

            GeometryReader { geo in
                let barW = max(1, (geo.size.width - CGFloat(bandCount - 1) * 1.2) / CGFloat(bandCount))
                HStack(alignment: .bottom, spacing: 1.2) {
                    ForEach(0..<bandCount, id: \.self) { i in
                        let energy = CGFloat(i < state.energyBands.count ? state.energyBands[i] : 0)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.tempoAccent.opacity(0.55 + 0.45 * energy),
                                        Color.tempoAccent.opacity(0.20 + 0.30 * energy),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: barW, height: max(4, geo.size.height * energy))
                            .animation(.easeOut(duration: 0.06), value: energy)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 48)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.tempoBorder, lineWidth: 1)
        )
    }
}

#Preview {
    EnergyPanel()
        .environment({
            let s = BeatState()
            s.energyBands = (0..<46).map { i in
                Float.random(in: 0.1...0.9) * Float(sin(Double(i) * 0.3) * 0.5 + 0.5)
            }
            return s
        }())
        .background(Color.tempoBg)
        .padding()
}
