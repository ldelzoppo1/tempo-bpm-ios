import SwiftUI

@main
struct TempoBPMApp: App {
    // Un'unica istanza di BeatState condivisa tra UI (via @Environment) e pipeline audio.
    // Tutti e tre gli oggetti sono inizializzati in init() con la stessa istanza `state`.
    @State private var beatState: BeatState
    private let audioEngine: AudioEngine
    private let beatDetector: BeatDetector
    private let tapTempo: TapTempo

    init() {
        let state = BeatState()
        _beatState = State(initialValue: state)
        audioEngine = AudioEngine(state: state)
        beatDetector = BeatDetector(state: state)
        tapTempo = TapTempo(state: state)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(onTap: tapTempo.registerTap)
                .environment(beatState)
                // TBD-47: osserva isListening e gestisce la pipeline audio.
                // ContentView scrive solo beatState.isListening; TempoBPMApp
                // traduce il cambiamento in startCapture/stopCapture, mantenendo
                // la separazione Audio/UI definita in ARCHITECTURE.md.
                .onChange(of: beatState.isListening) { _, newValue in
                    let detector = beatDetector
                    if newValue {
                        Task.detached(priority: .userInitiated) {
                            do {
                                try audioEngine.startCapture { [weak detector] buffer in
                                    detector?.process(buffer: buffer)
                                }
                            } catch {
                                // Permesso negato o hardware error: AudioEngine.start()
                                // non ha impostato isListening = true, quindi il pulsante
                                // rimane in stato AVVIA. Reset esplicito per sicurezza.
                                await MainActor.run { self.beatState.isListening = false }
                            }
                        }
                    } else {
                        audioEngine.stopCapture()
                        beatDetector.reset()
                        tapTempo.reset()
                    }
                    // Mantiene lo schermo acceso mentre l'ascolto è attivo.
                    UIApplication.shared.isIdleTimerDisabled = newValue
                }
        }
    }
}
