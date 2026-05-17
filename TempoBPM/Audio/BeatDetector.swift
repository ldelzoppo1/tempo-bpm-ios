import AVFoundation
import Accelerate
import CoreFoundation

#if DEBUG
import OSLog
private let bdLogger = Logger(subsystem: "com.ldelzoppo.tempo", category: "BeatDetector")
#endif

// TBD-37: RMS Extraction e Onset Detection
// TBD-38: Soglia Adattiva EMA e Rolling Window BPM
// TBD-39: Pubblicazione BeatState via @MainActor
// TBD-42: Reset e Gestione Sessione / Silence Detection

/// Rileva i beat da un buffer PCM pre-filtrato (banda 20–200 Hz).
///
/// Il buffer è fornito dalla DSP queue di AudioEngine con borrow semantics:
/// `process(buffer:)` deve essere sincrono e non trattenere il buffer oltre il ritorno.
/// Non usare `DispatchQueue.async` interno — tutto il calcolo è sincrono sulla DSP queue chiamante.
final class BeatDetector {

    // MARK: - DSP Constants

    /// Moltiplicatore onset: energia RMS deve superare soglia × onsetMultiplier per rilevare un beat.
    static let onsetMultiplier: Float = 1.5

    /// Velocità di adattamento della soglia adattiva EMA: 0.1 = lento, 1.0 = immediato.
    static let adaptiveAlpha: Float = 0.1

    /// Numero di inter-onset intervals tenuti per il calcolo BPM (media mobile).
    static let bpmWindowSize: Int = 4

    /// BPM minimo valido — intervalli che producono BPM < 40 vengono scartati.
    static let bpmMin: Double = 40

    /// BPM massimo valido — intervalli che producono BPM > 220 vengono scartati.
    static let bpmMax: Double = 220

    /// Periodo refrattario minimo in secondi tra due onset consecutivi (anti-bounce).
    static let refractoryMs: Double = 200

    /// Finestra IOI per il freeze BPM — più ampia di bpmWindowSize per catturare fill.
    static let ioiWindowSize: Int = 8

    /// Soglia deviazione per TRACKING (coefficiente di variazione).
    static let ioiTrackingThreshold: Double = 0.10

    /// Soglia deviazione per LOST (congela BPM).
    static let ioiLostThreshold: Double = 0.20

    /// Soglia kickRatio minima: onset accettato solo se kickRatio > questa soglia.
    /// 0 = disabilitato finché non c'è storia sufficiente.
    static let kickRatioMinimum: Float = 0.35

    // MARK: - Private state

    /// BeatState condiviso — weak per evitare retain cycle.
    private weak var state: BeatState?

    /// Soglia adattiva corrente calcolata via EMA sull'energia RMS.
    private var adaptiveThreshold: Float = 0.0

    /// Timestamp dell'ultimo onset rilevato (CFAbsoluteTimeGetCurrent()).
    private var lastOnsetTime: Double = 0.0

    /// Periodo refrattario in secondi — conversione da refractoryMs.
    private let refractoryPeriod: Double = BeatDetector.refractoryMs / 1000.0

    /// Rolling window degli ultimi bpmWindowSize inter-onset intervals (secondi).
    private var onsetIntervals: [Double] = []

    /// Tutti i BPM validi rilevati nella sessione corrente.
    private var allBPMs: [Double] = []

    /// Rolling window degli ultimi ioiWindowSize inter-onset intervals per IOI locking.
    private var ioiHistory: [Double] = []

    /// BPM frozen quando lo stato è .lost — non sovrascrive BeatState.currentBPM.
    private var frozenBPM: Double = 0

    // MARK: - Private: time provider

    /// Restituisce il timestamp corrente in secondi assoluti.
    /// Iniettabile per i test (evita Thread.sleep nei test di timing).
    private let now: () -> Double

    /// Predice il timing del prossimo beat e valida gli onset nella finestra temporale.
    private var tempoPredictor: TempoPredictor?

    // MARK: - Init

    init(state: BeatState, now: @escaping () -> Double = CFAbsoluteTimeGetCurrent, tempoPredictor: TempoPredictor? = nil) {
        self.state = state
        self.now = now
        self.tempoPredictor = tempoPredictor
    }

    // MARK: - Testability

    /// Espone la soglia adattiva corrente per consentire asserzioni nei test.
    var currentThreshold: Float { adaptiveThreshold }

    // MARK: - Public interface

    /// Processa un buffer PCM pre-filtrato (banda 20–200 Hz) per rilevare beat.
    ///
    /// Chiamato sincrono dalla DSP queue di AudioEngine. Non alloca, non usa lock.
    /// Il buffer è a borrow semantics — non trattenere riferimenti oltre il ritorno.
    func process(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameLength = vDSP_Length(buffer.frameLength)
        guard frameLength > 0 else { return }

        // TBD-37 Step 1: Calcola energia RMS con vDSP_rmsqv.
        var rms: Float = 0
        vDSP_rmsqv(channelData[0], 1, &rms, frameLength)

        // TBD-37 / TBD-38 Step 2: Aggiorna soglia adattiva EMA.
        if adaptiveThreshold == 0 {
            adaptiveThreshold = rms
        } else {
            // EMA: soglia = (1 - alpha) * soglia + alpha * rms
            adaptiveThreshold = (1.0 - BeatDetector.adaptiveAlpha) * adaptiveThreshold
                              + BeatDetector.adaptiveAlpha * rms
        }

        // TBD-37 Step 3: Guard warm-up — attendi che la soglia sia significativa.
        guard adaptiveThreshold > 0.001 else { return }

        // TBD-37 Step 4: Onset detection — energia deve superare soglia × moltiplicatore.
        guard rms > adaptiveThreshold * BeatDetector.onsetMultiplier else { return }

        // TBD-37 Step 5–6: Guard refrattario — previene doppi onset ravvicinati.
        let currentTime = now()
        guard currentTime - lastOnsetTime >= refractoryPeriod else { return }

        // KickSignatureDetector: filtra onset non-kick (tom, rullante, ecc.)
        // Applica il filtro solo quando il ratio è stato inizializzato (> 0).
        // Disabilita il filtro durante il warmup (ioiHistory.count < 2) per non perdere i primi beat.
        if ioiHistory.count >= 2, let s = state {
            let ratio = s.kickRatio
            if ratio > 0 && ratio < BeatDetector.kickRatioMinimum {
                #if DEBUG
                bdLogger.debug("⛔ onset rejected — kickRatio \(ratio, format: .fixed(precision: 2)) < \(BeatDetector.kickRatioMinimum, format: .fixed(precision: 2))")
                #endif
                return
            }
        }

        // TBD-37 Step 7: Onset rilevato — registra.
        registerOnset(at: currentTime)
    }

    /// Azzera lo stato interno della sessione.
    ///
    /// Chiamare solo dopo `stopCapture()`, mai durante la riproduzione attiva.
    /// Pubblica il reset su BeatState via @MainActor.
    func reset() {
        adaptiveThreshold = 0
        lastOnsetTime = 0
        onsetIntervals = []
        allBPMs = []
        ioiHistory = []
        frozenBPM = 0
        tempoPredictor?.reset()
        Task { @MainActor [weak state] in
            guard let state else { return }
            state.currentBPM = 0
            state.recentBPMs = []
            state.minBPM = 0
            state.maxBPM = 0
            state.avgBPM = 0
            state.stability = 0
            state.beatFlash = false
            state.currentBeat = 0
            state.confidenceState = .lost
            state.ioiDeviation = 0
            state.frozenBPM = 0
            state.kickRatio = 0
            state.predictedNextBeatTime = 0
        }
    }

    // MARK: - Private

    /// Registra un onset al timestamp fornito e aggiorna la stima BPM.
    ///
    /// TBD-38: calcola l'inter-onset interval, lo valida nel range 40–220 BPM,
    /// mantiene la rolling window degli ultimi bpmWindowSize intervals.
    private func registerOnset(at time: Double) {
        // TBD-42 — Silence detection: se l'intervallo supera 2s, l'energia ritmica è
        // cambiata radicalmente. Reset della rolling window per evitare BPM errati.
        if lastOnsetTime > 0 && time - lastOnsetTime > 2.0 {
            onsetIntervals.removeAll()
            allBPMs.removeAll()
            Task { @MainActor [weak state] in state?.stability = 0 }
        }

        if lastOnsetTime > 0 {
            let interval = time - lastOnsetTime
            let bpm = 60.0 / interval

            if bpm >= BeatDetector.bpmMin && bpm <= BeatDetector.bpmMax {
                #if DEBUG
                bdLogger.debug("✅ onset t=\(time, format: .fixed(precision: 3)) interval=\(interval, format: .fixed(precision: 3))s bpm=\(bpm, format: .fixed(precision: 1))")
                #endif
                // Aggiorna rolling window intervals (ultimi bpmWindowSize).
                onsetIntervals.append(interval)
                if onsetIntervals.count > BeatDetector.bpmWindowSize {
                    onsetIntervals.removeFirst()
                }

                // Accumula tutti i BPM validi della sessione.
                allBPMs.append(bpm)

                // IOI locking: aggiorna rolling window a 8 intervalli
                ioiHistory.append(interval)
                if ioiHistory.count > BeatDetector.ioiWindowSize {
                    ioiHistory.removeFirst()
                }

                // Calcola coefficiente di variazione IOI
                let ioiCV = computeIOIDeviation()

                // Calcola BPM corrente come media degli intervalli nella rolling window.
                let currentBPM = computeCurrentBPM()

                // TBD-39: Pubblica su BeatState sul @MainActor.
                publishBeatState(currentBPM: currentBPM, ioiCV: ioiCV)

                // Aggiorna TempoPredictor con il nuovo onset
                let meanInterval = onsetIntervals.isEmpty ? interval :
                    onsetIntervals.reduce(0, +) / Double(onsetIntervals.count)
                tempoPredictor?.register(onsetTime: time, meanInterval: meanInterval)
            }
        }

        lastOnsetTime = time
    }

    /// Calcola il BPM corrente dalla media degli interval nella rolling window.
    ///
    /// Richiede almeno 2 intervals per produrre un valore significativo.
    /// Restituisce 0 se la finestra è insufficiente.
    private func computeCurrentBPM() -> Double {
        guard onsetIntervals.count >= 2 else { return 0 }
        let meanInterval = onsetIntervals.reduce(0, +) / Double(onsetIntervals.count)
        return 60.0 / meanInterval
    }

    /// Calcola la stabilità del ritmo come complemento del coefficiente di variazione.
    ///
    /// Stabilità 1.0 = ritmo perfettamente costante.
    /// Stabilità 0.0 = ritmo molto variabile o dati insufficienti.
    private func computeStability() -> Double {
        guard onsetIntervals.count >= 2 else { return 0 }

        let count = Double(onsetIntervals.count)
        let mean = onsetIntervals.reduce(0, +) / count

        // Deviazione standard dei intervals nella rolling window.
        let variance = onsetIntervals.reduce(0.0) { acc, interval in
            let diff = interval - mean
            return acc + diff * diff
        } / count
        let stdDev = variance.squareRoot()

        // Coefficient of variation normalizzato e scalato: 5× rende la metrica
        // abbastanza sensibile da discriminare ritmo stabile da instabile.
        return max(0.0, 1.0 - (stdDev / mean) * 5.0)
    }

    private func computeIOIDeviation() -> Double {
        guard ioiHistory.count >= 2 else { return 0 }
        let count = Double(ioiHistory.count)
        let mean = ioiHistory.reduce(0, +) / count
        guard mean > 0 else { return 0 }
        let variance = ioiHistory.reduce(0.0) { acc, x in
            let d = x - mean; return acc + d * d
        } / count
        return variance.squareRoot() / mean  // Coefficient of Variation
    }

    /// Pubblica i valori aggiornati su BeatState via @MainActor.
    ///
    /// Non aggiorna se tapOverrideActive è true (tap tempo ha priorità su currentBPM).
    /// Il beatFlash viene riportato a false dopo 100ms.
    private func publishBeatState(currentBPM: Double, ioiCV: Double) {
        // Cattura copie dei valori calcolati sulla DSP queue prima del salto al MainActor.
        let bpmSnapshot = currentBPM
        let recentSnapshot = Array(allBPMs.suffix(BeatDetector.bpmWindowSize))
        let minBPM = allBPMs.min() ?? 0
        let maxBPM = allBPMs.max() ?? 0
        let avgBPM = allBPMs.isEmpty ? 0 : allBPMs.reduce(0, +) / Double(allBPMs.count)
        let stabilitySnapshot = computeStability()

        Task { @MainActor [weak state] in
            guard let state else { return }
            guard !state.tapOverrideActive else { return }

            // IOI Locking: determina confidence state e congela BPM se necessario
            let newConfidence: ConfidenceState
            switch ioiCV {
            case ..<BeatDetector.ioiTrackingThreshold:
                newConfidence = .locked
            case ..<BeatDetector.ioiLostThreshold:
                newConfidence = .tracking
            default:
                newConfidence = .lost
            }
            state.confidenceState = newConfidence
            state.ioiDeviation = ioiCV
            #if DEBUG
            let stateSymbol: String
            switch newConfidence {
            case .locked:   stateSymbol = "🔒 LOCKED"
            case .tracking: stateSymbol = "🟡 TRACKING"
            case .lost:     stateSymbol = "🔴 LOST — frozen at \(String(format: "%.1f", state.frozenBPM)) BPM"
            }
            bdLogger.debug("\(stateSymbol) — ioiCV=\(ioiCV * 100, format: .fixed(precision: 1))%")
            #endif

            // Congela BPM se LOST (fill/tom burst): mantieni l'ultimo valore valido
            if newConfidence == .lost {
                // Mostra il BPM congelato ma non aggiornare currentBPM
                if state.frozenBPM > 0 {
                    // BPM già congelato: non fare nulla su currentBPM
                }
                // Non fare return: aggiorniamo comunque recentBPMs/stats per trasparenza
            } else {
                // LOCKED o TRACKING: aggiorna currentBPM e aggiorna frozenBPM
                state.currentBPM = bpmSnapshot
                state.frozenBPM = bpmSnapshot
            }

            state.recentBPMs = recentSnapshot
            state.minBPM = minBPM
            state.maxBPM = maxBPM
            state.avgBPM = avgBPM
            state.stability = stabilitySnapshot
            let sig = state.timeSignature.rawValue
            state.currentBeat = (state.currentBeat + 1) % sig
            state.beatFlash = true
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            state.beatFlash = false
        }
    }
}
