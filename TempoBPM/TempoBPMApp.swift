import SwiftUI

@main
struct TempoBPMApp: App {
    // Un'unica istanza di BeatState condivisa tra UI (via @Environment) e pipeline audio.
    // Tutti e tre gli oggetti sono inizializzati in init() con la stessa istanza `state`.
    @State private var beatState: BeatState
    private let audioEngine: AudioEngine
    private let beatDetector: BeatDetector

    init() {
        let state = BeatState()
        _beatState = State(initialValue: state)
        audioEngine = AudioEngine(state: state)
        beatDetector = BeatDetector(state: state)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(beatState)
                .onAppear {
                    // Collegare BeatDetector come captureHandler di AudioEngine,
                    // poi avviare la pipeline audio su un thread non-main per evitare
                    // il blocco del main thread durante la richiesta permesso microfono.
                    let detector = beatDetector
                    Task.detached(priority: .userInitiated) {
                        do {
                            try audioEngine.startCapture { [weak detector] buffer in
                                detector?.process(buffer: buffer)
                            }
                        } catch {
                            // La UI mostra isListening=false (default) in caso di errore.
                        }
                    }
                }
        }
    }
}
