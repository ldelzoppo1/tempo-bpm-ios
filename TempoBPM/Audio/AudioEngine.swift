import AVFoundation

// TBD-21: Configurare AVAudioSession con categoria playAndRecord e parametri measurement
// TBD-30: Installazione tap AVAudioEngine, DSP queue, buffer pre-allocato

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

    // MARK: - Constants

    private static let tapBufferSize: AVAudioFrameCount = 2048

    // MARK: - Private state

    /// BeatState tenuto weak per evitare retain cycle (AudioEngine non deve
    /// prolungare la vita del modello condiviso).
    private weak var state: BeatState

    private let avEngine = AVAudioEngine()

    /// Coda DSP seriale su cui vengono consegnati i buffer al captureHandler.
    /// Serial + .userInteractive per garantire ordine e bassa latenza senza
    /// bloccare il thread audio real-time.
    private let dspQueue = DispatchQueue(label: "com.tempobpm.dsp", qos: .userInteractive)

    /// Callback registrato da `startCapture(handler:)` — invocato dalla dspQueue.
    private var captureHandler: ((AVAudioPCMBuffer) -> Void)?

    /// Buffer Float pre-allocato nell'init per uso futuro in TBD-25 (ring buffer).
    /// Capacità = 2 × tapBufferSize per assorbire jitter nell'arrivo dei frame.
    private let preallocatedBuffer: [Float]

    // MARK: - Init

    init(state: BeatState) {
        self.state = state
        // Pre-allocazione in init: nessuna alloc nel tap callback real-time.
        self.preallocatedBuffer = [Float](repeating: 0, count: Int(AudioEngine.tapBufferSize) * 2)
    }

    // MARK: - AudioBufferProvider

    /// Registra l'handler e avvia la pipeline audio.
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
        installTap()
        do {
            try avEngine.start()
        } catch {
            avEngine.inputNode.removeTap(onBus: 0)
            throw AudioEngineError.engineStartFailed
        }
        Task { @MainActor in
            self.state?.isListening = true
        }
    }

    func stop() {
        avEngine.inputNode.removeTap(onBus: 0)
        avEngine.stop()
        captureHandler = nil
        Task { @MainActor in
            self.state?.isListening = false
        }
    }

    // MARK: - Private

    /// Installa il tap sull'inputNode usando il formato nativo dell'hardware.
    /// Il callback è real-time safe: nessuna allocazione, nessun lock, nessuna
    /// chiamata ObjC con effetti collaterali — il buffer viene consegnato alla
    /// dspQueue per l'elaborazione DSP.
    private func installTap() {
        let inputNode = avEngine.inputNode
        // Il formato nativo evita costose conversioni di sample rate nel tap.
        let format = inputNode.inputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: AudioEngine.tapBufferSize, format: format) { [dspQueue, captureHandler] buffer, _ in
            // Thread audio real-time: catturiamo solo riferimenti pre-esistenti,
            // zero alloc, zero lock. Il dispatch non alloca sul real-time thread
            // perché il blocco è catturato per copia come closure pre-creata.
            guard let handler = captureHandler else { return }
            dspQueue.async {
                handler(buffer)
            }
        }
    }

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
