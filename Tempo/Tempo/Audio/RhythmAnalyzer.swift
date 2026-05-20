import Foundation
import os.log

#if DEBUG
private let raLog = Logger(subsystem: "com.ldelzoppo.tempo", category: "RhythmAnalyzer")
#endif

// MARK: - RhythmAnalyzer

/// Riceve gli onset da `BeatDetector.onOnset` e inferisce BPM e metrica ritmica.
///
/// ## Responsabilità
/// - Calcola `currentBPM` da una finestra circolare di IOI (Inter-Onset Interval)
///   usando il GCD robusto con tolleranza del 5%.
/// - Determina il metro candidato (`detectedMeter`, `meterDenominator`) con un
///   hypothesis engine che testa i metri `[4, 3, 5, 7, 6, 11]`.
/// - Valida ogni IOI in ingresso contro la soglia del metro corrente (outlier
///   rejection adattiva), tracciando `acceptedCount`/`totalCount` sull'ultima
///   finestra di 8 IOI per calcolare `meterConfidence`.
/// - Gestisce hysteresis al cambio metro (≥ 4 beat consecutivi con confidence ≥ 0.65)
///   e reset del hypothesis engine se la confidence scende sotto 0.40 per ≥ 3 beat.
/// - Traccia la posizione corrente nel metro (`beatInMeter`).
/// - Pubblica i risultati su `BeatState` via `Task { @MainActor in … }`.
///
/// ## Threading
/// `registerOnset(timestamp:rms:)` è chiamato dalla DSP queue (serial) tramite
/// `BeatDetector.onOnset`. Tutti i campi interni sono `nonisolated(unsafe)` e
/// acceduti esclusivamente dalla DSP queue — nessun lock necessario.
///
/// `reset()` deve essere chiamato prima di `AudioEngine.start()` o dopo `stop()`,
/// dalla stessa DSP queue o dalla main queue quando l'engine è fermo.
final class RhythmAnalyzer: @unchecked Sendable {

    // MARK: - DSP constants
    // Pattern nonisolated static var { get } per evitare l'inferenza @MainActor
    // su static stored properties, coerente con BeatDetector.

    /// Capacità del buffer circolare IOI.
    /// 16 intervalli coprono ~13 s a 120 BPM (intervallo 500 ms) — abbastanza per
    /// stabilizzare la stima GCD anche su pattern complessi come 11/8.
    private nonisolated static var iOIBufferCapacity: Int { 16 }

    /// Numero minimo di IOI nel buffer prima di calcolare GCD e metro.
    private nonisolated static var minimumIOICount: Int { 4 }

    /// Intervallo minimo fisico accettabile tra onset (100 ms).
    /// Filtra onset gemelli (doppi rilevamenti a < 100 ms): sotto questa soglia il
    /// segnale è sempre un artefatto (risonanza, click elettronico) e non un beat.
    private nonisolated static var minimumIOISeconds: Double { 0.100 }

    /// Tolleranza GCD: un IOI è "multiplo intero" del GCD candidato se il resto
    /// normalizzato è entro il 5% del GCD stesso.
    /// 5% corrisponde a ~25 ms su un IOI da 500 ms (120 BPM) — abbondantemente
    /// dentro la varianza umana di ±5–8 ms per beat.
    private nonisolated static var gcdTolerance: Double { 0.05 }

    /// BPM minimo prima dell'octave correction.
    /// Se il BPM raw è < 80 significa che il GCD IOI corrisponde a un kick ogni 2+
    /// beat (half-time feel o pattern rado). Raddoppiare porta alla pulsazione reale.
    private nonisolated static var octaveCorrectionThreshold: Double { 80.0 }

    /// Denominatori testati dal meter hypothesis engine.
    /// 4 → notazione tradizionale (4/4, 3/4, 5/4, 7/4, 6/4, 11/4)
    /// 8 → notazione compound (4/8, 3/8, 5/8, 7/8, 6/8, 11/8)
    private nonisolated static var candidateDenominators: [Int] { [4, 8] }

    /// Numeratori (beat per battuta) testati dal meter hypothesis engine, in ordine
    /// di priorità decrescente (i metri più comuni vengono testati per primi).
    private nonisolated static var candidateNumerators: [Int] { [4, 3, 5, 7, 6, 11] }

    /// Soglie outlier per numeratore — tolleranza adattiva per metro.
    /// Fonte: Music Theory Agent (TBD-68).
    /// Metri semplici (4, 3): tolleranza stretta perché gli IOI sono regolari.
    /// Metri complessi (7, 11): tolleranza alta perché gli IOI raggruppati creano
    /// varianza strutturale intrinseca (es. 7/8 = 3+4 o 2+2+3).
    private nonisolated static var outlierThresholdByNumerator: [Int: Double] {
        [4: 0.13, 3: 0.18, 5: 0.28, 7: 0.55, 6: 0.22, 11: 0.60]
    }

    /// Dimensione della finestra scorrevole per il calcolo di `meterConfidence`.
    /// 8 IOI = ~4 s a 120 BPM: abbastanza per rilevare un cambio di metro in tempo reale
    /// senza essere troppo reattivo ai singoli outlier accidentali.
    private nonisolated static var confidenceWindowSize: Int { 8 }

    /// Soglia sotto cui la confidence è considerata "bassa" (trigger reset hysteresis).
    /// Fonte: TBD-70 — 0.40 garantisce che almeno 3 IOI su 8 siano accettati prima
    /// di decidere che il metro è cambiato.
    private nonisolated static var lowConfidenceThreshold: Double { 0.40 }

    /// Numero di beat consecutivi con confidence bassa prima del reset del hypothesis engine.
    /// 3 beat consecutivi (non buffer size) bilanciamo reattività e stabilità.
    private nonisolated static var lowConfidenceStreakLimit: Int { 3 }

    /// Soglia minima di confidence per accettare un metro candidato.
    /// Fonte: TBD-70 — 0.65 = ≥ 5 IOI su 8 accettati nel metro candidato.
    private nonisolated static var candidateConfidenceThreshold: Double { 0.65 }

    /// Numero di beat consecutivi con confidence alta per confermare il cambio metro.
    /// 4 beat consecutivi = ~2 battute in 4/4 a 120 BPM: hysteresis adeguata.
    private nonisolated static var candidateStreakLimit: Int { 4 }

    // MARK: - Private state
    // nonisolated(unsafe): acceduto esclusivamente dalla DSP queue (serial).

    nonisolated(unsafe) private weak var state: BeatState?

    /// Buffer circolare degli IOI più recenti (secondi).
    nonisolated(unsafe) private var iOIBuffer: [Double]

    /// Indice write-head nel buffer circolare.
    nonisolated(unsafe) private var iOIBufferHead: Int = 0

    /// Numero di IOI validi nel buffer (≤ iOIBufferCapacity).
    nonisolated(unsafe) private var iOIBufferCount: Int = 0

    /// Timestamp dell'ultimo onset registrato (secondi, CACurrentMediaTime).
    nonisolated(unsafe) private var lastOnsetTimestamp: Double = 0

    /// Posizione corrente nel metro, 1-based. Resettata a 1 quando raggiunge
    /// `detectedMeter` (si avvolge alla fine della battuta).
    nonisolated(unsafe) private var currentBeatInMeter: Int = 1

    /// Metro attualmente rilevato (numero di beat per battuta).
    /// Inizializza a 4 (ipotesi default 4/4).
    nonisolated(unsafe) private var currentDetectedMeter: Int = 4

    /// Denominatore del metro attualmente rilevato (4 o 8).
    nonisolated(unsafe) private var currentMeterDenominator: Int = 4

    // MARK: - Outlier rejection & confidence window
    // Finestra scorrevole di `confidenceWindowSize` slot booleani (true = accettato).
    // Implementata come buffer circolare per evitare allocazioni in tempo reale.

    /// Buffer circolare che registra se ogni IOI degli ultimi `confidenceWindowSize`
    /// è stato accettato (true) o rifiutato (false) dalla soglia adattiva per metro.
    nonisolated(unsafe) private var acceptanceWindow: [Bool]

    /// Write-head del buffer `acceptanceWindow`.
    nonisolated(unsafe) private var acceptanceWindowHead: Int = 0

    /// Numero di slot validi nella finestra (≤ confidenceWindowSize).
    nonisolated(unsafe) private var acceptanceWindowCount: Int = 0

    /// Confidence corrente calcolata dalla finestra scorrevole: `acceptedCount / totalCount`.
    /// Aggiornata ad ogni IOI, pubblicata su `BeatState`.
    nonisolated(unsafe) private var meterConfidence: Double = 0.0

    // MARK: - Low-confidence hysteresis (reset trigger)

    /// Numero di beat consecutivi in cui `meterConfidence` è rimasta sotto
    /// `lowConfidenceThreshold`. Quando raggiunge `lowConfidenceStreakLimit`
    /// il hypothesis engine viene resettato.
    nonisolated(unsafe) private var lowConfidenceStreak: Int = 0

    // MARK: - Meter change hysteresis (candidato)

    /// Numeratore del metro candidato in attesa di conferma.
    /// Viene proposto da `detectMeter` quando differisce da `currentDetectedMeter`.
    nonisolated(unsafe) private var candidateMeter: Int = 0

    /// Denominatore del metro candidato.
    nonisolated(unsafe) private var candidateMeterDenominator: Int = 0

    /// Numero di beat consecutivi in cui il candidato ha mantenuto confidence ≥ 0.65.
    /// Quando raggiunge `candidateStreakLimit` il metro viene confermato.
    nonisolated(unsafe) private var candidateStreak: Int = 0

    // MARK: - Init

    /// - Parameter state: Stato condiviso aggiornato su `@MainActor`.
    init(state: BeatState) {
        self.state = state
        self.iOIBuffer      = [Double](repeating: 0, count: RhythmAnalyzer.iOIBufferCapacity)
        self.acceptanceWindow = [Bool](repeating: false, count: RhythmAnalyzer.confidenceWindowSize)
    }

    // MARK: - Public interface

    /// Registra un onset valido ricevuto da `BeatDetector.onOnset`.
    ///
    /// Chiamato sulla DSP queue — nessuna allocazione, nessun lock.
    ///
    /// - Parameters:
    ///   - timestamp: `CACurrentMediaTime()` al momento dell'onset.
    ///   - rms: Energia RMS del buffer all'onset (non usata nel calcolo BPM ma
    ///     disponibile per estensioni future, es. accent detection).
    nonisolated func registerOnset(timestamp: Double, rms: Float) {
        defer { lastOnsetTimestamp = timestamp }

        // Primo onset: registra solo il timestamp, nessun IOI calcolabile.
        guard lastOnsetTimestamp > 0 else {
            #if DEBUG
            raLog.debug("RA onset[1st]  ts=\(timestamp, format: .fixed(precision: 3))")
            #endif
            return
        }

        let ioi = timestamp - lastOnsetTimestamp

        // Filtra onset gemelli: IOI < 100 ms è sempre un artefatto.
        guard ioi >= RhythmAnalyzer.minimumIOISeconds else {
            #if DEBUG
            raLog.debug("RA onset gemello scartato  ioi=\(ioi, format: .fixed(precision: 4))s")
            #endif
            return
        }

        // --- Outlier rejection adattiva per metro ---
        // Se il buffer ha già un GCD stabile (≥ minimumIOICount IOI), valida il nuovo
        // IOI contro la soglia del metro corrente prima di inserirlo nel buffer.
        // Durante il warmup (buffer non ancora stabile) accetta sempre.
        let isAccepted: Bool
        if iOIBufferCount >= RhythmAnalyzer.minimumIOICount {
            let existingIOIs = collectIOIs()
            if let gcdIOI = robustGCD(of: existingIOIs) {
                let threshold = RhythmAnalyzer.outlierThresholdByNumerator[currentDetectedMeter]
                              ?? RhythmAnalyzer.gcdTolerance
                let multiple = (ioi / gcdIOI).rounded()
                let reconstructed = multiple * gcdIOI
                let error = multiple >= 1 ? abs(ioi - reconstructed) / gcdIOI : Double.greatestFiniteMagnitude
                isAccepted = error <= threshold
            } else {
                // GCD non trovato nel buffer esistente: accetta in attesa di stabilizzazione.
                isAccepted = true
            }
        } else {
            // Fase di warmup: accetta tutti gli IOI.
            isAccepted = true
        }

        // Aggiorna la finestra di confidence.
        recordAcceptance(isAccepted)
        updateMeterConfidence()

        // IOI rifiutato: non entra nel buffer, aggiorna la confidence e controlla il reset.
        guard isAccepted else {
            #if DEBUG
            raLog.debug("RA IOI rifiutato (outlier)  ioi=\(ioi, format: .fixed(precision: 3))s  meter=\(self.currentDetectedMeter)/\(self.currentMeterDenominator)  confidence=\(String(format: "%.2f", self.meterConfidence))")
            #endif
            checkLowConfidenceReset()
            advanceBeatInMeter()
            publishToState(bpm: nil, meter: nil, denominator: nil)
            return
        }

        // Aggiorna il buffer circolare IOI.
        iOIBuffer[iOIBufferHead] = ioi
        iOIBufferHead = (iOIBufferHead + 1) % RhythmAnalyzer.iOIBufferCapacity
        if iOIBufferCount < RhythmAnalyzer.iOIBufferCapacity { iOIBufferCount += 1 }

        #if DEBUG
        raLog.debug("RA onset  ioi=\(ioi, format: .fixed(precision: 3))s  bufCount=\(self.iOIBufferCount)  accepted=true  confidence=\(String(format: "%.2f", self.meterConfidence))")
        #endif

        // Aggiorna la posizione nel metro ad ogni onset accettato.
        advanceBeatInMeter()

        // Analisi ritmica: richiede almeno minimumIOICount IOI.
        guard iOIBufferCount >= RhythmAnalyzer.minimumIOICount else {
            publishToState(bpm: nil, meter: nil, denominator: nil)
            return
        }

        let iois = collectIOIs()
        guard let gcdIOI = robustGCD(of: iois) else {
            publishToState(bpm: nil, meter: nil, denominator: nil)
            return
        }

        let rawBPM = 60.0 / gcdIOI
        let bpm = rawBPM < RhythmAnalyzer.octaveCorrectionThreshold ? rawBPM * 2.0 : rawBPM

        let (candidateNum, candidateDen) = detectMeter(iois: iois, gcdIOI: gcdIOI)

        // Hysteresis cambio metro: il metro si aggiorna solo dopo `candidateStreakLimit`
        // beat consecutivi con confidence ≥ `candidateConfidenceThreshold`.
        updateMeterCandidate(numerator: candidateNum, denominator: candidateDen)

        checkLowConfidenceReset()

        #if DEBUG
        print("[RA] metro: \(currentDetectedMeter)/\(currentMeterDenominator) confidence: \(String(format: "%.2f", meterConfidence)) bpm: \(String(format: "%.1f", bpm))")
        #endif

        publishToState(bpm: bpm, meter: currentDetectedMeter, denominator: currentMeterDenominator)
    }

    /// Azzera lo stato interno e resetta i campi di metro su `BeatState`.
    ///
    /// Chiamare dopo `AudioEngine.stopCapture()` prima di un nuovo avvio.
    nonisolated func reset() {
        iOIBuffer       = [Double](repeating: 0, count: RhythmAnalyzer.iOIBufferCapacity)
        iOIBufferHead   = 0
        iOIBufferCount  = 0
        lastOnsetTimestamp      = 0
        currentBeatInMeter      = 1
        currentDetectedMeter    = 4
        currentMeterDenominator = 4

        acceptanceWindow      = [Bool](repeating: false, count: RhythmAnalyzer.confidenceWindowSize)
        acceptanceWindowHead  = 0
        acceptanceWindowCount = 0
        meterConfidence       = 0.0

        lowConfidenceStreak       = 0
        candidateMeter            = 0
        candidateMeterDenominator = 0
        candidateStreak           = 0

        Task { @MainActor [weak state] in
            guard let state else { return }
            state.detectedMeter    = 4
            state.meterDenominator = 4
            state.beatInMeter      = 1
            state.meterConfidence  = 0.0
        }
    }

    // MARK: - Private — beat-in-meter tracking

    /// Incrementa la posizione nel metro e resetta a 1 quando raggiunge il metro corrente.
    nonisolated private func advanceBeatInMeter() {
        currentBeatInMeter += 1
        if currentBeatInMeter > currentDetectedMeter {
            currentBeatInMeter = 1
        }
    }

    // MARK: - Private — IOI collection

    /// Restituisce gli IOI validi nel buffer, dal più vecchio al più recente.
    nonisolated private func collectIOIs() -> [Double] {
        let count    = iOIBufferCount
        let capacity = RhythmAnalyzer.iOIBufferCapacity
        var result   = [Double](repeating: 0, count: count)
        for i in 0..<count {
            // Indice del campione più vecchio nella finestra corrente:
            // il write-head punta alla prossima posizione libera; camminando
            // indietro di `count` passi si raggiunge il campione più vecchio.
            let idx = (iOIBufferHead - count + i + capacity) % capacity
            result[i] = iOIBuffer[idx]
        }
        return result
    }

    // MARK: - Private — GCD robusto

    /// Calcola il GCD degli IOI con tolleranza del 5%.
    ///
    /// Algoritmo:
    /// 1. Ordina gli IOI in ordine crescente.
    /// 2. Usa il minimo come candidato GCD iniziale.
    /// 3. Verifica quanti IOI sono multipli interi del candidato ± tolleranza (5%).
    /// 4. Se la maggioranza (≥ 50%) è compatibile, il candidato è il GCD.
    /// 5. Altrimenti, testa frazioni razionali del minimo (1/2, 1/3) per coprire
    ///    il caso in cui il minimo stesso sia un multiplo del GCD reale.
    ///
    /// Restituisce `nil` se non si trova un GCD robusto.
    nonisolated private func robustGCD(of iois: [Double]) -> Double? {
        guard !iois.isEmpty else { return nil }
        let sorted  = iois.sorted()
        let minimum = sorted[0]
        guard minimum > 0 else { return nil }

        // Testa il minimo e sue frazioni 1/2 e 1/3 come candidati GCD.
        // La frazione 1/2 copre il caso in cui il minimo IOI osservato sia
        // già un multiplo 2× del beat reale (es. kick ogni altro beat in 4/4).
        // La frazione 1/3 copre pattern terzinati o 6/8 interpretato come 2/4.
        let candidates: [Double] = [minimum, minimum / 2.0, minimum / 3.0]

        var bestCandidate: Double? = nil
        var bestScore = -1

        for candidate in candidates {
            guard candidate >= RhythmAnalyzer.minimumIOISeconds else { continue }
            let score = compatibleCount(iois: sorted, gcd: candidate,
                                        tolerance: RhythmAnalyzer.gcdTolerance)
            // Il candidato deve spiegare almeno il 50% degli IOI.
            if score > bestScore && score >= sorted.count / 2 {
                bestScore     = score
                bestCandidate = candidate
            }
        }

        #if DEBUG
        if let best = bestCandidate {
            raLog.debug("RA GCD=\(best, format: .fixed(precision: 3))s  score=\(bestScore)/\(iois.count)")
        } else {
            raLog.debug("RA GCD non trovato  iois=\(iois.map { String(format: "%.3f", $0) }.joined(separator: ","))")
        }
        #endif

        return bestCandidate
    }

    /// Conta quanti IOI sono multipli interi del GCD candidato entro la tolleranza.
    ///
    /// Un IOI è "compatibile" con il candidato se:
    /// `abs(ioi - round(ioi / candidate) * candidate) / candidate ≤ tolerance`
    nonisolated private func compatibleCount(iois: [Double],
                                              gcd: Double,
                                              tolerance: Double) -> Int {
        var count = 0
        for ioi in iois {
            let multiple = (ioi / gcd).rounded()
            guard multiple >= 1 else { continue }
            let reconstructed = multiple * gcd
            let error = abs(ioi - reconstructed) / gcd
            if error <= tolerance { count += 1 }
        }
        return count
    }

    // MARK: - Private — meter hypothesis engine

    /// Determina il metro più probabile testando i candidati `[4, 3, 5, 7, 6, 11]`
    /// con denominatori `[4, 8]`.
    ///
    /// Per ogni candidato `(numerator, denominator)` conta gli IOI compatibili con
    /// `gcdIOI * (denominator / 4.0)` ± soglia adattiva per metro.
    /// Il metro con il punteggio più alto vince.
    ///
    /// Restituisce il metro default `(4, 4)` se nessun candidato supera il minimo.
    nonisolated private func detectMeter(iois: [Double], gcdIOI: Double) -> (numerator: Int, denominator: Int) {
        var bestNumerator   = 4
        var bestDenominator = 4
        var bestScore       = -1

        for denominator in RhythmAnalyzer.candidateDenominators {
            // Durata di un'unità ritmica nell'ipotetico metro (denominatore / 4.0
            // converte l'unità: denominatore=4 → unità = 1 semiminima = 1 GCD beat;
            // denominatore=8 → unità = 1 croma = GCD beat / 2).
            let unitIOI = gcdIOI * (Double(denominator) / 4.0)
            guard unitIOI >= RhythmAnalyzer.minimumIOISeconds else { continue }

            for numerator in RhythmAnalyzer.candidateNumerators {
                let threshold = RhythmAnalyzer.outlierThresholdByNumerator[numerator]
                              ?? RhythmAnalyzer.gcdTolerance

                // Conta IOI compatibili con l'unità ritmica di questo metro.
                let score = compatibleCount(iois: iois, gcd: unitIOI, tolerance: threshold)

                #if DEBUG
                raLog.debug("RA meter \(numerator)/\(denominator)  unitIOI=\(unitIOI, format: .fixed(precision: 3))s  score=\(score)/\(iois.count)")
                #endif

                if score > bestScore {
                    bestScore       = score
                    bestNumerator   = numerator
                    bestDenominator = denominator
                }
            }
        }

        return (bestNumerator, bestDenominator)
    }

    // MARK: - Private — outlier acceptance window

    /// Inserisce un risultato (accettato/rifiutato) nella finestra scorrevole circolare.
    nonisolated private func recordAcceptance(_ accepted: Bool) {
        acceptanceWindow[acceptanceWindowHead] = accepted
        acceptanceWindowHead = (acceptanceWindowHead + 1) % RhythmAnalyzer.confidenceWindowSize
        if acceptanceWindowCount < RhythmAnalyzer.confidenceWindowSize {
            acceptanceWindowCount += 1
        }
    }

    /// Ricalcola `meterConfidence` dalla finestra scorrevole corrente.
    nonisolated private func updateMeterConfidence() {
        guard acceptanceWindowCount > 0 else {
            meterConfidence = 0.0
            return
        }
        var accepted = 0
        for i in 0..<acceptanceWindowCount {
            // Leggi i dati più recenti: i più recenti sono quelli prima della write-head.
            let capacity = RhythmAnalyzer.confidenceWindowSize
            let idx = (acceptanceWindowHead - acceptanceWindowCount + i + capacity) % capacity
            if acceptanceWindow[idx] { accepted += 1 }
        }
        meterConfidence = Double(accepted) / Double(acceptanceWindowCount)
    }

    // MARK: - Private — low-confidence reset hysteresis

    /// Controlla se la confidence è rimasta bassa per troppi beat consecutivi,
    /// e in quel caso resetta il hypothesis engine (svuota il buffer IOI).
    nonisolated private func checkLowConfidenceReset() {
        if meterConfidence < RhythmAnalyzer.lowConfidenceThreshold {
            lowConfidenceStreak += 1
            if lowConfidenceStreak >= RhythmAnalyzer.lowConfidenceStreakLimit {
                #if DEBUG
                raLog.debug("RA hypothesis reset (low confidence streak=\(self.lowConfidenceStreak)  confidence=\(String(format: "%.2f", self.meterConfidence)))")
                #endif
                resetHypothesisEngine()
            }
        } else {
            lowConfidenceStreak = 0
        }
    }

    /// Svuota il buffer IOI e azzera `beatInMeter` per ri-valutare il metro
    /// dal prossimo onset. Non tocca il metro corrente: viene mantenuto fino
    /// alla prossima conferma con hysteresis.
    nonisolated private func resetHypothesisEngine() {
        iOIBuffer      = [Double](repeating: 0, count: RhythmAnalyzer.iOIBufferCapacity)
        iOIBufferHead  = 0
        iOIBufferCount = 0
        currentBeatInMeter = 1
        lowConfidenceStreak = 0
        candidateMeter            = 0
        candidateMeterDenominator = 0
        candidateStreak           = 0
    }

    // MARK: - Private — meter change hysteresis

    /// Valuta il metro proposto da `detectMeter` e aggiorna `currentDetectedMeter`
    /// solo dopo `candidateStreakLimit` beat consecutivi con confidence ≥ 0.65.
    ///
    /// - Parameters:
    ///   - numerator: Metro candidato proposto (numero di beat per battuta).
    ///   - denominator: Denominatore del metro candidato (4 o 8).
    nonisolated private func updateMeterCandidate(numerator: Int, denominator: Int) {
        // Stesso metro già confermato: nessuna transizione da valutare.
        if numerator == currentDetectedMeter && denominator == currentMeterDenominator {
            candidateMeter            = 0
            candidateMeterDenominator = 0
            candidateStreak           = 0
            return
        }

        // Candidato diverso dal metro corrente.
        if numerator == candidateMeter && denominator == candidateMeterDenominator {
            // Stesso candidato del beat precedente: incrementa streak se confidence ok.
            if meterConfidence >= RhythmAnalyzer.candidateConfidenceThreshold {
                candidateStreak += 1
            } else {
                // Confidence insufficiente: azzera la streak del candidato.
                candidateStreak = 0
            }
        } else {
            // Nuovo candidato diverso dal precedente: resetta la streak.
            candidateMeter            = numerator
            candidateMeterDenominator = denominator
            candidateStreak           = meterConfidence >= RhythmAnalyzer.candidateConfidenceThreshold ? 1 : 0
        }

        // Conferma il cambio metro solo dopo streak sufficiente.
        if candidateStreak >= RhythmAnalyzer.candidateStreakLimit {
            #if DEBUG
            raLog.debug("RA meter change confirmed: \(self.currentDetectedMeter)/\(self.currentMeterDenominator) → \(numerator)/\(denominator)  streak=\(self.candidateStreak)  confidence=\(String(format: "%.2f", self.meterConfidence))")
            #endif
            currentDetectedMeter    = numerator
            currentMeterDenominator = denominator
            currentBeatInMeter      = 1
            candidateMeter            = 0
            candidateMeterDenominator = 0
            candidateStreak           = 0
        }
    }

    // MARK: - Private — publish

    /// Pubblica BPM, metro, posizione e meterConfidence su `BeatState` via `@MainActor`.
    ///
    /// Passa `nil` per i parametri che non devono essere aggiornati in questo ciclo
    /// (es. quando un IOI è stato rifiutato come outlier ma la confidence va pubblicata).
    nonisolated private func publishToState(bpm: Double?,
                                             meter: Int?,
                                             denominator: Int?) {
        let beatInMeter     = currentBeatInMeter
        let confidence      = meterConfidence
        let resolvedMeter   = meter
        let resolvedDen     = denominator
        let resolvedBPM     = bpm

        Task { @MainActor [weak state] in
            guard let state else { return }
            state.meterConfidence = confidence
            guard !state.tapOverrideActive else { return }
            if let b = resolvedBPM       { state.currentBPM       = b }
            if let m = resolvedMeter     { state.detectedMeter     = m }
            if let d = resolvedDen       { state.meterDenominator  = d }
            state.beatInMeter = beatInMeter
        }
    }
}
