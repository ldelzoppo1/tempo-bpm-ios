import SwiftUI

// TBD-12: Display BPM principale con flash al beat
struct BPMPanel: View {
    @Environment(BeatState.self) private var beatState

    var body: some View {
        // TODO: implementato dall'UI Agent (TBD-3)
        EmptyView()
    }
}

#Preview {
    BPMPanel()
        .environment(BeatState())
}
