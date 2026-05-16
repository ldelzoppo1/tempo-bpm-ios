import SwiftUI

@main
struct TempoBPMApp: App {
    @State private var beatState = BeatState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(beatState)
        }
    }
}
