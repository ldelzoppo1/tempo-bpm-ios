import SwiftUI

struct ContentView: View {
    @Environment(BeatState.self) private var beatState

    var body: some View {
        // TODO: implementato dall'UI Agent (TBD-3)
        Text("Tempo BPM")
    }
}

#Preview {
    ContentView()
        .environment(BeatState())
}
