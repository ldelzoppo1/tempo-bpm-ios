import AVFoundation
import Accelerate

// TBD-21: Configurare AVAudioSession con categoria playAndRecord e parametri measurement
// TBD-30: Installazione tap AVAudioEngine, DSP queue, buffer pre-allocato
// TBD-23: Coefficienti biquad HP@20Hz e LP@200Hz, setup vDSP_biquad_CreateSetup

// MARK: - Biquad filter coefficients

/// Coefficienti normalizzati per un filtro biquad IIR secondo ordine (RBJ cookbook).
///
/// Layout `[b0, b1, b2, A1, A2]` come atteso da `vDSP_biquad_CreateSetup`.
/// La ricorrenza implementata da vDSP è:
///   y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] − A1·y[n-1] − A2·y[n-2]
///
/// I valori A1 e A2 sono passati come `a1/a0` e `a2/a0` (notazione RBJ normalizzata),
/// senza ulteriore negazione: il segno meno nella ricorrenza è già nella formula vDSP.
/// Poiché RBJ definisce a1 = −2·cos(w0) (valore negativo), A1 risulterà negativo,
/// e la sottrazione −A1·y[n-1] diventa di fatto una addizione, come atteso.
struct BiquadCoefficients {
    /// `[b0/a0, b1/a0, b2/a0, a1/a0, a2/a0]` in Double,
    /// come richiesto da `vDSP_biquad_CreateSetup`.
    let values: [Double]
}

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

    // TBD-23: coefficienti biquad calcolati a runtime dalla sample rate nativa.
    // Nil fino a quando `start()` non ha configurato la sessione e letto il formato.
    private var hpCoefficients: BiquadCoefficients?   // HP 20 Hz — rimuove DC e sub-20 Hz
    private var lpCoefficients: BiquadCoefficients?   // LP 200 Hz — isola banda kick drum

    /// Setup vDSP per il filtro HP 20 Hz. Allocato dopo il calcolo dei coefficienti,
    /// deallocato automaticamente via `deinit`. Nil fino a `start()`.
    private var hpSetup: vDSP_biquad_Setup?

    /// Setup vDSP per il filtro LP 200 Hz.
    private var lpSetup: vDSP_biquad_Setup?

    // MARK: - Init

    init(state: BeatState) {
        self.state = state
        // Pre-allocazione in init: nessuna alloc nel tap callback real-time.
        self.preallocatedBuffer = [Float](repeating: 0, count: Int(AudioEngine.tapBufferSize) * 2)
    }

    deinit {
        // vDSP_biquad_Setup è un tipo opaco che richiede distruzione esplicita.
        if let setup = hpSetup { vDSP_biquad_DestroySetup(setup) }
        if let setup = lpSetup { vDSP_biquad_DestroySetup(setup) }
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
        // TBD-23: i coefficienti dipendono dalla sample rate effettiva negoziata
        // da AVAudioSession, quindi vengono calcolati dopo l'attivazione della sessione.
        computeFilterCoefficients(sampleRate: AVAudioSession.sharedInstance().sampleRate)
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

    /// Calcola i coefficienti biquad RBJ per il filtro HP@20Hz e LP@200Hz
    /// alla sample rate effettiva negoziata da AVAudioSession.
    ///
    /// Formula RBJ cookbook (bilinear transform, Butterworth Q=0.707≈1/√2):
    ///   w0    = 2π·fc/fs
    ///   alpha = sin(w0) / (2·Q)
    ///
    /// HP:  b0=(1+cos(w0))/2  b1=-(1+cos(w0))  b2=(1+cos(w0))/2
    /// LP:  b0=(1-cos(w0))/2  b1=  1-cos(w0)   b2=(1-cos(w0))/2
    /// Comune: a0=1+alpha  a1=-2·cos(w0)  a2=1-alpha
    ///
    /// Normalizzazione: tutti i coefficienti divisi per a0.
    /// Layout per vDSP_biquad_CreateSetup: [b0/a0, b1/a0, b2/a0, −a1/a0, −a2/a0]
    /// Il segno negato su A1 e A2 riflette la convenzione vDSP:
    ///   y[n] = b0·x[n] + b1·x[n−1] + b2·x[n−2] − A1·y[n−1] − A2·y[n−2]
    private func computeFilterCoefficients(sampleRate: Double) {
        // Butterworth maximally-flat magnitude: Q = 1/√2 ≈ 0.70710678
        let q = 1.0 / 2.0.squareRoot()

        func biquad(fc: Double, isHighPass: Bool) -> BiquadCoefficients {
            let w0    = 2.0 * Double.pi * fc / sampleRate
            let cosW0 = cos(w0)
            let sinW0 = sin(w0)
            let alpha = sinW0 / (2.0 * q)
            let a0    = 1.0 + alpha

            let (b0, b1, b2): (Double, Double, Double)
            if isHighPass {
                // HP: passa frequenze > fc, attenua frequenze < fc
                b0 = (1.0 + cosW0) / 2.0
                b1 = -(1.0 + cosW0)
                b2 = (1.0 + cosW0) / 2.0
            } else {
                // LP: passa frequenze < fc, attenua frequenze > fc
                b0 = (1.0 - cosW0) / 2.0
                b1 =  1.0 - cosW0
                b2 = (1.0 - cosW0) / 2.0
            }

            let a1 = -2.0 * cosW0   // RBJ a1, già con segno canonico
            let a2 = 1.0 - alpha    // RBJ a2

            // vDSP_biquad_CreateSetup si aspetta [b0, b1, b2, A1, A2] dove
            // A1 = −(a1/a0) e A2 = −(a2/a0) per il segno della ricorrenza.
            return BiquadCoefficients(values: [
                b0 / a0,
                b1 / a0,
                b2 / a0,
                -(a1 / a0),
                -(a2 / a0)
            ])
        }

        // Filtro HP 20 Hz: rimuove DC offset e contenuto sub-sonico
        let hp = biquad(fc: 20.0, isHighPass: true)
        hpCoefficients = hp
        // sections = 1: filtro biquad singolo del secondo ordine
        if let setup = hpSetup { vDSP_biquad_DestroySetup(setup) }
        hpSetup = vDSP_biquad_CreateSetup(hp.values, 1)

        // Filtro LP 200 Hz: isola banda kick drum (20–200 Hz)
        let lp = biquad(fc: 200.0, isHighPass: false)
        lpCoefficients = lp
        if let setup = lpSetup { vDSP_biquad_DestroySetup(setup) }
        lpSetup = vDSP_biquad_CreateSetup(lp.values, 1)
    }

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
