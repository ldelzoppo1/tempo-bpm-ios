import AVFoundation
import Accelerate

// MARK: - BeatDetector

/// Rileva i beat da un buffer PCM pre-filtrato (banda 30–250 Hz) e pubblica il BPM
/// su BeatState via @MainActor.
///
/// ## Algoritmo (TBD-10 / TBD-11)
///
/// **Onset detection (TBD-10)**
/// 1. RMS corrente del buffer PCM.
/// 2. Soglia dinamica = media + deviazione standard dell'energia in finestra
///    scorrevole di ~1 secondo (~22 buffer a 44100/2048 Hz).
/// 3. Onset se `rms > soglia`.
/// 4. Refrattario: minimo 300 ms tra onset (max 200 BPM).
/// 5. Intervallo massimo: 2000 ms — intervalli più lunghi indicano pausa.
/// 6. Outlier rejection: nuovo intervallo scartato se devia > ±40 % dalla
///    mediana degli ultimi 4 intervalli validi.
///
/// **Calcolo BPM (TBD-11)**
/// - Media degli ultimi 4 intervalli validi → BPM con 1 decimale.
/// - Aggiornamento ad ogni beat, non su timer.
/// - `recentBPMs`: 4 BPM individuali (da ogni singolo intervallo) per le pills UI.
/// - Reset automatico a 0 dopo 3 s senza beat rilevati.
///
/// ## Threading
/// `process(buffer:)` è chiamato sincrono dalla DSP queue di AudioEngine.
/// Tutte le scritture su BeatState avvengono via `Task { @MainActor in … }`.
final class BeatDetector: @unchecked Sendable {

    // MARK: DSP constants

    /// Numero di campioni RMS nella finestra scorrevole (~1 s a 44100/2048 Hz).
    private nonisolated static var energyWindowSize: Int { 22 }

    /// Onset se rms > media + std × onsetSigma.
    private nonisolated static var onsetSigma: Float { 1.0 }

    /// Periodo refrattario minimo tra due onset (300 ms → max 200 BPM).
    private nonisolated static var refractorySeconds: Double { 0.300 }

    /// Intervallo massimo valido tra onset (2000 ms → min 30 BPM).
    private nonisolated static var maxIntervalSeconds: Double { 2.000 }

    /// Soglia outlier: intervallo scartato se devia > 40 % dalla mediana degli ultimi N.
    private nonisolated static var outlierThreshold: Double { 0.40 }

    /// Numero di intervalli nella finestra BPM (media mobile).
    private nonisolated static var bpmWindowSize: Int { 4 }

    // MARK: Kick discrimination constants

    /// Cutoff del filtro LP per isolare la banda della grancassa (< kickCutoffHz).
    /// La cassa ha il fondamentale a 40–100 Hz; il rullante domina sopra i 100 Hz.
    private nonisolated static var kickCutoffHz: Double { 100.0 }

    /// Frazione minima di energia che deve stare sotto kickCutoffHz perché l'onset
    /// sia classificato come grancassa (e non rullante/altro).
    /// 0.40 = almeno il 40% dell'energia totale (30–250 Hz) deve essere < 100 Hz.
    private nonisolated static var kickRatioThreshold: Float { 0.40 }

    // MARK: Private state
    // nonisolated(unsafe): tutto acceduto dalla sola DSP queue (serial), concorrenza
    // manuale garantita dall'uso esclusivo da un singolo DispatchQueue consumer.

    nonisolated(unsafe) private weak var state: BeatState?
    nonisolated(unsafe) private let now: () -> Double

    // Finestra scorrevole di energia RMS (~1 s): pre-allocata, nessuna alloc nel loop.
    nonisolated(unsafe) private var energyWindow: [Float]
    nonisolated(unsafe) private var energyWindowHead: Int = 0
    nonisolated(unsafe) private var energyWindowCount: Int = 0

    // Ultimi N intervalli validi (secondi) — rolling window per BPM.
    nonisolated(unsafe) private var onsetIntervals: [Double] = []

    // Tutti i BPM validi della sessione (capped) — per min/max/avg.
    nonisolated(unsafe) private var sessionBPMs: [Double] = []
    private nonisolated static var sessionBPMCap: Int { 2000 }

    // Timing degli onset.
    nonisolated(unsafe) private var lastOnsetTime: Double = 0

    // Task che azzera il BPM dopo 3 s di silenzio; cancellato ad ogni nuovo beat.
    nonisolated(unsafe) private var beatResetTask: Task<Void, Never>?

    // Kick discrimination — filtro LP aggiuntivo a kickCutoffHz.
    // Pre-allocato in init; zero allocazioni nel DSP loop.
    nonisolated(unsafe) private var kickLPSetup: vDSP_biquad_Setup?
    nonisolated(unsafe) private var kickLPDelay: [Float] = [0, 0, 0, 0]   // 2*sections+2
    nonisolated(unsafe) private var kickWorkBuffer: [Float]                // scratch buffer

    // MARK: Init

    /// - Parameters:
    ///   - state: Stato condiviso aggiornato su @MainActor.
    ///   - now: Provider di timestamp iniettabile (default: CFAbsoluteTimeGetCurrent).
    ///     Nei test sostituire con un clock controllato.
    init(state: BeatState, now: @escaping () -> Double = CFAbsoluteTimeGetCurrent) {
        self.state      = state
        self.now        = now
        energyWindow    = [Float](repeating: 0, count: BeatDetector.energyWindowSize)
        kickWorkBuffer  = [Float](repeating: 0, count: 4096)
    }

    deinit {
        if let lp = kickLPSetup { vDSP_biquad_DestroySetup(lp) }
    }

    // MARK: Testability

    /// Espone la soglia adattiva corrente (media + σ × onsetSigma) per i test.
    nonisolated var currentThreshold: Float {
        let (mean, std) = computeEnergyStats()
        return mean + std * BeatDetector.onsetSigma
    }

    // MARK: Public interface

    /// Processa un buffer PCM pre-filtrato (HP@30 Hz + LP@250 Hz).
    ///
    /// Chiamato sincrono dalla DSP queue di AudioEngine (borrow semantics):
    /// non trattenere `buffer` oltre il ritorno.
    nonisolated func process(buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let n = vDSP_Length(buffer.frameLength)
        guard n > 0 else { return }

        // Step 1 — RMS del buffer corrente.
        var rms: Float = 0
        vDSP_rmsqv(ch[0], 1, &rms, n)

        // Step 2 — Aggiorna la finestra scorrevole di energia (circular buffer).
        energyWindow[energyWindowHead] = rms
        energyWindowHead = (energyWindowHead + 1) % BeatDetector.energyWindowSize
        if energyWindowCount < BeatDetector.energyWindowSize { energyWindowCount += 1 }

        // Warm-up: servono almeno 3 campioni per una soglia significativa.
        guard energyWindowCount >= 3 else { return }

        // Step 3 — Soglia = media + std della finestra energia.
        let (mean, std) = computeEnergyStats()
        let threshold = mean + std * BeatDetector.onsetSigma

        // Step 4 — Onset detection.
        guard rms > threshold, threshold > 0.001 else { return }

        // Step 4b — Kick discrimination: verifica che l'energia sia concentrata
        // sotto kickCutoffHz (= grancassa) e non nella banda del rullante (100–250 Hz).
        let kickRMS   = kickBandRMS(samples: ch[0], count: Int(n),
                                    sampleRate: buffer.format.sampleRate)
        let kickRatio = rms > 0 ? kickRMS / rms : 0
        guard kickRatio >= BeatDetector.kickRatioThreshold else { return }

        // Step 5 — Refrattario.
        let t = now()
        guard t - lastOnsetTime >= BeatDetector.refractorySeconds else { return }

        registerOnset(at: t)
    }

    /// Azzera lo stato interno e pubblica il reset su BeatState.
    ///
    /// Chiamare solo dopo `AudioEngine.stop()`.
    nonisolated func reset() {
        energyWindow = [Float](repeating: 0, count: BeatDetector.energyWindowSize)
        energyWindowHead  = 0
        energyWindowCount = 0
        onsetIntervals.removeAll()
        sessionBPMs.removeAll()
        lastOnsetTime = 0
        beatResetTask?.cancel()
        beatResetTask = nil
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
        // Gap > 2 s: pausa ritmica, azzera rolling window ma non il BPM.
        if lastOnsetTime > 0 && time - lastOnsetTime > 2.0 {
            onsetIntervals.removeAll()
        }

        defer { lastOnsetTime = time }

        // Primo onset: registra solo il timestamp.
        guard lastOnsetTime > 0 else { return }

        let interval = time - lastOnsetTime

        // Step A — Valida range BPM (30–200 BPM → 300 ms–2000 ms).
        guard interval >= BeatDetector.refractorySeconds,
              interval <= BeatDetector.maxIntervalSeconds else { return }

        // Step B — Outlier rejection: ±40 % dalla mediana degli ultimi N intervalli.
        if !onsetIntervals.isEmpty {
            let med = median(onsetIntervals)
            guard abs(interval - med) / med <= BeatDetector.outlierThreshold else { return }
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
        let bpm = rounded1(60.0 / meanInterval)

        // BPM individuali per le pills UI (1 decimale ciascuno).
        let recentBPMs = onsetIntervals.map { rounded1(60.0 / $0) }

        sessionBPMs.append(bpm)
        if sessionBPMs.count > BeatDetector.sessionBPMCap { sessionBPMs.removeFirst() }

        publishBeatState(currentBPM: bpm, recentBPMs: recentBPMs)
    }

    // MARK: Private — DSP helpers

    /// Filtra i campioni con un biquad LP a kickCutoffHz e restituisce il loro RMS.
    ///
    /// Il filtro viene inizializzato al primo invocation (sample-rate noto solo a runtime).
    /// L'inizializzazione è un'unica allocazione fuori dal loop stazionario.
    nonisolated private func kickBandRMS(samples: UnsafePointer<Float>,
                                          count: Int,
                                          sampleRate: Double) -> Float {
        if kickLPSetup == nil {
            let fc    = BeatDetector.kickCutoffHz
            let q     = 1.0 / 2.0.squareRoot()          // Butterworth
            let w0    = 2.0 * .pi * fc / sampleRate
            let cosW  = cos(w0)
            let alpha = sin(w0) / (2.0 * q)
            let a0    = 1.0 + alpha
            let coeffs: [Double] = [
                (1.0 - cosW) / 2.0 / a0,   // b0/a0
                (1.0 - cosW)       / a0,    // b1/a0
                (1.0 - cosW) / 2.0 / a0,   // b2/a0
                -2.0 * cosW        / a0,    // a1/a0
                (1.0 - alpha)      / a0     // a2/a0
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

    /// Calcola media e deviazione standard dell'energia nella finestra scorrevole.
    /// Opera sui soli `energyWindowCount` campioni riempiti.
    nonisolated private func computeEnergyStats() -> (mean: Float, std: Float) {
        guard energyWindowCount > 0 else { return (0, 0) }

        var sum: Float = 0
        var sumSq: Float = 0
        for i in 0..<energyWindowCount {
            let v = energyWindow[i]
            sum   += v
            sumSq += v * v
        }
        let n    = Float(energyWindowCount)
        let mean = sum / n
        // Var = E[x²] - E[x]²   (population variance)
        let variance = max(0, sumSq / n - mean * mean)
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

    // MARK: Private — publish

    nonisolated private func publishBeatState(currentBPM: Double, recentBPMs: [Double]) {
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
            state.currentBPM = currentBPM
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
