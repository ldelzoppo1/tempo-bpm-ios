import SwiftUI

// TBD-15: Funzione Tap Tempo — componente UI
struct TapPanel: View {
    @Environment(BeatState.self) private var beatState

    var body: some View {
        // TODO: implementato dall'UI Agent (TBD-5)
        EmptyView()
    }
}

#Preview {
    TapPanel()
        .environment(BeatState())
}
