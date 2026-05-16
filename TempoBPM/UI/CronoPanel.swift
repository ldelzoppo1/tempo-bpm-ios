import SwiftUI

// MARK: - Color tokens (CronoPanel-scoped)

private extension Color {
    static let cpBgCard         = Color(hex: "#111111")
    static let cpBgCardActive   = Color(hex: "#00FF88").opacity(0.08)
    static let cpBorderCard     = Color(hex: "#1E1E1E")
    static let cpBorderActive   = Color(hex: "#00FF88")
    static let cpBgDisabled     = Color(hex: "#222222")
    static let cpTextPrimary    = Color(hex: "#E8E8E8")
    static let cpTextSecondary  = Color(hex: "#444444")
    static let cpAccentGreen    = Color(hex: "#00FF88")
    static let cpAccentRed      = Color(hex: "#FF3C00")
}

// MARK: - CronoPanel

/// Pannello con due celle orizzontali (ORA / CONCERTO) e i controlli del cronometro.
struct CronoPanel: View {
    @Environment(BeatState.self) private var beatState

    @State private var currentTime: Date = Date()

    // Timer pubblicato sul main runloop — usato sia per l'orologio che per il cronometro
    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        // @Bindable permette di scrivere su BeatState letto via @Environment
        @Bindable var bs = beatState

        VStack(spacing: 8) {
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
                    value: formattedElapsed(beatState.concertElapsed),
                    valueColor: .cpAccentGreen
                )
            }

            CronoControls(
                isRunning: bs.concertRunning,
                onStart: { bs.concertRunning = true },
                onStop:  { bs.concertRunning = false },
                onReset: { bs.concertElapsed = 0; bs.concertRunning = false }
            )
        }
        .onReceive(clockTimer) { date in
            currentTime = date
            // Un solo timer gestisce sia l'orologio sia il cronometro
            if beatState.concertRunning {
                beatState.concertElapsed += 1
            }
        }
    }

    private func formattedElapsed(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - CronoControls

private struct CronoControls: View {
    let isRunning: Bool
    let onStart: () -> Void
    let onStop:  () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ControlButton(
                label: "▶  START",
                foreground: .cpAccentGreen,
                background: .cpBgCardActive,
                border: .cpBorderActive,
                disabled: isRunning,
                action: onStart
            )
            ControlButton(
                label: "■  STOP",
                foreground: .cpTextSecondary,
                background: .cpBgDisabled,
                border: .cpBorderCard,
                disabled: !isRunning,
                action: onStop
            )
            ControlButton(
                label: "↺  RESET",
                foreground: .cpTextSecondary,
                background: .cpBgDisabled,
                border: .cpBorderCard,
                disabled: false,
                action: onReset
            )
        }
    }
}

// MARK: - ControlButton

private struct ControlButton: View {
    let label: String
    let foreground: Color
    let background: Color
    let border: Color
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(foreground.opacity(disabled ? 0.35 : 1))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(background)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(border.opacity(disabled ? 0.35 : 1), lineWidth: 1)
                )
        )
        .disabled(disabled)
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
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)

                Text(label)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(dotColor)
                    .lineLimit(1)
            }

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

#Preview("Idle") {
    CronoPanel()
        .environment(BeatState())
        .padding(20)
        .background(Color.black)
}

#Preview("Running — 1m23s") {
    let state = BeatState()
    state.concertElapsed = 83
    state.concertRunning = true
    return CronoPanel()
        .environment(state)
        .padding(20)
        .background(Color.black)
}

#Preview("Stopped — 4m02s") {
    let state = BeatState()
    state.concertElapsed = 242
    state.concertRunning = false
    return CronoPanel()
        .environment(state)
        .padding(20)
        .background(Color.black)
}
