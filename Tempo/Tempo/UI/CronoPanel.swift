import SwiftUI

struct CronoPanel: View {
    @Environment(BeatState.self) private var state
    @State private var concertStartDate: Date?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                clockCard
                cronoCard
            }
            controls
        }
    }

    // MARK: Clock

    private var clockCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(Color.tempoMuted).frame(width: 8, height: 8)
                Text("ORA")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.tempoMuted)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(currentTimeString)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(Color.tempoText)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.tempoPanel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.tempoBorder, lineWidth: 1))
    }

    // MARK: Chronometer

    private var cronoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle()
                    .fill(state.concertRunning ? Color.tempoGreen : Color.tempoMuted)
                    .frame(width: 8, height: 8)
                Text("CONCERTO")
                    .font(.system(size: 9))
                    .foregroundStyle(state.concertRunning ? Color.tempoGreen : Color.tempoMuted)
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(elapsedString(at: ctx.date))
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(Color.tempoText)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.tempoPanel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.tempoBorder, lineWidth: 1))
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 8) {
            crButton("START", isGreen: !state.concertRunning) {
                guard !state.concertRunning else { return }
                if concertStartDate == nil {
                    concertStartDate = Date().addingTimeInterval(-state.concertElapsed)
                }
                state.concertRunning = true
            }
            crButton("STOP", isGreen: state.concertRunning) {
                guard state.concertRunning else { return }
                if let start = concertStartDate {
                    state.concertElapsed = Date().timeIntervalSince(start)
                }
                concertStartDate = nil
                state.concertRunning = false
            }
            crButton("RESET", isGreen: false) {
                concertStartDate = nil
                state.concertElapsed = 0
                state.concertRunning = false
            }
        }
    }

    private func crButton(_ label: String, isGreen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 16))
                .foregroundStyle(isGreen ? Color.tempoGreen : Color.tempoMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.tempoPanel)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(
                                    isGreen
                                        ? LinearGradient(
                                            colors: [Color.tempoGreen.opacity(0.18), Color.tempoGreen.opacity(0.05)],
                                            startPoint: .top, endPoint: .bottom
                                          )
                                        : LinearGradient(colors: [Color.clear, Color.clear], startPoint: .top, endPoint: .bottom)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isGreen ? Color.tempoGreen : Color.tempoBorder, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Helpers

    private var currentTimeString: String {
        let c = Calendar.current
        let h = c.component(.hour, from: Date())
        let m = c.component(.minute, from: Date())
        return String(format: "%02d:%02d", h, m)
    }

    private func elapsedString(at date: Date) -> String {
        let elapsed: TimeInterval
        if state.concertRunning, let start = concertStartDate {
            elapsed = max(0, date.timeIntervalSince(start))
        } else {
            elapsed = state.concertElapsed
        }
        let total = Int(elapsed)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%02d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

#Preview {
    CronoPanel()
        .environment(BeatState())
        .background(Color.tempoBg)
        .padding()
}
