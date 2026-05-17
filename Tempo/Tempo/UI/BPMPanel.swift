import SwiftUI

struct BPMPanel: View {
    @Environment(BeatState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            // Accent bar — pulses on each detected beat
            Rectangle()
                .fill(Color.tempoAccent.opacity(state.beatFlash ? 1.0 : 0.6))
                .frame(height: 2)
                .animation(.easeOut(duration: 0.08), value: state.beatFlash)

            VStack(spacing: 8) {
                bpmDisplay
                if !state.recentBPMs.isEmpty { recentPills }
                stabilityBar
                rhythmDots
            }
            .padding(12)
        }
        .background(Color.tempoPanel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.tempoBorder, lineWidth: 1)
        )
    }

    private var bpmDisplay: some View {
        VStack(spacing: 2) {
            let displayColor: Color = state.tapOverrideActive
                ? Color.tempoAmber
                : (state.beatFlash ? Color.tempoAccent : Color.tempoText)
            Text(state.currentBPM > 0 ? String(format: "%.1f", state.currentBPM) : "—")
                .font(.system(size: 108, weight: .regular))
                .foregroundStyle(displayColor)
                .monospacedDigit()
                .animation(.easeOut(duration: 0.08), value: state.beatFlash)
                .contentTransition(.numericText())

            HStack(spacing: 6) {
                Text("BPM")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.tempoMuted)
                if state.tapOverrideActive {
                    Text("TAP")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.tempoAmber)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.tempoAmber, lineWidth: 1)
                        )
                }
            }
        }
    }

    private var recentPills: some View {
        HStack(spacing: 4) {
            ForEach(Array(state.recentBPMs.enumerated()), id: \.offset) { idx, bpm in
                let isLast = idx == state.recentBPMs.count - 1
                Text(String(format: "%.1f", bpm))
                    .font(.system(size: 11))
                    .foregroundStyle(isLast ? Color.tempoAmber : Color.tempoText.opacity(0.6))
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isLast ? Color.tempoAmber.opacity(0.12) : Color.tempoDark)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(isLast ? Color.tempoAmber : Color.tempoBorder, lineWidth: 1)
                            )
                    )
            }
        }
    }

    private var stabilityBar: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("STABILITÀ")
                .font(.system(size: 8))
                .foregroundStyle(Color.tempoMuted)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.tempoDark)
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.tempoAmber)
                        .frame(width: geo.size.width * state.stability, height: 4)
                        .animation(.easeOut(duration: 0.3), value: state.stability)
                }
            }
            .frame(height: 4)
        }
    }

    private var rhythmDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<8, id: \.self) { i in
                Circle()
                    .fill(i % 2 == 0 ? Color.tempoMuted : Color.tempoAmber)
                    .frame(width: 8, height: 8)
                    .scaleEffect(state.beatFlash && i == 0 ? 1.3 : 1.0)
                    .animation(.easeOut(duration: 0.08), value: state.beatFlash)
            }
        }
    }
}

#Preview {
    BPMPanel()
        .environment({
            let s = BeatState()
            s.currentBPM = 120.4
            s.recentBPMs = [119.0, 120.0, 121.0, 120.4]
            s.stability = 0.82
            return s
        }())
        .background(Color.tempoBg)
        .padding()
}
