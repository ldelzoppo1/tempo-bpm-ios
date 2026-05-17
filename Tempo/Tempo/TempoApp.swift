import SwiftUI

@main
struct TempoApp: App {

    @State private var beatState = BeatState()

    // Tenuti in @State per sopravvivere ai re-render del body.
    @State private var audioEngine: AudioEngine?
    @State private var beatDetector: BeatDetector?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(beatState)
                .task { startAudioPipeline() }
        }
    }

    /// Crea AudioEngine + BeatDetector e avvia la cattura audio su un thread non-main.
    ///
    /// `startCapture` usa un semaforo per attendere il permesso microfono:
    /// deve girare fuori dal main thread per evitare deadlock.
    private func startAudioPipeline() {
        let engine   = AudioEngine(state: beatState)
        let detector = BeatDetector(state: beatState)
        audioEngine   = engine
        beatDetector  = detector

        Task.detached(priority: .high) {
            try? engine.startCapture { buffer in
                detector.process(buffer: buffer)
            }
        }
    }
}
