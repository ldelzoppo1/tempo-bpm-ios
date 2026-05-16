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
    static let cpDotInactive    = Color(hex: "#2A2A2A")
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

            // Metro visivo
            BeatDotsRow(
                totalBeats: beatState.timeSignature.rawValue,
                activeBeat: beatState.currentBeat
            )
            TimeSignaturePicker(selection: $bs.timeSignature)
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

// MARK: - BeatDotsRow

/// Una riga di dot che visualizza il beat corrente all'interno della battuta.
/// Il primo dot (index 0) è leggermente più grande per indicare il downbeat.
private struct BeatDotsRow: View {
    let totalBeats: Int   // timeSignature.rawValue
    let activeBeat: Int   // currentBeat (0-based), scritto solo da BeatDetector

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalBeats, id: \.self) { index in
                Circle()
                    .fill(index == activeBeat ? Color.cpAccentGreen : Color.cpDotInactive)
                    .frame(width: 10, height: 10)
                    // Il primo beat ha un dot leggermente più grande per indicare l'inizio della battuta
                    .scaleEffect(index == 0 ? 1.3 : 1.0)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.08), value: activeBeat)
    }
}

// MARK: - TimeSignaturePicker

/// Selettore a pillole per la metrica: 3/4, 4/4, 5/4, 6/4, 7/4.
/// Scrive su BeatState.timeSignature (campo di competenza della UI).
private struct TimeSignaturePicker: View {
    @Binding var selection: TimeSignatureOption

    var body: some View {
        HStack(spacing: 6) {
            ForEach(TimeSignatureOption.allCases) { option in
                Text(option.label)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(selection == option ? Color.cpAccentGreen : Color.cpTextSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(selection == option ? Color.cpAccentGreen.opacity(0.12) : Color.cpBgCard)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(
                                        selection == option ? Color.cpAccentGreen : Color.cpBorderCard,
                                        lineWidth: 1
                                    )
                            )
                    )
                    .onTapGesture { selection = option }
            }
        }
        .frame(maxWidth: .infinity)
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

#Preview("Metro visivo — beat 2 di 4") {
    let state = BeatState()
    state.timeSignature = .four
    state.currentBeat = 1  // 0-based: secondo beat
    return CronoPanel()
        .environment(state)
        .padding(20)
        .background(Color.black)
}

#Preview("Metro visivo — 7/4 downbeat") {
    let state = BeatState()
    state.timeSignature = .seven
    state.currentBeat = 0
    return CronoPanel()
        .environment(state)
        .padding(20)
        .background(Color.black)
}
