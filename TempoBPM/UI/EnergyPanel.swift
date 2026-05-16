import SwiftUI

struct EnergyPanel: View {
    @Environment(BeatState.self) private var beatState

    var body: some View {
        // TODO: implementato dall'UI Agent (TBD-3)
        EmptyView()
    }
}

#Preview {
    EnergyPanel()
        .environment(BeatState())
}
