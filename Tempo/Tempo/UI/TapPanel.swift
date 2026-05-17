import SwiftUI

struct TapPanel: View {
    @Environment(BeatState.self) private var state
    @State private var tapTempo: TapTempo?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("TAP TEMPO")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.tempoMuted)
                Spacer()
                if state.tapCount > 0 {
                    Text("\(state.tapCount) tap")
                        .font(.system(size: 9))
                        .foregroundStyle(state.tapOverrideActive ? Color.tempoGreen : Color.tempoMuted)
                }
            }

            Button {
                if tapTempo == nil { tapTempo = TapTempo(state: state) }
                tapTempo?.tap()
            } label: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.tempoDark)
                    .overlay(
                        Text("TAP")
                            .font(.system(size: 32, weight: .regular))
                            .foregroundStyle(state.tapOverrideActive ? Color.tempoAmber : Color.tempoText)
                    )
                    .frame(height: 80)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
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
    TapPanel()
        .environment(BeatState())
        .background(Color.tempoBg)
        .padding()
}
