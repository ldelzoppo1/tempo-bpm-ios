import SwiftUI

// MARK: - Color tokens (CronoPanel-scoped)

private extension Color {
    static let cpBgCard      = Color(hex: "#111111")
    static let cpBorderCard  = Color(hex: "#1E1E1E")
    static let cpTextPrimary = Color(hex: "#E8E8E8")
    static let cpTextSecondary = Color(hex: "#444444")
    static let cpAccentGreen = Color(hex: "#00FF88")
}

// MARK: - CronoPanel

/// Pannello orizzontale con due celle affiancate:
/// - ORA: orologio digitale aggiornato ogni secondo
/// - CONCERTO: placeholder per TBD-50 (cronometro durata concerto)
///
/// Consuma BeatState via @Environment (richiesto per TBD-50).
struct CronoPanel: View {
    @Environment(BeatState.self) private var beatState

    @State private var currentTime: Date = Date()

    // Timer pubblicato sul main runloop, aggiornamento ogni secondo
    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Formatter come proprietà della view — non riallocato ad ogni render
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            ClockCell(
                label: "ORA",
                dotColor: .cpTextSecondary,
                value: timeFormatter.string(from: currentTime),
                valueColor: .cpTextPrimary
            )
            ClockCell(
                label: "CONCERTO",
                dotColor: .cpAccentGreen,
                value: "00:00",
                valueColor: .cpAccentGreen
            )
        }
        .onReceive(clockTimer) { date in
            currentTime = date
        }
    }
}

// MARK: - ClockCell

/// Singola cella con dot colorato, label categoria e valore digitale.
private struct ClockCell: View {
    let label: String
    let dotColor: Color
    let value: String
    let valueColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header: dot + label
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)

                Text(label)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(dotColor)
                    .lineLimit(1)
            }

            // Valore digitale
            Text(value)
                .font(.system(size: 30, weight: .regular, design: .default).monospacedDigit())
                .foregroundStyle(valueColor)
                .frame(maxWidth: .infinity, alignment: .center)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.cpBgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.cpBorderCard, lineWidth: 1)
                )
        )
    }
}

// MARK: - Preview

#Preview("Orario corrente") {
    CronoPanel()
        .environment(BeatState())
        .padding(20)
        .background(Color.black)
}

#Preview("Orario simulato — 21:34") {
    // Simula l'orario mostrato nel design Figma
    let panel = CronoPanel()
    return panel
        .environment(BeatState())
        .padding(20)
        .background(Color.black)
}
