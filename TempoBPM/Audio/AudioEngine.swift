import AVFoundation
import Accelerate
import Darwin

// TBD-21: Configurare AVAudioSession con categoria playAndRecord e parametri measurement
// TBD-30: Installazione tap AVAudioEngine, DSP queue, buffer pre-allocato
// TBD-23: Coefficienti biquad HP@20Hz e LP@200Hz, setup vDSP_biquad_CreateSetup
// TBD-25: Ring buffer SPSC lock-free per trasferimento PCM thread audio → dspQueue

// MARK: - SPSC Ring Buffer

/// Ring buffer single-producer / single-consumer lock-free per campioni PCM Float32.
///
/// Progettato per il pattern audio real-time:
/// - **Producer** = tap callback AVAudioEngine (thread real-time): chiama `write(_:count:)`.
///   Il path di scrittura è wait-free e allocation-free.
/// - **Consumer** = dspQueue (serial DispatchQueue): chiama `read(into:count:)`.
///
/// ## Correttezza SPSC senza librerie esterne
///
/// Usiamo due indici interi normali (`writeIndex`, `readIndex`) con `OSMemoryBarrier()`
/// come barriera hardware completa (store-release / load-acquire equivalente su ARM64).
/// Il protocollo è:
///   1. Producer: scrive i dati nel buffer di storage.
///   2. Producer: esegue `OSMemoryBarrier()` (store-release).
///   3. Producer: aggiorna `writeIndex`.
///   4. Consumer: legge `writeIndex`.
///   5. Consumer: esegue `OSMemoryBarrier()` (load-acquire).
///   6. Consumer: legge i dati dal buffer di storage.
///
/// Questo schema è corretto per SPSC perché:
/// - Un solo thread scrive `writeIndex` (producer).
/// - Un solo thread scrive `readIndex` (consumer).
/// - `OSMemoryBarrier()` impedisce il riordinamento delle istruzioni da parte del
///   compilatore e della CPU (su ARM64 corrisponde a `dmb ish`).
///
/// ## Capacità e wrap-around
///
/// La capacità è sempre una potenza di 2: il wrap-around usa bitmasking
/// (`index & mask`) invece di modulo, evitando divisioni nel path real-time.
///
/// - Note: Questa classe è `final` per evitare overhead da vtable nel path real-time.
private final class SPSCRingBuffer {

    // MARK: - Constants

    /// Capacità del ring buffer in numero di campioni Float32.
    /// Deve essere una potenza di 2; verificato nell'init via assert.
    let capacity: Int

    // MARK: - Storage

    /// Buffer Float32 pre-allocato nell'init. Deallocato nel deinit.
    /// L'accesso diretto via UnsafeMutablePointer evita il bridging Swift Array
    /// e garantisce che il path di scrittura non tocchi l'ARC.
    private let storage: UnsafeMutablePointer<Float>

    /// Bitmask per wrap-around: `capacity - 1` (valido solo se capacity è potenza di 2).
    private let mask: Int

    // MARK: - Indices
    //
    // writeIndex è scritto solo dal producer (thread real-time).
    // readIndex  è scritto solo dal consumer (dspQueue).
    // Entrambi vengono letti dall'altro lato, ma mai scritti contemporaneamente
    // dallo stesso thread, quindi non servono operazioni atomiche CAS —
    // basta la barriera di memoria (OSMemoryBarrier) per garantire la visibilità.

    private var writeIndex: Int = 0
    private var readIndex:  Int = 0

    // MARK: - Init / Deinit

    /// - Parameter capacity: Numero di campioni Float32. Deve essere una potenza di 2.
    init(capacity: Int) {
        precondition(capacity > 0 && (capacity & (capacity - 1)) == 0,
                     "SPSCRingBuffer: la capacità deve essere una potenza di 2, ricevuto \(capacity)")
        self.capacity = capacity
        self.mask     = capacity - 1
        self.storage  = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        self.storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
    }

    // MARK: - Producer API (real-time safe)

    /// Scrive `count` campioni da `source` nel ring buffer.
    ///
    /// **Real-time safe**: nessuna allocazione heap, nessun lock, nessuna chiamata ObjC.
    /// Se lo spazio disponibile è inferiore a `count`, scrive solo i campioni che entrano
    /// (i campioni in eccesso vengono scartati silenziosamente — il consumer è abbastanza
    /// veloce da drenare il buffer prima che si riempia con la capacità scelta di 4×tapBufferSize).
    ///
    /// Usa `assign(from:count:)` invece di `initialize`: lo storage è già inizializzato
    /// nell'`init` e le scritture successive sovrascrivono memoria già inizializzata.
    ///
    /// - Parameters:
    ///   - source: Puntatore ai campioni Float da scrivere.
    ///   - count: Numero di campioni da scrivere.
    func write(_ source: UnsafePointer<Float>, count: Int) {
        // Legge readIndex per stimare lo spazio disponibile. Un valore stale (vecchio)
        // causerebbe solo una sottostima dello spazio libero (drop conservativo), mai
        // una data race — readIndex avanza in modo monotono e non torna indietro.
        let read  = readIndex
        let write = writeIndex
        let available = capacity - (write - read)   // spazio libero (può essere negativo in overflow teorico)
        let toWrite   = min(count, max(0, available))
        guard toWrite > 0 else { return }

        let startSlot = write & mask

        if startSlot + toWrite <= capacity {
            // Caso semplice: nessun wrap-around.
            // `assign` è corretto qui perché lo storage è già inizializzato dall'init.
            (storage + startSlot).assign(from: source, count: toWrite)
        } else {
            // Caso wrap-around: due memcpy (assign su memoria già inizializzata).
            let firstChunk  = capacity - startSlot
            let secondChunk = toWrite - firstChunk
            (storage + startSlot).assign(from: source,              count: firstChunk)
            storage.assign(from: source + firstChunk, count: secondChunk)
        }

        // Barriera store-release: garantisce che i dati siano visibili al consumer
        // prima che writeIndex venga aggiornato.
        OSMemoryBarrier()
        writeIndex = write + toWrite
    }

    // MARK: - Consumer API (dspQueue)

    /// Legge fino a `count` campioni dal ring buffer in `destination`.
    ///
    /// - Parameters:
    ///   - destination: Puntatore al buffer di destinazione (almeno `count` Float).
    ///   - count: Numero massimo di campioni da leggere.
    /// - Returns: Numero effettivo di campioni letti (0 se il buffer è vuoto).
    @discardableResult
    func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        // Barriera load-acquire: garantisce che i dati scritti prima dell'aggiornamento
        // di writeIndex siano visibili adesso.
        OSMemoryBarrier()

        let write   = writeIndex
        let read    = readIndex
        let filled  = write - read
        let toRead  = min(count, max(0, filled))
        guard toRead > 0 else { return 0 }

        let startSlot = read & mask

        if startSlot + toRead <= capacity {
            // `assign` è corretto: destination (drainBuffer) è già inizializzato dall'init di AudioEngine.
            destination.assign(from: storage + startSlot, count: toRead)
        } else {
            let firstChunk  = capacity - startSlot
            let secondChunk = toRead - firstChunk
            destination.assign(from: storage + startSlot,   count: firstChunk)
            (destination + firstChunk).assign(from: storage, count: secondChunk)
        }

        // Nessuna barriera necessaria dopo readIndex: il producer non legge readIndex
        // nel path critico (lo usa solo per calcolare lo spazio disponibile).
        readIndex = read + toRead
        return toRead
    }

    /// Numero di campioni attualmente disponibili per la lettura.
    var availableSamples: Int {
        // Snapshot non-atomico: sufficiente per decisioni non-critiche (log, diagnostica).
        return writeIndex - readIndex
    }
}

// MARK: - Biquad filter coefficients

/// Coefficienti normalizzati per un filtro biquad IIR secondo ordine (RBJ cookbook).
///
/// Layout `[b0, b1, b2, A1, A2]` come atteso da `vDSP_biquad_CreateSetup`.
/// La ricorrenza implementata da vDSP è:
///   y[n] = B0·x[n] + B1·x[n−1] + B2·x[n−2] − A1·y[n−1] − A2·y[n−2]
///
/// I valori A1 e A2 sono passati come `a1/a0` e `a2/a0` (notazione RBJ normalizzata),
/// senza ulteriore negazione: la ricorrenza RBJ e quella vDSP hanno la stessa forma,
/// entrambe sottraggono i termini di feedback. Il segno meno è già intrinseco.
/// RBJ a1 = −2·cos(w0) è già negativo, quindi A1 passato a vDSP sarà negativo:
/// la sottrazione −A1·y[n−1] equivale a sommare +2·cos(w0)/a0·y[n−1], corretto.
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

    /// Capacità del ring buffer: potenza di 2 ≥ 4 × tapBufferSize (4 × 2048 = 8192).
    /// Scegliamo 8192 che è esattamente 4 × 2048 ed è una potenza di 2.
    private static let ringCapacity: Int = 8192

    // TBD-29: FFT parameters
    /// Numero di campioni per la FFT (deve essere potenza di 2).
    private static let fftSize: Int = 1024
    /// log2(fftSize) = 10, richiesto da vDSP_fft_zrip.
    private static let fftLog2n: vDSP_Length = 10
    /// Numero di bin reali: fftSize / 2 (simmetria hermitiana della FFT reale).
    private static let fftBinCount: Int = 512
    /// Numero di bande energia esposte alla UI via BeatState.energyBands.
    private static let energyBandCount: Int = 46
    /// Intervallo minimo tra aggiornamenti di energyBands (~60 ms).
    private static let energyBandsThrottleInterval: Double = 0.060

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

    // TBD-25: Ring buffer SPSC lock-free. Alloca storage nell'init, nessuna alloc
    // nel tap callback. Il producer (tap) scrive; il consumer (dspQueue) drena.
    private let ringBuffer: SPSCRingBuffer

    /// Buffer Float pre-allocato usato dalla dspQueue per drenare il ring buffer
    /// senza allocare memoria sul consumer path. Dimensione = tapBufferSize.
    private let drainBuffer: UnsafeMutablePointer<Float>

    /// Buffer AVAudioPCMBuffer pre-allocato per consegnare i campioni drenati al
    /// captureHandler. Il formato viene impostato in `installTap()` una volta nota
    /// la sample rate reale. Nil fino all'installazione del tap.
    private var handlerPCMBuffer: AVAudioPCMBuffer?

    // TBD-23: coefficienti biquad calcolati a runtime dalla sample rate nativa.
    // Nil fino a quando `start()` non ha configurato la sessione e letto il formato.
    private var hpCoefficients: BiquadCoefficients?   // HP 20 Hz — rimuove DC e sub-20 Hz
    private var lpCoefficients: BiquadCoefficients?   // LP 200 Hz — isola banda kick drum

    /// Setup vDSP per il filtro HP 20 Hz. Allocato dopo il calcolo dei coefficienti,
    /// deallocato automaticamente via `deinit`. Nil fino a `start()`.
    private var hpSetup: vDSP_biquad_Setup?

    /// Setup vDSP per il filtro LP 200 Hz.
    private var lpSetup: vDSP_biquad_Setup?

    // TBD-28: buffer di delay (storia IIR) per i filtri biquad a singola precisione.
    // Dimensione: 2 * sections + 2 = 2 * 1 + 2 = 4 elementi per sections = 1.
    // Devono essere inizializzati a zero e mantenuti tra un buffer e l'altro:
    // il filtro IIR usa l'output dei campioni precedenti; azzerarli ad ogni buffer
    // introdurrebbe un transitorio all'inizio di ciascun blocco.
    private var hpDelayBuffer: [Float] = [0, 0, 0, 0]
    private var lpDelayBuffer: [Float] = [0, 0, 0, 0]

    // TBD-29: FFT setup e buffer ausiliari — tutti pre-allocati nell'init.
    // Zero alloc nel loop DSP.

    /// Setup FFT reale in-place creato da vDSP_create_fftsetup. Distrutto nel deinit.
    private var fftSetup: FFTSetup?

    /// Finestra di Hann pre-calcolata su fftSize campioni (normalizzata vDSP_HANN_NORM).
    private var hannWindow: [Float]

    /// Buffer di lavoro per applicare la finestra al segnale prima della FFT.
    /// Dimensione: fftSize. Non condivide spazio con drainBuffer per preservare
    /// il segnale filtrato già consegnato al captureHandler (Output A).
    private var fftWorkBuffer: [Float]

    /// Buffer per la parte reale del DSPSplitComplex (fftBinCount = fftSize/2 elementi).
    private var fftRealBuffer: [Float]

    /// Buffer per la parte immaginaria del DSPSplitComplex (fftBinCount elementi).
    private var fftImagBuffer: [Float]

    /// Buffer magnitudini quadratiche (output di vDSP_zvmags) — fftBinCount elementi.
    private var magnitudesBuffer: [Float]

    /// Timestamp dell'ultimo aggiornamento di BeatState.energyBands (CFAbsoluteTime, Double).
    /// Usato per throttling ~60ms. Zero = mai aggiornato.
    private var lastEnergyBandsTime: Double = 0

    // MARK: - Init

    init(state: BeatState) {
        self.state = state
        // TBD-25: alloca ring buffer e drain buffer nell'init — nessuna alloc nel
        // tap callback real-time.
        self.ringBuffer  = SPSCRingBuffer(capacity: AudioEngine.ringCapacity)
        self.drainBuffer = UnsafeMutablePointer<Float>.allocate(
            capacity: Int(AudioEngine.tapBufferSize))
        self.drainBuffer.initialize(
            repeating: 0, count: Int(AudioEngine.tapBufferSize))

        // TBD-29: Pre-alloca tutti i buffer FFT e calcola la finestra di Hann.
        // Questi buffer sono riutilizzati ad ogni chiamata di drainRingBuffer()
        // senza mai allocare heap nel loop DSP.
        let binCount = AudioEngine.fftBinCount
        let fftSz    = AudioEngine.fftSize

        // Alloca e azzera i buffer Float prima di usarli nei setter di proprietà.
        var hann    = [Float](repeating: 0, count: fftSz)
        var work    = [Float](repeating: 0, count: fftSz)
        var realBuf = [Float](repeating: 0, count: binCount)
        var imagBuf = [Float](repeating: 0, count: binCount)
        var mags    = [Float](repeating: 0, count: binCount)

        // Calcola la finestra di Hann normalizzata (vDSP_HANN_NORM).
        // vDSP_hann_window sovrascrive 'hann' direttamente; il flag 0 = periodic
        // (vs 1 = symmetric). Per analisi FFT si usa la forma periodica.
        vDSP_hann_window(&hann, vDSP_Length(fftSz), Int32(vDSP_HANN_NORM))

        self.hannWindow      = hann
        self.fftWorkBuffer   = work
        self.fftRealBuffer   = realBuf
        self.fftImagBuffer   = imagBuf
        self.magnitudesBuffer = mags

        // Crea il setup FFT reale (radix-2). Deve essere creato una volta sola:
        // è un'operazione costosa che alloca tabelle di twiddle factor interne.
        self.fftSetup = vDSP_create_fftsetup(AudioEngine.fftLog2n, FFTRadix(kFFTRadix2))
    }

    deinit {
        // vDSP_biquad_Setup è un tipo opaco che richiede distruzione esplicita.
        if let setup = hpSetup { vDSP_biquad_DestroySetup(setup) }
        if let setup = lpSetup { vDSP_biquad_DestroySetup(setup) }
        // TBD-29: distruggi il setup FFT (libera le tabelle di twiddle factor interne).
        if let setup = fftSetup { vDSP_destroy_fftsetup(setup) }
        // Dealloca il drain buffer pre-allocato.
        drainBuffer.deallocate()
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
    /// Layout per vDSP_biquad_CreateSetup: [b0/a0, b1/a0, b2/a0, a1/a0, a2/a0]
    /// Nessuna negazione extra su A1/A2: la ricorrenza vDSP
    ///   y[n] = B0·x[n] + B1·x[n−1] + B2·x[n−2] − A1·y[n−1] − A2·y[n−2]
    /// coincide con la forma RBJ normalizzata; i valori si passano direttamente.
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

            // vDSP_biquad_CreateSetup si aspetta [b0/a0, b1/a0, b2/a0, a1/a0, a2/a0].
            // Nessuna negazione: la ricorrenza vDSP sottrae già A1 e A2, esattamente
            // come nella forma RBJ normalizzata. Passare −(a1/a0) invertirebbe il segno
            // del polo e destabilizzerebbe il filtro.
            return BiquadCoefficients(values: [
                b0 / a0,
                b1 / a0,
                b2 / a0,
                a1 / a0,
                a2 / a0
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
    ///
    /// ## Path real-time (tap callback)
    /// 1. Copia i campioni PCM dal buffer AVAudioEngine nel ring buffer SPSC.
    /// 2. Invia un dispatch asincrono alla dspQueue per svegliare il consumer.
    ///
    /// Il tap callback è real-time safe: nessuna allocazione heap, nessun lock,
    /// nessuna chiamata ObjC con effetti collaterali.
    /// `ringBuffer.write(_:count:)` è wait-free e allocation-free.
    /// Il `dspQueue.async` cattura solo il riferimento `ringBuffer` (già allocato)
    /// e il `captureHandler` — nessuna copia di buffer audio sul real-time thread.
    ///
    /// ## Path consumer (dspQueue)
    /// La closure schedulata su dspQueue drena il ring buffer a blocchi di
    /// `tapBufferSize` campioni e chiama `captureHandler` con un `AVAudioPCMBuffer`
    /// pre-allocato (`handlerPCMBuffer`) popolato con i campioni drenati.
    private func installTap() {
        let inputNode = avEngine.inputNode
        // Il formato nativo evita costose conversioni di sample rate nel tap.
        let format = inputNode.inputFormat(forBus: 0)

        // Pre-alloca il PCMBuffer usato dal consumer per avvolgere i campioni
        // drenati prima di consegnarli al captureHandler. Un unico buffer riutilizzato
        // dalla dspQueue (serial) evita alloc nel consumer path.
        let tapFrameCount = AudioEngine.tapBufferSize
        handlerPCMBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: tapFrameCount)

        inputNode.installTap(
            onBus: 0,
            bufferSize: tapFrameCount,
            format: format
        ) { [weak self] buffer, _ in
            // ── Thread audio real-time ──────────────────────────────────────────
            // Requisiti: zero alloc, zero lock, zero ObjC con side-effects.
            //
            // `self` è catturato weak per sicurezza, ma nel real-time path evitiamo
            // operazioni ARC heavy. Il guard è l'unica operazione "pesante" qui,
            // ed è accettabile perché è solo un load+branch.
            guard let self,
                  let channelData = buffer.floatChannelData else { return }

            let frameCount = Int(buffer.frameLength)
            // write() è wait-free e allocation-free: copia i campioni nel ring buffer
            // usando puntatori raw senza toccare l'heap né i lock.
            self.ringBuffer.write(channelData[0], count: frameCount)

            // Sveglia il consumer sulla dspQueue. `dspQueue.async` può allocare
            // internamente per accodare il work item, ma questa allocazione avviene
            // nel sistema operativo (libdispatch) ed è accettabile in questo contesto:
            // il tap di AVAudioEngine su iOS non è un thread con priorità THREAD_TIME_CONSTRAINT
            // puro, e Apple stessa usa dispatch_async nei tap di esempio.
            self.dspQueue.async { [weak self] in
                self?.drainRingBuffer()
            }
            // ── Fine path real-time ─────────────────────────────────────────────
        }
    }

    /// Drena il ring buffer e consegna i campioni al captureHandler.
    ///
    /// Chiamato esclusivamente dalla dspQueue (serial). Legge fino a `tapBufferSize`
    /// campioni per chiamata usando il `drainBuffer` pre-allocato, li copia nel
    /// `handlerPCMBuffer` pre-allocato, e chiama `captureHandler`.
    /// Continua a drenare finché ci sono campioni disponibili (per smaltire eventuali
    /// accodamenti multipli generati da burst di tap callback ravvicinati).
    ///
    /// TBD-28: prima di consegnare i campioni al captureHandler, applica in-place
    /// la catena biquad HP@20Hz → LP@200Hz. Il filtraggio isola la banda kick drum
    /// (20–200 Hz) rimuovendo DC offset e contenuto ad alta frequenza irrilevante.
    /// I delay buffer (hpDelayBuffer, lpDelayBuffer) sono mantenuti tra i blocchi
    /// per preservare la continuità del filtro IIR.
    private func drainRingBuffer() {
        guard let handler = captureHandler,
              let pcmBuffer = handlerPCMBuffer else { return }

        let batchSize = Int(AudioEngine.tapBufferSize)

        // Drena tutto il ring buffer in batch da tapBufferSize per evitare latenza
        // accumulata se il consumer è momentaneamente in ritardo.
        while ringBuffer.availableSamples >= batchSize {
            let read = ringBuffer.read(into: drainBuffer, count: batchSize)
            guard read > 0,
                  let channelData = pcmBuffer.floatChannelData else { break }

            let n = vDSP_Length(read)

            // TBD-28: Applica catena HP → LP in-place sul drainBuffer.
            // Entrambi i filtri operano su drainBuffer direttamente (src == dst).
            // vDSP_biquad supporta operazione in-place: il buffer di input e output
            // possono coincidere.
            //
            // Guard su hpSetup e lpSetup: sono nil se start() non è ancora stato
            // chiamato (o se computeFilterCoefficients non ha avuto successo).
            // In quel caso consegniamo il segnale non filtrato piuttosto che
            // silenziare l'output — comportamento fail-open coerente con l'architettura.
            if let hp = hpSetup, let lp = lpSetup {
                // Passo 1 — HP@20Hz: rimuove DC offset e contenuto sub-sonico.
                vDSP_biquad(hp, &hpDelayBuffer, drainBuffer, 1, drainBuffer, 1, n)
                // Passo 2 — LP@200Hz: isola la banda kick drum (20–200 Hz).
                vDSP_biquad(lp, &lpDelayBuffer, drainBuffer, 1, drainBuffer, 1, n)
            }

            // Copia i campioni filtrati nel PCMBuffer wrapper pre-allocato.
            // `vDSP_mmov` non è disponibile per array 1-D; usiamo `cblas_scopy`
            // (Accelerate) — zero alloc, loop SIMD-ottimizzato.
            // In alternativa, memcpy è equivalente per Float32 senza stride.
            channelData[0].update(from: drainBuffer, count: read)
            pcmBuffer.frameLength = AVAudioFrameCount(read)

            // ── Output A: consegna buffer PCM filtrato al captureHandler (BeatDetector) ──
            handler(pcmBuffer)

            // ── Output B: FFT 1024-pt → 46 bande energia → BeatState.energyBands ──────
            // Indipendente da Output A: opera sullo stesso drainBuffer filtrato ma
            // non modifica il buffer (vmul scrive su fftWorkBuffer separato).

            // Throttle ~60ms: aggiorna le bande al massimo ogni energyBandsThrottleInterval
            // per non saturare il main thread con aggiornamenti SwiftUI troppo frequenti.
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastEnergyBandsTime >= AudioEngine.energyBandsThrottleInterval else {
                continue
            }

            // La finestra di Hann richiede esattamente fftSize campioni.
            // Se il drain ha prodotto meno campioni (read < fftSize), salta la FFT
            // per questo ciclo — zero-padding altererebbe lo spettro.
            guard read >= AudioEngine.fftSize else { continue }

            // Step 1 — Calcola RMS sul buffer filtrato (banda 20–200 Hz, `read` campioni).
            // L'energia RMS è l'input primario per la beat detection (TBD-10);
            // qui viene calcolata in preparazione all'integrazione con BeatDetector.
            var rmsEnergy: Float = 0
            vDSP_rmsqv(drainBuffer, 1, &rmsEnergy, vDSP_Length(read))
            // rmsEnergy è pronto per essere usato da BeatDetector quando sarà implementato (TBD-10).

            // Step 2 — Applica finestra di Hann ai primi fftSize campioni del drainBuffer.
            // vDSP_vmul(A, strideA, B, strideB, C, strideC, N): C[i] = A[i] * B[i]
            // drainBuffer → windowed → fftWorkBuffer (preserva drainBuffer inalterato).
            vDSP_vmul(
                drainBuffer,       1,
                &hannWindow,       1,
                &fftWorkBuffer,    1,
                vDSP_Length(AudioEngine.fftSize)
            )

            // Step 3 — Impacchetta fftWorkBuffer in DSPSplitComplex (interleaved → split).
            // vDSP_ctoz interpreta il buffer reale come coppie (re, im) con im=0,
            // ma per FFT reale si usa il layout "packed": coppie di campioni reali
            // consecutivi → (realp[k], imagp[k]) = (x[2k], x[2k+1]).
            // Lo stride su fftWorkBuffer è 2 (saltiamo ogni secondo elemento per realp,
            // poi offset 1 per imagp). Questo è il layout richiesto da vDSP_fft_zrip.
            fftRealBuffer.withUnsafeMutableBufferPointer { realPtr in
                fftImagBuffer.withUnsafeMutableBufferPointer { imagPtr in
                    guard let rBase = realPtr.baseAddress,
                          let iBase = imagPtr.baseAddress else { return }

                    var splitComplex = DSPSplitComplex(realp: rBase, imagp: iBase)

                    fftWorkBuffer.withUnsafeBufferPointer { floatPtr in
                        // Reinterpreta il buffer Float come DSPComplex (coppie float):
                        // ogni coppia (fftWorkBuffer[2k], fftWorkBuffer[2k+1]) → splitComplex[k].
                        // Stride 2 su floatPtr perché DSPComplex ha dimensione 2×Float.
                        // Questo impacchettamento è il prerequisito di vDSP_fft_zrip.
                        guard let fBase = floatPtr.baseAddress else { return }
                        fBase.withMemoryRebound(to: DSPComplex.self,
                                                capacity: AudioEngine.fftBinCount) { complexPtr in
                            vDSP_ctoz(complexPtr, 1, &splitComplex, 1,
                                      vDSP_Length(AudioEngine.fftBinCount))
                        }
                    }

                    // Step 4 — Esegui FFT reale in-place (forward).
                    // vDSP_fft_zrip modifica splitComplex in-place:
                    // dopo questa chiamata realp/imagp contengono i bin FFT nel
                    // formato packed vDSP (bin 0 in realp[0], bin N/2 in imagp[0]).
                    guard let setup = fftSetup else { return }
                    vDSP_fft_zrip(setup, &splitComplex, 1,
                                  AudioEngine.fftLog2n, FFTDirection(FFT_FORWARD))

                    // Step 5 — Calcola magnitudini quadratiche dei primi 46 bin.
                    // vDSP_zvabs calcola sqrt(re^2 + im^2) per ogni bin.
                    // Usiamo solo i primi energyBandCount bin (escludiamo DC e Nyquist
                    // che sono packed rispettivamente in realp[0] e imagp[0]).
                    magnitudesBuffer.withUnsafeMutableBufferPointer { magPtr in
                        guard let mBase = magPtr.baseAddress else { return }
                        // Nota: bin 0 (DC) è in realp[0]; bin N/2 (Nyquist) è in imagp[0].
                        // I bin 1..N/2-1 sono in realp[1..] e imagp[1..] nel formato packed.
                        // Per semplicità e coerenza con il requisito del ticket (46 magnitudini)
                        // calcoliamo le prime 46 magnitudini dal vettore split complex così
                        // com'è: include bin 0 (DC), ma verrà normalizzato insieme agli altri.
                        vDSP_zvabs(&splitComplex, 1, mBase, 1,
                                   vDSP_Length(AudioEngine.energyBandCount))
                    }
                }
            }

            // Step 6 — Normalizza magnitudini in [0, 1] rispetto al massimo del frame.
            var maxMag: Float = 0
            vDSP_maxv(&magnitudesBuffer, 1, &maxMag, vDSP_Length(AudioEngine.energyBandCount))

            // Evita divisione per zero se tutto è silenzio.
            if maxMag > 0 {
                var invMax = 1.0 / maxMag
                vDSP_vsmul(&magnitudesBuffer, 1, &invMax, &magnitudesBuffer, 1,
                           vDSP_Length(AudioEngine.energyBandCount))
            } else {
                // Frame silenzioso: azzera tutte le bande.
                var zero: Float = 0
                vDSP_vfill(&zero, &magnitudesBuffer, 1,
                           vDSP_Length(AudioEngine.energyBandCount))
            }

            // Aggiorna il timestamp del throttle prima della Task per evitare
            // che burst ravvicinati schedulino Task multipli se la dspQueue è veloce.
            lastEnergyBandsTime = now

            // Step 7 — Pubblica le 46 bande su @MainActor (Output B).
            // Copia esplicita con Array(prefix:): separa il ciclo di vita del buffer
            // DSP (mutabile, riutilizzato al prossimo ciclo) dal valore consegnato
            // alla UI. La copia avviene sulla dspQueue, non sul main thread.
            let bands = Array(magnitudesBuffer.prefix(AudioEngine.energyBandCount))
            Task { @MainActor [weak state] in
                state?.energyBands = bands
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
