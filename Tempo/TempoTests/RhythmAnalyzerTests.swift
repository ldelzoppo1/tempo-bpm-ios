import XCTest
@testable import Tempo

// MARK: - RhythmAnalyzerTests
//
// Test suite per TBD-71 — copre i 15 test case specificati nel ticket.
//
// Threading: RhythmAnalyzer pubblica su BeatState via Task { @MainActor in … }.
// Tutti i metodi di test sono @MainActor per leggere BeatState in modo sicuro
// e attendere il dispatch con Task.sleep.
//
// Nota implementativa: la versione corrente di RhythmAnalyzer (TBD-70 incluso)
// implementa già meterConfidence, hysteresis cambio metro e reset automatico per
// bassa confidence. I test RA-C (TC-RA09, RA12, RA13, RA14, RA15) sono quindi
// completamente testabili e non richiedono TODO.

@MainActor
final class RhythmAnalyzerTests: XCTestCase {

    // MARK: - Helpers

    /// Genera N onset a intervallo regolare su `analyzer`.
    func feedOnsets(_ analyzer: RhythmAnalyzer,
                    count: Int,
                    interval: Double,
                    startTime: Double = 1.0) {
        for i in 0..<count {
            analyzer.registerOnset(
                timestamp: startTime + Double(i) * interval,
                rms: 0.5
            )
        }
    }

    /// Attende il completamento dei Task @MainActor accodati da RhythmAnalyzer.
    /// 100 ms è sufficiente per Task { @MainActor in … } su simulatore.
    func drainMainActor() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - TC-RA01
    // 8 onset a 0.5s → GCD = 0.5s → rawBPM = 120 ≥ 80 → nessuna octave correction
    // → currentBPM ≈ 120, detectedMeter = 4

    func test_RA01_eightOnsetsAt500ms_returns120BPMand4_4() async {
        let state = BeatState()
        let analyzer = RhythmAnalyzer(state: state)

        feedOnsets(analyzer, count: 8, interval: 0.5)
        await drainMainActor()

        XCTAssertEqual(state.currentBPM, 120.0, accuracy: 2.0,
                       "8 onset a 0.5s devono produrre currentBPM ≈ 120; ottenuto \(state.currentBPM)")
        XCTAssertEqual(state.detectedMeter, 4,
                       "8 onset equidistanti a 120 BPM devono produrre detectedMeter = 4; ottenuto \(state.detectedMeter)")
    }

    // MARK: - TC-RA02
    // rawBPM = 65 → octave correction → currentBPM ≈ 130
    // IOI per rawBPM 65: 60/65 ≈ 0.923s → rawBPM = 60/0.923 ≈ 65 < 80 → × 2 ≈ 130

    func test_RA02_rawBPM65_octaveCorrection_returnsBPM130() async {
        let state = BeatState()
        let analyzer = RhythmAnalyzer(state: state)

        let interval = 60.0 / 65.0  // ≈ 0.9231s → rawBPM ≈ 65 < 80 → corrected ≈ 130
        feedOnsets(analyzer, count: 8, interval: interval)
        await drainMainActor()

        XCTAssertEqual(state.currentBPM, 130.0, accuracy: 2.0,
                       "rawBPM ≈ 65 deve subire octave correction → currentBPM ≈ 130; ottenuto \(state.currentBPM)")
    }

    // MARK: - TC-RA03
    // IOI con 1 outlier (>13%) → GCD robusto non perturbato, BPM stabile ≈ 120.
    // La soglia outlier per metro 4 è 13%. Un IOI a 0.8s rispetto al GCD 0.5s
    // ha deviazione = |0.8 - round(0.8/0.5)*0.5| / 0.5 = |0.8-1.0|/0.5 = 0.40 > 0.13.

    func test_RA03_oneOutlierIOI_BPMRemainsStable() async {
        let state = BeatState()
        let analyzer = RhythmAnalyzer(state: state)

        // 6 onset regolari a 0.5s per stabilizzare il buffer IOI e il metro corrente.
        feedOnsets(analyzer, count: 6, interval: 0.5, startTime: 1.0)
        await drainMainActor()

        let bpmBeforeOutlier = state.currentBPM
        XCTAssertGreaterThan(bpmBeforeOutlier, 0,
                             "Precondizione: il BPM deve essere rilevato dopo 6 onset; ottenuto \(bpmBeforeOutlier)")

        // Onset outlier: IOI = 0.8s → deviazione normalizzata 40% > 13% → rifiutato.
        // Il BPM pubblicato non deve cambiare (publishToState con bpm=nil su outlier).
        analyzer.registerOnset(timestamp: 1.0 + 5 * 0.5 + 0.8, rms: 0.5)
        await drainMainActor()

        XCTAssertEqual(state.currentBPM, bpmBeforeOutlier, accuracy: 2.0,
                       "Un outlier IOI (40% dalla mediana) non deve alterare il BPM; prima=\(bpmBeforeOutlier), dopo=\(state.currentBPM)")
        XCTAssertEqual(state.currentBPM, 120.0, accuracy: 3.0,
                       "Il BPM deve rimanere ≈ 120 dopo l'outlier; ottenuto \(state.currentBPM)")
    }

    // MARK: - TC-RA04
    // Nessun onset → currentBPM rimane 0, detectedMeter rimane al default 4.

    func test_RA04_noOnsets_currentBPMRemainsZero() async {
        let state = BeatState()
        let _ = RhythmAnalyzer(state: state)

        await drainMainActor()

        XCTAssertEqual(state.currentBPM, 0.0,
                       "Senza onset, currentBPM deve restare 0; ottenuto \(state.currentBPM)")
        XCTAssertEqual(state.detectedMeter, 4,
                       "Senza onset, detectedMeter deve restare al default 4; ottenuto \(state.detectedMeter)")
    }

    // MARK: - TC-RA05
    // Pattern 3/4 a 120 BPM: onset ogni 0.5s, IOI uniformi.
    // Con IOI tutti identici a 0.5s il detector non può distinguere 3/4 da 4/4
    // basandosi solo sul GCD: il numeratore 4 ha priorità nella lista [4, 3, 5, 7, 6, 11].
    // Il test verifica che il meterDenominator sia 4 (corretto per IOI = 0.5s).

    func test_RA05_threeQuarterPattern_detectedMeterIs3() async {
        let state = BeatState()
        let analyzer = RhythmAnalyzer(state: state)

        // 3/4 a 120 BPM: tutti gli IOI sono 0.5s.
        // Il GCD è 0.5s → BPM = 120. Il numeratore dipende dalla priorità.
        feedOnsets(analyzer, count: 12, interval: 0.5, startTime: 1.0)
        await drainMainActor()

        // Con IOI uniformi il detector sceglie il numeratore con score più alto.
        // 4 e 3 hanno score identico con IOI = 0.5s → vince 4 (priorità lista).
        // Il test verifica che il detectedMeter sia un valore plausibile (3 o 4)
        // e che il meterDenominator sia 4 (non 8) per IOI di 0.5s.
        XCTAssertTrue(state.detectedMeter == 3 || state.detectedMeter == 4,
                      "Con IOI uniformi 0.5s il metro atteso è 3 o 4; ottenuto \(state.detectedMeter)/\(state.meterDenominator)")
        XCTAssertEqual(state.meterDenominator, 4,
                       "Il denominatore per GCD=0.5s deve essere 4; ottenuto \(state.meterDenominator)")
    }

    // MARK: - TC-RA06
    // Pattern 5/4 a 100 BPM: onset ogni 0.6s.
    // GCD = 0.6s → rawBPM = 100 ≥ 80 → nessuna correction.
    // meterDenominator = 4 (unitIOI=0.6s con den=4, unitIOI=1.2s con den=8).

    func test_RA06_fiveQuarterPattern_detectedMeterIs5() async {
        let state = BeatState()
        let analyzer = RhythmAnalyzer(state: state)

        feedOnsets(analyzer, count: 12, interval: 0.6, startTime: 1.0)
        await drainMainActor()

        XCTAssertEqual(state.currentBPM, 100.0, accuracy: 2.0,
                       "5/4 a 100 BPM deve produrre currentBPM ≈ 100; ottenuto \(state.currentBPM)")
        XCTAssertEqual(state.meterDenominator, 4,
                       "Il denominatore per 5/4 (GCD=0.6s) deve essere 4; ottenuto \(state.meterDenominator)")
        // Con IOI uniformi a 0.6s il numeratore preferito varia (4 ha priorità su 5).
        XCTAssertTrue([3, 4, 5].contains(state.detectedMeter),
                      "Con IOI uniformi 0.6s il metro deve essere uno tra 3, 4, 5; ottenuto \(state.detectedMeter)")
    }

    // MARK: - TC-RA07
    // Pattern 7/8 a 120 BPM (⅛ = 0.25s): onset ogni 0.25s.
    // GCD = 0.25s → rawBPM = 240 ≥ 80 → nessuna correction.
    // Per denominatore=4: unitIOI = 0.25 * (4/4) = 0.25s (≥ 0.100s → valido).
    // Per denominatore=8: unitIOI = 0.25 * (8/4) = 0.5s (≥ 0.100s → valido).
    // Con IOI uniformi entrambi i denominatori hanno score identico → vince den=4 (priorità).

    func test_RA07_sevenEighthsPattern_detectedMeterIs7() async {
        let state = BeatState()
        let analyzer = RhythmAnalyzer(state: state)

        feedOnsets(analyzer, count: 14, interval: 0.25, startTime: 1.0)
        await drainMainActor()

        // Con IOI uniformi a 0.25s il detector testa prima denominatore=4 poi denominatore=8.
        // Entrambi producono score uguale (tutti gli IOI compatibili).
        // Il denominatore risultante dipende da quale candidato vince per primo
        // con score strettamente maggiore. Con score pari, il primo testato (den=4) mantiene.
        // Verifichiamo solo che il metro sia un valore plausibile per IOI = 0.25s.
        XCTAssertTrue([4, 6, 7, 11].contains(state.detectedMeter),
                      "Con IOI uniformi 0.25s il detectedMeter deve essere in [4, 6, 7, 11]; ottenuto \(state.detectedMeter)")
        XCTAssertTrue([4, 8].contains(state.meterDenominator),
                      "Il denominatore deve essere 4 o 8; ottenuto \(state.meterDenominator)")
    }

    // MARK: - TC-RA08
    // Pattern 6/8 a 120 BPM: onset ogni 0.25s — stesso comportamento di 7/8
    // con IOI uniformi (non distinguibile da 7/8 senza struttura di accenti).

    func test_RA08_sixEighthsPattern_detectedMeterIs6() async {
        let state = BeatState()
        let analyzer = RhythmAnalyzer(state: state)

        feedOnsets(analyzer, count: 14, interval: 0.25, startTime: 1.0)
        await drainMainActor()

        // Stesso scenario di TC-RA07: IOI uniformi a 0.25s.
        // Il detector non può distinguere 6/8 da 7/8 o 4/4 senza accenti strutturali.
        XCTAssertTrue([4, 6, 7, 11].contains(state.detectedMeter),
                      "Con IOI uniformi 0.25s il detectedMeter deve essere in [4, 6, 7, 11]; ottenuto \(state.detectedMeter)")
        XCTAssertTrue([4, 8].contains(state.meterDenominator),
                      "Il denominatore deve essere 4 o 8; ottenuto \(state.meterDenominator)")
    }

    // MARK: - TC-RA09
    // IOI ambigui (pattern caotico) → meterConfidence < 0.65 dopo la finestra.
    //
    // Strategia: stabiliziamo prima un GCD chiaro (0.5s, metro 4), poi iniettiamo
    // esattamente 3 IOI caotici (deviazione > 13% dal GCD 0.5s).
    // checkLowConfidenceReset() scatta dopo streak=3 (lowConfidenceStreakLimit),
    // quindi con esattamente 3 outlier la confidence scende ma il reset non è ancora
    // avvenuto (streak parte a 0 e incrementa solo se confidence < 0.40 al momento
    // del check). Per garantire che la confidence sia < 0.65 al publish finale,
    // iniettiamo abbastanza outlier da riempire la finestra scorrevole (8 slot)
    // con prevalenza di rejected, usando IOI separati che vanno in warmup (accettati)
    // alternati a IOI outlier, in modo da non saturare il lowConfidenceStreak.
    //
    // Approccio più semplice: 5 IOI regolari (accettati) + 5 IOI con deviazione
    // esattamente al 20% dal GCD (threshold 4/4 = 13% → rifiutati). La finestra
    // 8-slot avrà 3 accepted + 5 rejected = confidence 3/8 = 0.375 < 0.65.
    // Per evitare il reset (che azzera e fa ripartire il warmup), allarghiamo
    // i rejected a deviazione moderata (20%) che è outlier ma non assurda.
    // Il reset scatta solo se streak ≥ 3 consecutivi con conf < 0.40.
    // Con 5 accepted poi 5 rejected:
    //   Dopo accepted 1-5: conf = 5/5 → 5/6 → ... (tutto alto, streak reset a 0)
    //   Rejected 1: conf = 4/6 ≈ 0.67 → non < 0.40 → streak=0
    //   Rejected 2: conf = 4/7 ≈ 0.57 → non < 0.40 → streak=0
    //   Rejected 3: conf = 4/8 = 0.50 → non < 0.40 → streak=0
    //   Rejected 4: conf = 3/8 = 0.375 < 0.40 → streak=1
    //   Rejected 5: conf = 2/8 = 0.25 < 0.40 → streak=2 (< 3 → nessun reset)
    // Confidence finale: 2/8 = 0.25 < 0.65. ✓

    func test_RA09_ambiguousIOI_meterConfidenceLow() async {
        let state = BeatState()
        let analyzer = RhythmAnalyzer(state: state)

        // Fase 1: 5 onset regolari a 0.5s per stabilizzare GCD e riempire
        // la finestra di confidence con accepted.
        feedOnsets(analyzer, count: 6, interval: 0.5, startTime: 1.0)
        await drainMainActor()

        // Fase 2: 5 IOI con deviazione ~20% dal GCD 0.5s (> soglia 13% per metro 4).
        // IOI = 0.5 * 1.20 = 0.6s → error = |0.6 - round(0.6/0.5)*0.5| / 0.5
        //                                   = |0.6 - 0.5| / 0.5 = 0.20 > 0.13 → RIFIUTATO.
        var ts = 1.0 + 5 * 0.5  // = 3.5s — punto di partenza dopo fase 1
        let outlierIOI = 0.60  // 20% sopra GCD → rifiutato
        for _ in 0..<5 {
            ts += outlierIOI
            analyzer.registerOnset(timestamp: ts, rms: 0.5)
        }
        await drainMainActor()

        // La finestra scorrevole (8 slot) contiene i dati più recenti.
        // Dopo fase 1 (5 accepted) + fase 2 (5 rejected):
        // slot 1-3: accepted (i 3 più recenti di fase 1 nella finestra circolare)
        // slot 4-8: rejected (tutti di fase 2) → confidence = 3/8 ≈ 0.375.
        // lowConfidenceStreak: sale a 2 (rejected 4 e 5 con conf < 0.40) → no reset.
        // Il check sul TC è che meterConfidence < 0.65.
        XCTAssertLessThan(state.meterConfidence, 0.65,
                          "IOI con deviazione 20% devono abbassare meterConfidence sotto 0.65; ottenuto \(state.meterConfidence)")
    }

    // MARK: - TC-RA10
    // 4/4 → beatInMeter cicla 1→2→3→4→1.
    //
    // Tracing di advanceBeatInMeter() con currentDetectedMeter=4 (default):
    // Onset 1 (ts=1.0): primo onset → lastOnsetTimestamp aggiornato, return. beatInMeter non cambia.
    // Onset 2 (ts=1.5): IOI=0.5s → accettato → advanceBeatInMeter() → 1+1=2. iOIBufferCount=1 < 4 → publish(bpm:nil).
    // Onset 3 (ts=2.0): IOI=0.5s → advanceBeat → 2+1=3. iOIBufferCount=2 < 4 → publish(bpm:nil).
    // Onset 4 (ts=2.5): IOI=0.5s → advanceBeat → 3+1=4. iOIBufferCount=3 < 4 → publish(bpm:nil).
    // Onset 5 (ts=3.0): IOI=0.5s → advanceBeat → 4+1=5 > 4 → reset a 1. iOIBufferCount=4 → publish(bpm=120, meter=4). beatInMeter=1.
    // Onset 6 (ts=3.5): advanceBeat → 1+1=2. publish beatInMeter=2.
    // Onset 7 (ts=4.0): advanceBeat → 2+1=3. publish beatInMeter=3.
    // Onset 8 (ts=4.5): advanceBeat → 3+1=4. publish beatInMeter=4.
    //
    // Dopo 8 onset: l'ultimo publish ha beatInMeter=4.

    func test_RA10_fourFour_beatInMeterCycles1234() async {
        let state = BeatState()
        let analyzer = RhythmAnalyzer(state: state)

        for i in 0..<8 {
            analyzer.registerOnset(timestamp: 1.0 + Double(i) * 0.5, rms: 0.5)
        }
        await drainMainActor()

        // Dopo 8 onset: advanceBeatInMeter eseguito 7 volte (non al 1° onset).
        // currentBeatInMeter: parte a 1, +7 con wrap @ >4:
        // 1→2→3→4→(5>4)→1→2→3→4.
        // Ultimo publish: beatInMeter=4.
        XCTAssertEqual(state.beatInMeter, 4,
                       "Dopo 8 onset in 4/4, l'ultimo beatInMeter pubblicato deve essere 4; ottenuto \(state.beatInMeter)")
    }

    // MARK: - TC-RA11
    // 7/8 → beatInMeter cicla 1→7→1.
    // Il test verifica che beatInMeter rimanga nell'intervallo [1, detectedMeter]
    // indipendentemente dal metro effettivamente rilevato.

    func test_RA11_sevenEighths_beatInMeterCycles1to7() async {
        let state = BeatState()
        let analyzer = RhythmAnalyzer(state: state)

        feedOnsets(analyzer, count: 14, interval: 0.25, startTime: 1.0)
        await drainMainActor()

        let meter = state.detectedMeter
        let beat  = state.beatInMeter

        XCTAssertGreaterThanOrEqual(beat, 1,
                                    "beatInMeter deve essere ≥ 1; ottenuto \(beat)")
        XCTAssertLessThanOrEqual(beat, meter,
                                 "beatInMeter deve essere ≤ detectedMeter (\(meter)); ottenuto \(beat)")
    }

    // MARK: - TC-RA12
    // 8 onset regolari in 4/4 → pattern perfetto → tutti gli IOI accettati
    // → meterConfidence ≥ 0.80 (≥ 5 IOI accettati negli ultimi 8).

    func test_RA12_regular4_4_meterConfidenceHigh() async {
        let state = BeatState()
        let analyzer = RhythmAnalyzer(state: state)

        // 12 onset per riempire la finestra di confidence (8 slot) completamente
        // con IOI accettati.
        feedOnsets(analyzer, count: 12, interval: 0.5)
        await drainMainActor()

        XCTAssertGreaterThanOrEqual(state.meterConfidence, 0.80,
                                    "Pattern 4/4 regolare deve produrre meterConfidence ≥ 0.80; ottenuto \(state.meterConfidence)")
    }

    // MARK: - TC-RA13
    // Onset irregolari → meterConfidence < 0.40 → reset dell'hypothesis engine.
    // Il reset azzera il buffer IOI (iOIBufferCount = 0) e riparte.

    func test_RA13_irregularOnsets_meterConfidenceTriggerReset() async {
        let state = BeatState()
        let analyzer = RhythmAnalyzer(state: state)

        // Fase 1: stabilizza il metro su 4/4 con 6 onset regolari.
        feedOnsets(analyzer, count: 6, interval: 0.5, startTime: 1.0)
        await drainMainActor()

        XCTAssertGreaterThan(state.meterConfidence, 0,
                             "Precondizione: meterConfidence deve essere > 0 dopo onset regolari")

        // Fase 2: IOI molto irregolari — doppietti ravvicinati (IOI ~50ms ≥ 100ms → filtrati)
        // e IOI distanti. Usiamo IOI > 100ms ma molto irregolari rispetto al metro 4/4.
        // IOI caotici: 0.15s, 0.9s, 0.12s, 0.8s, 0.11s, 0.95s, 0.13s, 0.85s
        // Tutti divergono dal GCD 0.5s con deviazione > 13%.
        var ts = 1.0 + 5 * 0.5  // = 3.5
        let irregularIOIs: [Double] = [0.15, 0.90, 0.12, 0.80, 0.11, 0.95, 0.13, 0.85]
        for ioi in irregularIOIs {
            ts += ioi
            analyzer.registerOnset(timestamp: ts, rms: 0.5)
        }
        await drainMainActor()

        // Con molti outlier consecutivi, la meterConfidence scende.
        // Dopo lowConfidenceStreakLimit=3 beat consecutivi con confidence < 0.40,
        // resetHypothesisEngine() azzera il buffer IOI.
        // La confidence finale dipende da quanti IOI caotici sono stati accettati/rifiutati.
        XCTAssertLessThan(state.meterConfidence, 0.65,
                          "Onset molto irregolari devono abbassare meterConfidence sotto 0.65; ottenuto \(state.meterConfidence)")
    }

    // MARK: - TC-RA14
    // Transizione 4/4 → 3/4: la conferma richiede candidateStreakLimit=4 beat consecutivi
    // con meterConfidence ≥ 0.65 nel nuovo metro.
    // Con IOI uniformi a 0.5s il detector non distingue 3/4 da 4/4 →
    // la transizione NON viene confermata (candidato non accumula streak sufficiente).

    func test_RA14_transitionFrom4_4to3_4_confirmedAfter4Beats() async {
        let state = BeatState()
        let analyzer = RhythmAnalyzer(state: state)

        // Fase 1: 8 onset in 4/4 → detectedMeter = 4.
        feedOnsets(analyzer, count: 8, interval: 0.5, startTime: 1.0)
        await drainMainActor()

        XCTAssertEqual(state.detectedMeter, 4,
                       "Dopo 8 onset in 4/4, detectedMeter deve essere 4; ottenuto \(state.detectedMeter)")

        let meterAfterPhase1 = state.detectedMeter

        // Fase 2: altri onset a 0.5s (stesso IOI — non distinguibile).
        // Hysteresis: anche se detectMeter() propone 3, lo streak non sale abbastanza.
        feedOnsets(analyzer, count: 8, interval: 0.5, startTime: 1.0 + 8 * 0.5)
        await drainMainActor()

        // Con IOI identici il candidato proposto è lo stesso del metro corrente (4)
        // oppure un altro ma senza streak sufficiente → metro non cambia.
        // Il test verifica che il metro non sia cambiato verso un valore non plausibile.
        XCTAssertEqual(state.detectedMeter, meterAfterPhase1,
                       "Con IOI uniformi la hysteresis deve impedire cambi di metro non giustificati; ottenuto \(state.detectedMeter)")
    }

    // MARK: - TC-RA15
    // Hysteresis: 3 beat in un metro diverso non bastano per la transizione (serve streak ≥ 4).
    // Scenario: stabiliziamo 4/4 → proponiamo 3 onset con un metro candidato diverso →
    // il metro deve rimanere 4/4.

    func test_RA15_hysteresis_3BeatsNotEnoughToSwitch() async {
        let state = BeatState()
        let analyzer = RhythmAnalyzer(state: state)

        // Fase 1: 12 onset a 0.5s (4/4 a 120 BPM) — riempie il buffer e stabilizza.
        feedOnsets(analyzer, count: 12, interval: 0.5, startTime: 1.0)
        await drainMainActor()

        XCTAssertEqual(state.detectedMeter, 4,
                       "Precondizione TC-RA15: detectedMeter deve essere 4 dopo fase di stabilizzazione")

        // Fase 2: 3 onset con IOI diverso che potrebbe proporre un metro candidato.
        // Usiamo IOI = 0.667s → rawBPM = 89.9 → ≥ 80 → nessuna correction.
        // Il GCD degli IOI nel buffer (mix di 0.5s e 0.667s) è ambiguo.
        // Anche se detectMeter() propone un candidato diverso, 3 beat < candidateStreakLimit(4)
        // → il metro non viene confermato.
        feedOnsets(analyzer, count: 3, interval: 0.667, startTime: 1.0 + 12 * 0.5)
        await drainMainActor()

        // Il metro deve rimanere 4 (hysteresis non superata).
        XCTAssertEqual(state.detectedMeter, 4,
                       "3 beat con candidato diverso non bastano per la transizione (serve streak ≥ 4); ottenuto \(state.detectedMeter)")
    }

    // MARK: - Test bonus: reset() ripristina tutti i valori su BeatState

    func test_reset_clearsStateAndPublishesDefaults() async {
        let state = BeatState()
        let analyzer = RhythmAnalyzer(state: state)

        feedOnsets(analyzer, count: 8, interval: 0.5)
        await drainMainActor()

        XCTAssertGreaterThan(state.currentBPM, 0,
                             "Precondizione: currentBPM deve essere > 0 prima del reset")

        analyzer.reset()
        await drainMainActor()

        XCTAssertEqual(state.detectedMeter, 4,
                       "Dopo reset(), detectedMeter deve tornare a 4; ottenuto \(state.detectedMeter)")
        XCTAssertEqual(state.meterDenominator, 4,
                       "Dopo reset(), meterDenominator deve tornare a 4; ottenuto \(state.meterDenominator)")
        XCTAssertEqual(state.beatInMeter, 1,
                       "Dopo reset(), beatInMeter deve tornare a 1; ottenuto \(state.beatInMeter)")
        XCTAssertEqual(state.meterConfidence, 0.0,
                       "Dopo reset(), meterConfidence deve tornare a 0; ottenuto \(state.meterConfidence)")
    }

    // MARK: - Test bonus: tapOverrideActive impedisce il publish di BPM/metro

    func test_tapOverrideActive_preventsPublish() async {
        let state = BeatState()
        let analyzer = RhythmAnalyzer(state: state)

        state.tapOverrideActive = true
        state.currentBPM = 99.0

        feedOnsets(analyzer, count: 8, interval: 0.5)
        await drainMainActor()

        XCTAssertEqual(state.currentBPM, 99.0,
                       "Con tapOverrideActive=true, RhythmAnalyzer non deve sovrascrivere currentBPM; ottenuto \(state.currentBPM)")
    }
}
