import SwiftUI

// TBD-17: Orologio digitale sempre visibile
// TBD-18: Cronometro durata concerto
struct CronoPanel: View {
    @Environment(BeatState.self) private var beatState

    var body: some View {
        // TODO: implementato dall'UI Agent (TBD-3)
        EmptyView()
    }
}

#Preview {
    CronoPanel()
        .environment(BeatState())
}
