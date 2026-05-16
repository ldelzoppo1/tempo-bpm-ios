import AVFoundation

// TBD-21: Configurare AVAudioSession con categoria playAndRecord e parametri measurement
// TBD-30: Installazione tap AVAudioEngine (prossimo subtask)

// MARK: - Error types

enum AudioEngineError: Error {
    case microphonePermissionDenied
    case engineStartFailed
}

// MARK: - AudioEngine

/// Gestisce la pipeline AVAudioEngine e la configurazione AVAudioSession.
/// Chiamare `start()` su un thread non-main (non blocca la UI, ma usa un semaforo
/// interno per attendere la risposta sincrona al prompt di permesso microfono).
final class AudioEngine: AudioBufferProvider {

    // MARK: - Private state

    private let state: BeatState
    private let avEngine = AVAudioEngine()

    /// Callback registrato da `startCapture(handler:)` — chiamato dal tap real-time.
    private var captureHandler: ((AVAudioPCMBuffer) -> Void)?

    // MARK: - Init

    init(state: BeatState) {
        self.state = state
    }

    // MARK: - AudioBufferProvider

    /// Avvia la sessione audio e installa il tap sull'input node.
    /// - Throws: `AudioEngineError.microphonePermissionDenied` se il permesso è negato.
    /// - Throws: `AudioEngineError.engineStartFailed` se AVAudioEngine non si avvia.
    /// - Note: Non chiamare dal main thread — `requestRecordPermission` viene reso
    ///   sincrono tramite semaforo; bloccare il main thread causerebbe un deadlock.
    func startCapture(handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        captureHandler = handler
        try start()
    }

    func stopCapture() {
        stop()
    }

    // MARK: - Public interface (ARCHITECTURE.md)

    func start() throws {
        try requestMicrophonePermission()
        try configureAudioSession()
        Task { @MainActor in
            self.state.isListening = true
        }
    }

    func stop() {
        avEngine.stop()
        captureHandler = nil
        Task { @MainActor in
            self.state.isListening = false
        }
    }

    // MARK: - Private

    /// Verifica o richiede il permesso microfono in modo sincrono.
    /// - Throws: `AudioEngineError.microphonePermissionDenied` se negato o non concesso.
    private func requestMicrophonePermission() throws {
        let session = AVAudioSession.sharedInstance()

        switch session.recordPermission {
        case .granted:
            return

        case .denied:
            throw AudioEngineError.microphonePermissionDenied

        case .undetermined:
            // Usiamo un semaforo per rendere sincrono il completionHandler.
            // Questo è sicuro purché `start()` non venga chiamato dal main thread.
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            session.requestRecordPermission { result in
                granted = result
                semaphore.signal()
            }
            semaphore.wait()
            if !granted {
                throw AudioEngineError.microphonePermissionDenied
            }

        @unknown default:
            throw AudioEngineError.microphonePermissionDenied
        }
    }

    /// Configura AVAudioSession con i parametri per acquisizione microfono a bassa latenza.
    /// - Throws: rethrows gli errori di configurazione AVAudioSession.
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.mixWithOthers, .allowBluetooth]
        )
        try session.setPreferredSampleRate(44100)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
    }
}
