import AVFoundation
import Accelerate
import os.log

#if DEBUG
private let bdLog = Logger(subsystem: "com.ldelzoppo.tempo", category: "BeatDetector")
#endif

// MARK: - BeatDetector

/// Rileva gli onset da un buffer PCM pre-filtrato (banda 30–250 Hz) e notifica
/// tramite la closure `onOnset`.
///
/// Questa classe è un puro onset detector: non calcola BPM né pubblica statistiche
/// di sessione. Il calcolo BPM e le statistiche sono delegati a RhythmAnalyzer
/// (TBD-68), che riceve gli onset tramite la closure `onOnset`.
///
/// ## Algoritmo
///
/// **Onset detection**
/// 1. RMS corrente del buffer PCM.
/// 2. Soglia dinamica = media + deviazione standard dell'energia in finestra
///    scorrevole adattiva (4 beat stimati, tra 22 e 64 buffer a 44100/2048 Hz).
/// 3. Onset se `rms > soglia`.
/// 4. Refrattario: minimo 350 ms tra onset (max 171 BPM).
/// 5. Holddown anti-risonanza: entro 380 ms dall'ultimo onset, il nuovo onset
///    viene accettato solo se la sua energia ≥ 20 % di quella precedente.
///    Previene la doppia rilevazione della coda di decadimento della cassa.
/// 6. Intervallo massimo: 2400 ms — intervalli più lunghi indicano pausa.
/// 7. Outlier rejection: nuovo intervallo scartato se devia > ±13 % dalla
///    mediana degli ultimi 4 intervalli validi (IOI).
///
/// ## Threading
/// `process(buffer:)` è chiamato sincrono dalla DSP queue di AudioEngine.
/// La closure `onOnset` è invocata sulla stessa DSP queue.
/// Le scritture su BeatState (`beatPosition`, `beatFlash`) avvengono via
/// `Task { @MainActor in … }`.
final class BeatDetector: @unchecked Sendable {

    // MARK: DSP constants

    /// Dimensione minima della finestra energia (usata a BPM alti, ~220 BPM → ~1 s).
    private nonisolated static var energyWindowSize: Int { 22 }

    /// Dimensione massima della finestra energia (usata a BPM bassi o senza stima → ~3 s).
    /// Pre-allocata all'init: nessuna alloc nel loop hot.
    private nonisolated static var energyWindowMaxSize: Int { 64 }

    /// Onset se rms > media + std × onsetSigma.
    private nonisolated static var onsetSigma: Float { 1.0 }

    /// Periodo refrattario minimo tra due onset (350 ms → max 171 BPM).
    /// Abbassato da 400 ms per coprire punk, ska veloce e rock a 160–171 BPM.
    /// Le risonanze della cassa nella finestra 350–380 ms rimangono filtrate
    /// dall'holddown (holddownSeconds = 0.380, resonanceHolddownRatio = 0.20).
    private nonisolated static var refractorySeconds: Double { 0.350 }

    /// Finestra holddown anti-risonanza: dopo un onset, un nuovo onset viene
    /// accettato entro questa finestra solo se la sua energia ≥
    /// resonanceHolddownRatio × energia dell'ultimo onset.
    /// 380 ms: il decay della cassa produce < 10 % dell'energia originale a
    /// questo punto — bloccato dal ratio 0.20. Abbassato da 450 ms per evitare
    /// che il kick successivo in four-on-the-floor a 136 BPM (IOI = 441 ms)
    /// cadesse dentro la holddown window con margine negativo.
    private nonisolated static var holddownSeconds: Double { 0.380 }

    /// Frazione minima di energia rispetto all'ultimo onset per onset nella
    /// holddown window. Le risonanze della cassa sono tipicamente ≤ 15%;
    /// 0.20 blocca le risonanze lasciando passare rullanti (tipicamente 25-60%
    /// del kick anche da speaker del telefono).
    private nonisolated static var resonanceHolddownRatio: Float { 0.20 }

    /// Intervallo massimo valido tra onset (2400 ms → min 25 BPM).
    /// Alzato da 2000 ms per coprire 3/4, 7/4 e brani lenti con kick rado
    /// (doom metal, ballad jazz) dove l'intervallo kick supera i 2000 ms.
    private nonisolated static var maxIntervalSeconds: Double { 2.400 }

    /// Soglia outlier: intervallo scartato se devia > 13 % dalla mediana degli ultimi N.
    /// Un batterista umano non varia il tempo di più del 5-8% tra beat consecutivi;
    /// 13% lascia margine per micro-timing naturale senza accettare falsi positivi.
    private nonisolated static var outlierThreshold: Double { 0.13 }

    /// Numero di intervalli nella finestra BPM (media mobile).
    private nonisolated static var bpmWindowSize: Int { 4 }

    /// Energia RMS minima assoluta per entrare nell'onset detection.
    /// Contesto target: batterista live o musica amplificata nel mic del telefono.
    /// Kick reali ≥ 0.05 rms; rumore ambiente tipico 0.001–0.020 rms.
    /// 0.040 blocca transienti ambientali senza escludere i colpi più soft.
    private nonisolated static var minimumOnsetRms: Float { 0.040 }

    // MARK: Live mode constants

    /// Soglia flux: onset se flux > media + std × liveFluxSigma.
    /// Più alta di onsetSigma perché il flux (derivata) è più rumoroso dell'energia assoluta.
    /// Usiamo il segnale 30–250 Hz già pre-filtrato da AudioEngine e rileviamo le salite
    /// di energia (transients) invece dei livelli assoluti — più reattivo del livello RMS
    /// assoluto in presenza di un noise floor elevato (monitor, ampli basso, riverbero PA).
    private nonisolated static var liveFluxSigma: Float { 1.5 }

    /// kickRatio minimo per accettare un onset come grancassa in modalità LIVE.
    /// Valore inferiore a kickRatioThreshold (0.35 in SOLO) perché in LIVE il segnale
    /// è già gatedato dal flux: il kick near-field (0.5–1 m) produce kickRatio ≈ 0.35–0.60,
    /// mentre snare/cymbal bleed dai monitor hanno kickRatio ≈ 0.05–0.15 e sarebbero
    /// accettati senza questo filtro.
    /// 0.20 blocca snare bleed e vibrazioni broadband (caso 1 e 2) accettando tutti i kick
    /// near-field. Le note gravi del basso (kickRatio 0.30–0.45 a ~3 m) cadono nella zona
    /// ambigua: parzialmente filtrate dal minimumOnsetRms e dall'SPL near-field del kick.
    private nonisolated static var liveKickRatioThreshold: Float { 0.20 }

    /// Energia RMS minima assoluta per entrare nell'onset detection in modalità LIVE.
    /// Più alta di minimumOnsetRms (0.040 in SOLO) perché in LIVE il noise floor è
    /// significativamente più elevato: monitor laterali, ampli basso e vibrazioni del palco
    /// producono RMS continuo tipicamente 0.020–0.050. Con 0.040 questi segnali ambientali
    /// possono superare il gate e raggiungere il flux detector generando falsi positivi.
    /// 0.060 (50% superiore a SOLO) garantisce che il gate blocchi il noise floor del palco:
    /// il kick near-field (telefono sul kit) produce RMS ≥ 0.080–0.150 → margine adeguato.
    /// Le note gravi del basso a ~3 m producono RMS tipicamente 0.020–0.050 — sotto la soglia.
    private nonisolated static var liveMinimumOnsetRms: Float { 0.060 }

    // MARK: Kick classification constants

    /// Cutoff LP per separare banda cassa (< 100 Hz) dal rullante (100–250 Hz).
    private nonisolated static var kickCutoffHz: Double { 100.0 }

    /// kickRatio minimo per accettare un onset come grancassa in modalità Solo.
    /// Alzato a 0.35 rispetto al precedente 0.28 per ridurre i falsi positivi
    /// da tom medio e colpi forti sul rullante che ricadono in banda 40–250 Hz.
    private nonisolated static var kickRatioThreshold: Float { 0.35 }

    // MARK: Public interface — onset notification

    /// Closure invocata ad ogni onset valido con `(timestamp: Double, rms: Float)`.
    /// Il timestamp è `CACurrentMediaTime()` al momento dell'onset.
    /// Chiamata sulla DSP queue — non fare allocazioni o chiamate ObjC nel body.
    nonisolated(unsafe) var onOnset: ((Double, Float) -> Void)?

    // MARK: Private state
    // nonisolated(unsafe): tutto acceduto dalla sola DSP queue (serial), concorrenza
    // manuale garantita dall'uso esclusivo da un singolo DispatchQueue consumer.

    nonisolated(unsafe) private weak var state: BeatState?
    nonisolated(unsafe) private let now: () -> Double

    // Finestra scorrevole di energia RMS: pre-allocata a energyWindowMaxSize,
    // la dimensione effettiva usata per le statistiche è adattiva (effectiveWindowSize).
    nonisolated(unsafe) private var energyWindow: [Float]
    nonisolated(unsafe) private var energyWindowHead: Int = 0
    nonisolated(unsafe) private var energyWindowCount: Int = 0

    // Ultimo IOI valido (secondi) — usato per calcolare la dimensione adattiva della finestra.
    // Sostituisce lastValidBPM: l'IOI è l'intervallo grezzo tra due onset consecutivi validi,
    // senza la conversione in BPM (che spetta a RhythmAnalyzer).
    nonisolated(unsafe) private var lastValidIOI: Double = 0

    // Ultimi N IOI validi (secondi) — rolling window per l'outlier rejection.
    nonisolated(unsafe) private var onsetIntervals: [Double] = []

    // Timing e energia degli onset.
    nonisolated(unsafe) private var lastOnsetTime: Double = 0
    nonisolated(unsafe) private var lastOnsetRms: Float = 0

    // Confidenza ritmica [0.0–1.0]: sale con ogni beat valido, scende su outlier o pausa.
    // Governa la dimensione adattiva della finestra energia.
    nonisolated(unsafe) private var rhythmConfidence: Double = 0

    // Modalità corrente — sincronizzata da TempoApp via setMode(_:).
    nonisolated(unsafe) private var currentMode: DetectionMode = .solo

    // Live mode — flux window (nessun filtro aggiuntivo: usa lo stesso RMS di Solo).
    nonisolated(unsafe) private var prevRMS: Float = 0
    nonisolated(unsafe) private var fluxWindow: [Float]
    nonisolated(unsafe) private var fluxWindowHead: Int = 0
    nonisolated(unsafe) private var fluxWindowCount: Int = 0

    // Filtro LP kick (< 100 Hz): usato in produzione per filtrare i falsi onset.
    nonisolated(unsafe) private var kickLPSetup: vDSP_biquad_Setup?
    nonisolated(unsafe) private var kickLPDelay: [Float] = [0, 0, 0, 0]
    nonisolated(unsafe) private var kickWorkBuffer: [Float] = [Float](repeating: 0, count: 4096)

    // MARK: Init

    /// - Parameters:
    ///   - state: Stato condiviso aggiornato su @MainActor.
    ///   - now: Provider di timestamp iniettabile (default: CFAbsoluteTimeGetCurrent).
    ///     Nei test sostituire con un clock controllato.
    init(state: BeatState, now: @escaping () -> Double = CFAbsoluteTimeGetCurrent) {
        self.state   = state
        self.now     = now
        energyWindow = [Float](repeating: 0, count: BeatDetector.energyWindowMaxSize)
        fluxWindow   = [Float](repeating: 0, count: BeatDetector.energyWindowMaxSize)
    }

    deinit {
        if let lp = kickLPSetup { vDSP_biquad_DestroySetup(lp) }
    }

    // MARK: Testability

    /// Espone la soglia adattiva corrente (media + σ × onsetSigma) per i test.
    nonisolated var currentThreshold: Float {
        let (mean, std) = computeStats(window: energyWindow, head: energyWindowHead,
                                       count: energyWindowCount, limit: effectiveWindowSize)
        return mean + std * BeatDetector.onsetSigma
    }

    /// Espone la confidenza ritmica corrente [0.0–1.0] per i test.
    nonisolated var currentRhythmConfidence: Double { rhythmConfidence }

    /// Espone la dimensione effettiva della finestra energia per i test.
    nonisolated var currentEffectiveWindowSize: Int { effectiveWindowSize }

    // MARK: Public interface

    /// Cambia modalità di rilevamento e azzera lo stato Live-specifico.
    nonisolated func setMode(_ mode: DetectionMode) {
        currentMode     = mode
        prevRMS         = 0
        fluxWindow      = [Float](repeating: 0, count: BeatDetector.energyWindowMaxSize)
        fluxWindowHead  = 0
        fluxWindowCount = 0
    }

    /// Processa un buffer PCM pre-filtrato (HP@30 Hz + LP@250 Hz).
    ///
    /// Chiamato sincrono dalla DSP queue di AudioEngine (borrow semantics):
    /// non trattenere `buffer` oltre il ritorno.
    nonisolated func process(buffer: AVAudioPCMBuffer) {
        switch currentMode {
        case .solo: processSolo(buffer: buffer)
        case .live: processLive(buffer: buffer)
        }
    }

    // MARK: Solo mode — onset detection su energia RMS full-spectrum

    nonisolated private func processSolo(buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let n = vDSP_Length(buffer.frameLength)
        guard n > 0 else { return }

        var rms: Float = 0
        vDSP_rmsqv(ch[0], 1, &rms, n)

        energyWindow[energyWindowHead] = rms
        energyWindowHead = (energyWindowHead + 1) % BeatDetector.energyWindowMaxSize
        if energyWindowCount < BeatDetector.energyWindowMaxSize { energyWindowCount += 1 }

        guard rms > BeatDetector.minimumOnsetRms else { return }
        guard energyWindowCount >= 3 else { return }

        let (mean, std) = computeStats(window: energyWindow, head: energyWindowHead,
                                       count: energyWindowCount, limit: effectiveWindowSize)
        let threshold = mean + std * BeatDetector.onsetSigma
        guard rms > threshold, threshold > 0.001 else { return }

        let t = now()
        let elapsed = t - lastOnsetTime
        guard elapsed >= BeatDetector.refractorySeconds else { return }

        if elapsed < BeatDetector.holddownSeconds,
           lastOnsetRms > 0,
           rms < lastOnsetRms * BeatDetector.resonanceHolddownRatio {
            #if DEBUG
            bdLog.debug("⛔ holddown   rms=\(rms, format: .fixed(precision: 4))  lastRms=\(self.lastOnsetRms, format: .fixed(precision: 4))  elapsed=\(elapsed, format: .fixed(precision: 3))s")
            #endif
            return
        }

        // Kick filter: scarta onset con rapporto sub-bass/full-band insufficiente.
        // Tom medi e rullanti forti hanno kickRatio < 0.35 — non sono grancasse.
        let kickRMS   = kickBandRMS(samples: ch[0], count: Int(n), sampleRate: buffer.format.sampleRate)
        let kickRatio = rms > 0 ? kickRMS / rms : 0
        guard kickRatio >= BeatDetector.kickRatioThreshold else {
            #if DEBUG
            bdLog.debug("🪘 snare/tom  rms=\(rms, format: .fixed(precision: 4))  kickRatio=\(kickRatio, format: .fixed(precision: 2))  elapsed=\(elapsed, format: .fixed(precision: 3))s — scartato")
            #endif
            return
        }

        lastOnsetRms = rms
        #if DEBUG
        bdLog.debug("🥁 kick  rms=\(rms, format: .fixed(precision: 4))  kickRatio=\(kickRatio, format: .fixed(precision: 2))  elapsed=\(elapsed, format: .fixed(precision: 3))s")
        #endif
        registerOnset(at: t, rms: rms)
    }

    // MARK: Live mode — energy flux su segnale 30–250 Hz (già filtrato da AudioEngine)

    nonisolated private func processLive(buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let n = vDSP_Length(buffer.frameLength)
        guard n > 0 else { return }

        var rms: Float = 0
        vDSP_rmsqv(ch[0], 1, &rms, n)

        // Derivata positiva dell'energia: rileva le salite brusche (transienti).
        // Robusto a noise floor alto (palco, monitor) perché non dipende dal livello assoluto
        // ma dal cambio. Il kick near-field produce un flux netto anche in un mix rumoroso.
        let flux = max(0, rms - prevRMS)
        prevRMS = rms

        fluxWindow[fluxWindowHead] = flux
        fluxWindowHead = (fluxWindowHead + 1) % BeatDetector.energyWindowMaxSize
        if fluxWindowCount < BeatDetector.energyWindowMaxSize { fluxWindowCount += 1 }

        // Gate energetico separato da SOLO: 0.060 vs 0.040.
        // In LIVE il noise floor del palco (monitor, ampli basso, vibrazioni) raggiunge
        // RMS 0.020–0.050. Usare la stessa soglia di SOLO lascerebbe passare questo rumore
        // continuo al flux detector. Il kick near-field produce RMS ≥ 0.080 → il margine
        // è adeguato. Le note gravi del basso a ~3 m rimangono tipicamente sotto 0.060.
        guard rms > BeatDetector.liveMinimumOnsetRms else { return }
        guard fluxWindowCount >= 3 else { return }

        let (fluxMean, fluxStd) = computeStats(window: fluxWindow, head: fluxWindowHead,
                                                count: fluxWindowCount, limit: effectiveWindowSize)
        let fluxThreshold = fluxMean + fluxStd * BeatDetector.liveFluxSigma
        guard flux > fluxThreshold, fluxThreshold > 0 else { return }

        // Kick filter attenuato in LIVE: soglia più bassa rispetto a SOLO (0.20 vs 0.35)
        // perché il flux gate riduce già i falsi positivi da segnali continui.
        // Blocca snare/cymbal bleed dai monitor (kickRatio ≈ 0.05–0.15) e vibrazioni palco
        // broadband (kickRatio ≈ 0.10–0.20). Il kick near-field (kickRatio ≈ 0.35–0.60) passa
        // sempre. Nota gravi del basso a ~3 m (kickRatio ≈ 0.30–0.45) parzialmente filtrate
        // dal minimumOnsetRms (SPL ~9.5 dB inferiore al kick) e dall'outlier rejection.
        let liveKickRatio = kickBandRMS(samples: ch[0], count: Int(n), sampleRate: buffer.format.sampleRate) / (rms > 0 ? rms : 1)
        guard liveKickRatio >= BeatDetector.liveKickRatioThreshold else {
            #if DEBUG
            bdLog.debug("🎵 live snare/bleed  rms=\(rms, format: .fixed(precision: 4))  kickRatio=\(liveKickRatio, format: .fixed(precision: 2)) — scartato")
            #endif
            return
        }

        let t = now()
        let elapsed = t - lastOnsetTime
        guard elapsed >= BeatDetector.refractorySeconds else { return }

        if elapsed < BeatDetector.holddownSeconds,
           lastOnsetRms > 0,
           rms < lastOnsetRms * BeatDetector.resonanceHolddownRatio {
            return
        }

        lastOnsetRms = rms
        #if DEBUG
        bdLog.debug("🎵 live flux=\(flux, format: .fixed(precision: 4))  rms=\(rms, format: .fixed(precision: 4))  thr=\(fluxThreshold, format: .fixed(precision: 4))  kickRatio=\(liveKickRatio, format: .fixed(precision: 2))  elapsed=\(elapsed, format: .fixed(precision: 3))s")
        #endif
        registerOnset(at: t, rms: rms)
    }

    /// Azzera lo stato interno e pubblica il reset su BeatState.
    ///
    /// Chiamare solo dopo `AudioEngine.stop()`.
    nonisolated func reset() {
        energyWindow = [Float](repeating: 0, count: BeatDetector.energyWindowMaxSize)
        energyWindowHead  = 0
        energyWindowCount = 0
        lastValidIOI      = 0
        rhythmConfidence  = 0
        onsetIntervals.removeAll()
        lastOnsetTime = 0
        lastOnsetRms  = 0
        prevRMS         = 0
        fluxWindow      = [Float](repeating: 0, count: BeatDetector.energyWindowMaxSize)
        fluxWindowHead  = 0
        fluxWindowCount = 0
        kickLPDelay = [0, 0, 0, 0]
        Task { @MainActor [weak state] in
            guard let state else { return }
            state.beatFlash    = false
            state.beatPosition = 0
        }
    }

    // MARK: Private — onset logic

    nonisolated private func registerOnset(at time: Double, rms: Float) {
        // Gap > maxIntervalSeconds: pausa ritmica, azzera rolling window e confidenza.
        if lastOnsetTime > 0 && time - lastOnsetTime > BeatDetector.maxIntervalSeconds {
            onsetIntervals.removeAll()
            rhythmConfidence = 0
        }

        defer { lastOnsetTime = time }

        // Primo onset: registra solo il timestamp, poi notifica senza IOI.
        guard lastOnsetTime > 0 else {
            let ts = CACurrentMediaTime()
            onOnset?(ts, rms)
            #if DEBUG
            bdLog.debug("🥁 onset[1st]  rms=\(rms, format: .fixed(precision: 4))  ts=\(ts, format: .fixed(precision: 3))")
            #endif
            return
        }

        let interval = time - lastOnsetTime

        // Step A — Valida range IOI (350 ms–2400 ms → 25–171 BPM equivalenti).
        guard interval >= BeatDetector.refractorySeconds,
              interval <= BeatDetector.maxIntervalSeconds else { return }

        // Step B — Outlier rejection: ±13 % dalla mediana degli ultimi N IOI.
        if !onsetIntervals.isEmpty {
            let med = median(onsetIntervals)
            guard abs(interval - med) / med <= BeatDetector.outlierThreshold else {
                // Outlier: abbassa la confidenza — il sistema diventa più plastico
                // per aggiornarsi rapidamente al nuovo tempo dopo un fill.
                rhythmConfidence = max(0, rhythmConfidence - 0.3)
                #if DEBUG
                bdLog.debug("⛔ outlier  interval=\(interval, format: .fixed(precision: 3))s  median=\(med, format: .fixed(precision: 3))s")
                #endif
                return
            }
        }

        // Step C — Aggiorna rolling window IOI (max bpmWindowSize elementi).
        onsetIntervals.append(interval)
        if onsetIntervals.count > BeatDetector.bpmWindowSize {
            onsetIntervals.removeFirst()
        }

        // Aggiorna l'IOI valido più recente per la dimensione adattiva della finestra.
        lastValidIOI = interval

        // Beat valido: aumenta la confidenza ritmica.
        rhythmConfidence = min(1.0, rhythmConfidence + 0.12)

        let ts = CACurrentMediaTime()
        #if DEBUG
        bdLog.debug("🥁 onset  rms=\(rms, format: .fixed(precision: 4))  ioi=\(interval, format: .fixed(precision: 3))s  window=\(self.onsetIntervals.count)  eWin=\(self.effectiveWindowSize)  ts=\(ts, format: .fixed(precision: 3))")
        #endif

        // Notifica il consumer (tipicamente RhythmAnalyzer) con timestamp e RMS.
        onOnset?(ts, rms)

        // Aggiorna beatPosition e beatFlash su @MainActor.
        publishOnsetToState(rms: rms)
    }

    // MARK: Private — DSP helpers

    /// Dimensione effettiva della finestra energia: copre 4 beat stimati.
    /// Senza un IOI noto usa il massimo (finestra larga per calibrazione).
    /// Con IOI noto: più lenta a BPM bassi (finestra più larga), più reattiva ad alti BPM.
    /// L'IOI (inter-onset interval, secondi) viene usato direttamente senza conversione
    /// in BPM, perché BeatDetector non calcola più il BPM.
    nonisolated private var effectiveWindowSize: Int {
        guard lastValidIOI > 0 else { return BeatDetector.energyWindowMaxSize }
        // buffers per beat = (sampleRate / frameSize) × IOI
        let buffersPerBeat = (44100.0 / 2048.0) * lastValidIOI
        let target = Int((buffersPerBeat * 4.0).rounded())
        return min(BeatDetector.energyWindowMaxSize, max(BeatDetector.energyWindowSize, target))
    }

    /// Calcola media e std dei più recenti `limit` campioni nel circular buffer.
    /// Cammina indietro da `head` per leggere i valori più recenti indipendentemente
    /// da come il buffer ha ruotato.
    nonisolated private func computeStats(window: [Float], head: Int, count: Int, limit: Int) -> (mean: Float, std: Float) {
        let n = min(count, limit)
        guard n > 0 else { return (0, 0) }
        let size = window.count
        var sum: Float = 0
        var sumSq: Float = 0
        for i in 0..<n {
            let idx = (head - 1 - i + size) % size
            let v = window[idx]
            sum   += v
            sumSq += v * v
        }
        let fN       = Float(n)
        let mean     = sum / fN
        let variance = max(0, sumSq / fN - mean * mean)
        return (mean, variance.squareRoot())
    }

    /// Mediana di un array non ordinato (copia-e-ordina; array piccolo, max 4 elementi).
    nonisolated private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 0
            ? (sorted[n / 2 - 1] + sorted[n / 2]) / 2
            : sorted[n / 2]
    }

    // MARK: Private — kick classification

    /// Applica un biquad LP a kickCutoffHz e restituisce l'RMS dei campioni filtrati.
    /// Usato in produzione per filtrare onset non-kick (tom, rullante) in modalità Solo.
    nonisolated private func kickBandRMS(samples: UnsafePointer<Float>,
                                          count: Int,
                                          sampleRate: Double) -> Float {
        if kickLPSetup == nil {
            let fc    = BeatDetector.kickCutoffHz
            let q     = 1.0 / 2.0.squareRoot()
            let w0    = 2.0 * .pi * fc / sampleRate
            let cosW  = cos(w0)
            let alpha = sin(w0) / (2.0 * q)
            let a0    = 1.0 + alpha
            let coeffs: [Double] = [
                (1.0 - cosW) / 2.0 / a0,
                (1.0 - cosW)       / a0,
                (1.0 - cosW) / 2.0 / a0,
                -2.0 * cosW        / a0,
                (1.0 - alpha)      / a0
            ]
            kickLPSetup = vDSP_biquad_CreateSetup(coeffs, 1)
        }
        guard let lp = kickLPSetup, count <= kickWorkBuffer.count else { return 0 }
        kickWorkBuffer.withUnsafeMutableBufferPointer { buf in
            guard let p = buf.baseAddress else { return }
            vDSP_biquad(lp, &kickLPDelay, samples, 1, p, 1, vDSP_Length(count))
        }
        var rms: Float = 0
        kickWorkBuffer.withUnsafeBufferPointer { buf in
            guard let p = buf.baseAddress else { return }
            vDSP_rmsqv(p, 1, &rms, vDSP_Length(count))
        }
        return rms
    }

    // MARK: Private — publish

    /// Aggiorna `beatPosition` e `beatFlash` su @MainActor ad ogni onset valido.
    /// La scrittura di BPM e statistiche di sessione è stata delegata a RhythmAnalyzer
    /// (TBD-68), che riceve gli onset tramite `onOnset`.
    nonisolated private func publishOnsetToState(rms: Float) {
        Task { @MainActor [weak state] in
            guard let state else { return }
            state.beatPosition = (state.beatPosition + 1) % 4
            state.beatFlash    = true
            try? await Task.sleep(for: .milliseconds(100))
            state.beatFlash    = false
        }
    }
}
