import AVFoundation
import Accelerate
import CoreFoundation

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

    // MARK: - Init

    init(state: BeatState) {
        self.state = state
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

        // TBD-42 — Silence detection: se non c'è nessun onset da > 2s, pubblica stability=0.
        // Non viene resettato lo stato — il reset avviene solo su chiamata esplicita a reset().
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastOnsetTime > 2.0 && lastOnsetTime > 0 {
            Task { @MainActor [weak state] in
                state?.stability = 0
            }
        }

        // TBD-37 Step 3: Guard warm-up — attendi che la soglia sia significativa.
        guard adaptiveThreshold > 0.001 else { return }

        // TBD-37 Step 4: Onset detection — energia deve superare soglia × moltiplicatore.
        guard rms > adaptiveThreshold * BeatDetector.onsetMultiplier else { return }

        // TBD-37 Step 5–6: Guard refrattario — previene doppi onset ravvicinati.
        guard now - lastOnsetTime >= refractoryPeriod else { return }

        // TBD-37 Step 7: Onset rilevato — registra.
        registerOnset(at: now)
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
        Task { @MainActor [weak state] in
            guard let state else { return }
            state.currentBPM = 0
            state.recentBPMs = []
            state.minBPM = 0
            state.maxBPM = 0
            state.avgBPM = 0
            state.stability = 0
            state.beatFlash = false
        }
    }

    // MARK: - Private

    /// Registra un onset al timestamp fornito e aggiorna la stima BPM.
    ///
    /// TBD-38: calcola l'inter-onset interval, lo valida nel range 40–220 BPM,
    /// mantiene la rolling window degli ultimi bpmWindowSize intervals.
    private func registerOnset(at time: Double) {
        if lastOnsetTime > 0 {
            let interval = time - lastOnsetTime
            let bpm = 60.0 / interval

            if bpm >= BeatDetector.bpmMin && bpm <= BeatDetector.bpmMax {
                // Aggiorna rolling window intervals (ultimi bpmWindowSize).
                onsetIntervals.append(interval)
                if onsetIntervals.count > BeatDetector.bpmWindowSize {
                    onsetIntervals.removeFirst()
                }

                // Accumula tutti i BPM validi della sessione.
                allBPMs.append(bpm)

                // Calcola BPM corrente come media degli intervalli nella rolling window.
                let currentBPM = computeCurrentBPM()

                // TBD-39: Pubblica su BeatState sul @MainActor.
                publishBeatState(currentBPM: currentBPM)
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

    /// Pubblica i valori aggiornati su BeatState via @MainActor.
    ///
    /// Non aggiorna se tapOverrideActive è true (tap tempo ha priorità su currentBPM).
    /// Il beatFlash viene riportato a false dopo 100ms.
    private func publishBeatState(currentBPM: Double) {
        // Cattura copie dei valori calcolati sulla DSP queue prima del salto al MainActor.
        let bpmSnapshot = currentBPM
        let recentSnapshot = Array(allBPMs.suffix(20))
        let minBPM = allBPMs.min() ?? 0
        let maxBPM = allBPMs.max() ?? 0
        let avgBPM = allBPMs.isEmpty ? 0 : allBPMs.reduce(0, +) / Double(allBPMs.count)
        let stabilitySnapshot = computeStability()

        Task { @MainActor [weak state] in
            guard let state else { return }
            guard !state.tapOverrideActive else { return }
            state.currentBPM = bpmSnapshot
            state.recentBPMs = recentSnapshot
            state.minBPM = minBPM
            state.maxBPM = maxBPM
            state.avgBPM = avgBPM
            state.stability = stabilitySnapshot
            state.beatFlash = true
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            state.beatFlash = false
        }
    }
}
