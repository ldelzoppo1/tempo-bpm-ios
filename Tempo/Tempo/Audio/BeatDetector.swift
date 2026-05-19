import AVFoundation
import Accelerate
import os.log

#if DEBUG
private let bdLog = Logger(subsystem: "com.ldelzoppo.tempo", category: "BeatDetector")
#endif

// MARK: - BeatDetector

/// Rileva i beat da un buffer PCM pre-filtrato (banda 30–250 Hz) e pubblica il BPM
/// su BeatState via @MainActor.
///
/// ## Algoritmo
///
/// **Onset detection**
/// 1. RMS corrente del buffer PCM.
/// 2. Soglia dinamica = media + deviazione standard dell'energia in finestra
///    scorrevole adattiva (4 beat stimati, tra 22 e 64 buffer a 44100/2048 Hz).
/// 3. Onset se `rms > soglia`.
/// 4. Refrattario: minimo 300 ms tra onset (max 200 BPM).
/// 5. Holddown anti-risonanza: entro 450 ms dall'ultimo onset, il nuovo onset
///    viene accettato solo se la sua energia ≥ 35 % di quella precedente.
///    Previene la doppia rilevazione della coda di decadimento della cassa.
/// 6. Intervallo massimo: 2000 ms — intervalli più lunghi indicano pausa.
/// 7. Outlier rejection: nuovo intervallo scartato se devia > ±13 % dalla
///    mediana degli ultimi 4 intervalli validi.
///
/// **Calcolo BPM**
/// - Media degli ultimi 4 intervalli validi → BPM con 1 decimale.
/// - Aggiornamento ad ogni beat, non su timer.
/// - `recentBPMs`: 4 BPM individuali per le pills UI.
/// - Reset automatico a 0 dopo 3 s senza beat rilevati.
///
/// ## Threading
/// `process(buffer:)` è chiamato sincrono dalla DSP queue di AudioEngine.
/// Tutte le scritture su BeatState avvengono via `Task { @MainActor in … }`.
final class BeatDetector: @unchecked Sendable {

    // MARK: DSP constants

    /// Dimensione minima della finestra energia (usata a BPM alti, ~220 BPM → ~1 s).
    private nonisolated static var energyWindowSize: Int { 22 }

    /// Dimensione massima della finestra energia (usata a BPM bassi o senza stima → ~3 s).
    /// Pre-allocata all'init: nessuna alloc nel loop hot.
    private nonisolated static var energyWindowMaxSize: Int { 64 }

    /// Onset se rms > media + std × onsetSigma.
    private nonisolated static var onsetSigma: Float { 1.0 }

    /// Periodo refrattario minimo tra due onset (400 ms → max 150 BPM).
    /// 400 ms previene il lock su coppie di hit ravvicinate (es. kick + colpo sincopato
    /// a ~395 ms) che falserebbero il BPM rilevato.
    private nonisolated static var refractorySeconds: Double { 0.400 }

    /// Finestra holddown anti-risonanza: dopo un onset, un nuovo onset viene
    /// accettato entro questa finestra solo se la sua energia ≥
    /// resonanceHolddownRatio × energia dell'ultimo onset.
    private nonisolated static var holddownSeconds: Double { 0.450 }

    /// Frazione minima di energia rispetto all'ultimo onset per onset nella
    /// holddown window. Le risonanze della cassa sono tipicamente ≤ 15%;
    /// 0.20 blocca le risonanze lasciando passare rullanti (tipicamente 25-60%
    /// del kick anche da speaker del telefono).
    private nonisolated static var resonanceHolddownRatio: Float { 0.20 }

    /// Intervallo massimo valido tra onset (2000 ms → min 30 BPM).
    private nonisolated static var maxIntervalSeconds: Double { 2.000 }

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
    /// Il mic iPhone filtra già i sub-bass sotto ~120 Hz: non occorre un LP aggiuntivo.
    /// Usiamo il segnale 30–250 Hz già pre-filtrato da AudioEngine e rileviamo le salite
    /// di energia (transients) invece dei livelli assoluti — robusto a mix compressi.
    private nonisolated static var liveFluxSigma: Float { 1.5 }

    // MARK: Kick classification constants

    /// Cutoff LP per separare banda cassa (< 100 Hz) dal rullante (100–250 Hz).
    private nonisolated static var kickCutoffHz: Double { 100.0 }

    /// kickRatio minimo per accettare un onset come grancassa in modalità Solo.
    /// Alzato a 0.35 rispetto al precedente 0.28 per ridurre i falsi positivi
    /// da tom medio e colpi forti sul rullante che ricadono in banda 40–250 Hz.
    private nonisolated static var kickRatioThreshold: Float { 0.35 }

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

    // Ultimo BPM valido — usato per calcolare la dimensione adattiva della finestra.
    nonisolated(unsafe) private var lastValidBPM: Double = 0

    // Ultimi N intervalli validi (secondi) — rolling window per BPM.
    nonisolated(unsafe) private var onsetIntervals: [Double] = []

    // Tutti i BPM validi della sessione (capped) — per min/max/avg.
    nonisolated(unsafe) private var sessionBPMs: [Double] = []
    private nonisolated static var sessionBPMCap: Int { 2000 }

    // Timing e energia degli onset.
    nonisolated(unsafe) private var lastOnsetTime: Double = 0
    nonisolated(unsafe) private var lastOnsetRms: Float = 0

    // Confidenza ritmica [0.0–1.0]: sale con ogni beat valido, scende su outlier o pausa.
    // Governa l'α dell'EMA: bassa confidenza → α più alto (adattamento rapido dopo fill);
    // alta confidenza → α più basso (stabilità su ritmo regolare).
    nonisolated(unsafe) private var rhythmConfidence: Double = 0

    // Task che azzera il BPM dopo 3 s di silenzio; cancellato ad ogni nuovo beat.
    nonisolated(unsafe) private var beatResetTask: Task<Void, Never>?

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
        registerOnset(at: t)
    }

    // MARK: Live mode — energy flux su segnale 30–250 Hz (già filtrato da AudioEngine)

    nonisolated private func processLive(buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let n = vDSP_Length(buffer.frameLength)
        guard n > 0 else { return }

        var rms: Float = 0
        vDSP_rmsqv(ch[0], 1, &rms, n)

        // Derivata positiva dell'energia: rileva le salite brusche (transienti).
        // Robusto a mix compressi perché non dipende dal livello assoluto ma dal cambio.
        // Il mic iPhone agisce già come HP naturale sotto ~120 Hz: nessun LP aggiuntivo serve.
        let flux = max(0, rms - prevRMS)
        prevRMS = rms

        fluxWindow[fluxWindowHead] = flux
        fluxWindowHead = (fluxWindowHead + 1) % BeatDetector.energyWindowMaxSize
        if fluxWindowCount < BeatDetector.energyWindowMaxSize { fluxWindowCount += 1 }

        guard rms > BeatDetector.minimumOnsetRms else { return }
        guard fluxWindowCount >= 3 else { return }

        let (fluxMean, fluxStd) = computeStats(window: fluxWindow, head: fluxWindowHead,
                                                count: fluxWindowCount, limit: effectiveWindowSize)
        let fluxThreshold = fluxMean + fluxStd * BeatDetector.liveFluxSigma
        guard flux > fluxThreshold, fluxThreshold > 0 else { return }

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
        bdLog.debug("🎵 live flux=\(flux, format: .fixed(precision: 4))  rms=\(rms, format: .fixed(precision: 4))  thr=\(fluxThreshold, format: .fixed(precision: 4))  elapsed=\(elapsed, format: .fixed(precision: 3))s")
        #endif
        registerOnset(at: t)
    }

    /// Azzera lo stato interno e pubblica il reset su BeatState.
    ///
    /// Chiamare solo dopo `AudioEngine.stop()`.
    nonisolated func reset() {
        energyWindow = [Float](repeating: 0, count: BeatDetector.energyWindowMaxSize)
        energyWindowHead  = 0
        energyWindowCount = 0
        lastValidBPM      = 0
        rhythmConfidence  = 0
        onsetIntervals.removeAll()
        sessionBPMs.removeAll()
        lastOnsetTime = 0
        lastOnsetRms  = 0
        beatResetTask?.cancel()
        beatResetTask = nil
        prevRMS         = 0
        fluxWindow      = [Float](repeating: 0, count: BeatDetector.energyWindowMaxSize)
        fluxWindowHead  = 0
        fluxWindowCount = 0
        kickLPDelay = [0, 0, 0, 0]
        Task { @MainActor [weak state] in
            guard let state else { return }
            state.currentBPM = 0
            state.recentBPMs = []
            state.minBPM     = 0
            state.maxBPM     = 0
            state.avgBPM     = 0
            state.stability  = 0
            state.beatFlash  = false
        }
    }

    // MARK: Private — onset logic

    nonisolated private func registerOnset(at time: Double) {
        // Gap > 2 s: pausa ritmica, azzera rolling window e azzera la confidenza.
        if lastOnsetTime > 0 && time - lastOnsetTime > 2.0 {
            onsetIntervals.removeAll()
            rhythmConfidence = 0
        }

        defer { lastOnsetTime = time }

        // Primo onset: registra solo il timestamp.
        guard lastOnsetTime > 0 else { return }

        let interval = time - lastOnsetTime

        // Step A — Valida range BPM (30–200 BPM → 300 ms–2000 ms).
        guard interval >= BeatDetector.refractorySeconds,
              interval <= BeatDetector.maxIntervalSeconds else { return }

        // Step B — Outlier rejection: ±13 % dalla mediana degli ultimi N intervalli.
        if !onsetIntervals.isEmpty {
            let med = median(onsetIntervals)
            guard abs(interval - med) / med <= BeatDetector.outlierThreshold else {
                // Outlier: abbassa la confidenza — il sistema diventa più plastico
                // per aggiornarsi rapidamente al nuovo tempo dopo un fill.
                rhythmConfidence = max(0, rhythmConfidence - 0.3)
                return
            }
        }

        // Step C — Aggiorna rolling window (max 4 intervalli).
        onsetIntervals.append(interval)
        if onsetIntervals.count > BeatDetector.bpmWindowSize {
            onsetIntervals.removeFirst()
        }

        // Serve almeno 2 intervalli per BPM affidabile.
        guard onsetIntervals.count >= 2 else { return }

        // Step D — BPM = 60 / media intervalli, arrotondato a 1 decimale.
        let meanInterval = onsetIntervals.reduce(0, +) / Double(onsetIntervals.count)
        let rawBPM = rounded1(60.0 / meanInterval)

        // Octave correction: kick su battiti alterni (1 e 3) produce intervalli doppi
        // → BPM dimezzato. Soglia 80 copre kick-rado su brani 80–160 BPM
        // (intervallo kick 0.75–1.5 s → raw 40–80 BPM → corretto a 80–160 BPM).
        let octaveFactor: Double = rawBPM < 80 ? 2.0 : 1.0
        let bpm = rounded1(rawBPM * octaveFactor)

        // Aggiorna la stima BPM per il calcolo adattivo della finestra energia.
        lastValidBPM = bpm

        // Beat valido: aumenta la confidenza ritmica.
        rhythmConfidence = min(1.0, rhythmConfidence + 0.12)

        // BPM individuali per le pills UI (stesso fattore di correzione).
        let recentBPMs = onsetIntervals.map { rounded1(60.0 / $0 * octaveFactor) }

        sessionBPMs.append(bpm)
        if sessionBPMs.count > BeatDetector.sessionBPMCap { sessionBPMs.removeFirst() }

        #if DEBUG
        bdLog.debug("🥁 bpm=\(bpm, format: .fixed(precision: 1))  interval=\(interval, format: .fixed(precision: 3))s  window=\(self.onsetIntervals.count)  eWin=\(self.effectiveWindowSize)")
        #endif
        publishBeatState(currentBPM: bpm, recentBPMs: recentBPMs, confidence: rhythmConfidence)
    }

    // MARK: Private — DSP helpers

    /// Dimensione effettiva della finestra energia: copre 4 beat stimati.
    /// Senza stima BPM usa il massimo (finestra larga per calibrazione).
    /// Con BPM noto: più lenta a BPM bassi (finestra più larga), più reattiva ad alti BPM.
    nonisolated private var effectiveWindowSize: Int {
        guard lastValidBPM > 0 else { return BeatDetector.energyWindowMaxSize }
        // buffers per beat = (sampleRate / frameSize) / (BPM / 60)
        let buffersPerBeat = (44100.0 / 2048.0) * (60.0 / lastValidBPM)
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

    /// Calcola la stabilità del ritmo come 1 − CV × 5 (clampato in [0, 1]).
    nonisolated private func computeStability() -> Double {
        guard onsetIntervals.count >= 2 else { return 0 }
        let n    = Double(onsetIntervals.count)
        let mean = onsetIntervals.reduce(0, +) / n
        let variance = onsetIntervals.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / n
        let cv = variance.squareRoot() / mean
        return max(0.0, min(1.0, 1.0 - cv * 5.0))
    }

    /// Arrotonda a 1 decimale.
    nonisolated private func rounded1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
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

    nonisolated private func publishBeatState(currentBPM: Double, recentBPMs: [Double], confidence: Double) {
        let minBPM = sessionBPMs.min() ?? 0
        let maxBPM = sessionBPMs.max() ?? 0
        let avgBPM = sessionBPMs.isEmpty
            ? 0
            : rounded1(sessionBPMs.reduce(0, +) / Double(sessionBPMs.count))
        let stability = computeStability()

        // Cancella il timer precedente e riavvia il countdown di 3 s.
        beatResetTask?.cancel()
        beatResetTask = Task { @MainActor [weak state] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            state?.currentBPM = 0
            state?.recentBPMs = []
            state?.stability  = 0
        }

        Task { @MainActor [weak state] in
            guard let state, !state.tapOverrideActive else { return }
            // EMA con α adattivo basato sulla confidenza ritmica:
            //   α = 0.85 a confidenza 0 (post-fill, bassa) → aggiornamento rapido al nuovo tempo
            //   α = 0.60 a confidenza 1 (ritmo stabile) → smorzamento dei picchi transitori
            // Questo previene il freeze su numeri tondi (es. 120.0): dopo un fill la confidenza
            // scende, α sale, e il sistema si aggiorna rapidamente al BPM reale.
            let alpha = 0.85 - 0.25 * confidence
            let prev = state.currentBPM
            state.currentBPM = prev > 0 ? rounded1(alpha * currentBPM + (1 - alpha) * prev) : currentBPM
            state.recentBPMs = recentBPMs
            state.minBPM     = minBPM
            state.maxBPM     = maxBPM
            state.avgBPM     = avgBPM
            state.stability  = stability
            state.beatFlash  = true
            try? await Task.sleep(for: .milliseconds(100))
            state.beatFlash  = false
        }
    }
}
