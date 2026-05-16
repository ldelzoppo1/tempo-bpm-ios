import XCTest
import AVFoundation
import Accelerate
@testable import TempoBPM

// TBD-41: Test suite completa per BeatDetector (epica TBD-2)
//
// Ogni test è deterministico e non dipende da hardware reale (microfono).
// BeatDetector.process(buffer:) è sincrono; la pubblicazione su BeatState avviene
// via Task { @MainActor in ... }, quindi i test asincroni usano XCTestExpectation +
// await fulfillment(of:timeout:) per attendere la propagazione sul main actor.

final class BeatDetectorTests: XCTestCase {

    // MARK: - Helpers

    /// Genera un AVAudioPCMBuffer sintetico a 44100 Hz mono con ampiezza calibrata
    /// in modo che il suo RMS coincida con `targetRMS`.
    ///
    /// RMS di una sinusoide di ampiezza A è A / sqrt(2), quindi:
    ///   A = targetRMS * sqrt(2)
    private func makePCMBuffer(rms targetRMS: Float,
                               frameCount: AVAudioFrameCount = 2048) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]
        // Ampiezza: A = targetRMS * sqrt(2) per ottenere RMS = targetRMS esattamente.
        let amplitude = targetRMS * sqrt(2.0)
        for i in 0 ..< Int(frameCount) {
            data[i] = amplitude * sin(2 * .pi * 440 * Float(i) / 44100)
        }
        return buffer
    }

    /// Genera un buffer di silenzio (tutti i campioni a 0).
    private func makeSilentBuffer(frameCount: AVAudioFrameCount = 2048) -> AVAudioPCMBuffer {
        return makePCMBuffer(rms: 0.0, frameCount: frameCount)
    }

    // MARK: - Test 1: Warm-up guard — buffer sotto soglia non scatena onset

    /// Processare un buffer con RMS molto basso (0.0005) non deve superare la soglia
    /// adattiva e quindi non deve aggiornare state.currentBPM.
    ///
    /// La guard `adaptiveThreshold > 0.001` impedisce onset durante il warm-up.
    /// Con RMS = 0.0005 il primo frame imposta adaptiveThreshold = 0.0005 < 0.001,
    /// quindi il processo si ferma prima di raggiungere l'onset detection.
    func test_warmUpGuard_bufferSottoSoglia_nonScatenaNessunOnset() {
        let state = BeatState()
        let detector = BeatDetector(state: state)

        let buffer = makePCMBuffer(rms: 0.0005)
        detector.process(buffer: buffer)

        XCTAssertEqual(state.currentBPM, 0.0,
            "Con RMS = 0.0005 la soglia adattiva rimane sotto 0.001: nessun onset deve " +
            "essere rilevato e currentBPM deve rimanere 0")
    }

    // MARK: - Test 2: Onset rilevato sopra soglia — beatFlash diventa true

    /// Dopo 5 buffer di warm-up a RMS = 0.05 (che portano la soglia a ~0.046),
    /// iniettare un buffer con RMS = 0.5 (>> soglia × 1.5 ≈ 0.069).
    /// L'onset viene rilevato e state.beatFlash deve diventare true entro 150ms.
    ///
    /// Nota: beatFlash rimane true per 100ms, poi torna false. L'expectation deve
    /// essere soddisfatta entro i primi 100ms. Il timeout di 150ms garantisce margine.
    func test_onsetDetection_bufferSoprasSoglia_beatFlashDiventaTrue() async {
        let state = BeatState()
        let detector = BeatDetector(state: state)

        // Warm-up: 5 buffer a RMS = 0.05 per portare la soglia adattiva a ~0.046.
        // Dopo 5 buffer: soglia ≈ 0.05 * (1 - 0.9^5) ≈ 0.041; onset richiede > 0.041 * 1.5 ≈ 0.062.
        let warmupBuffer = makePCMBuffer(rms: 0.05)
        for _ in 0 ..< 5 {
            detector.process(buffer: warmupBuffer)
        }

        let expectation = XCTestExpectation(description: "beatFlash deve diventare true dopo onset sopra soglia")

        // Osserva beatFlash: non c'è KVO su @Observable, quindi usiamo un task
        // che monitora la proprietà con polling minimale sul main actor.
        let observationTask = Task { @MainActor in
            for _ in 0 ..< 50 {  // al massimo 50 iterazioni da 3ms = 150ms totali
                if state.beatFlash {
                    expectation.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 3_000_000)  // 3ms
            }
        }

        // Inietta il buffer ad alta energia (RMS = 0.5) che deve scatenare l'onset.
        let highEnergyBuffer = makePCMBuffer(rms: 0.5)
        detector.process(buffer: highEnergyBuffer)

        await fulfillment(of: [expectation], timeout: 0.15)
        observationTask.cancel()

        XCTAssertTrue(state.beatFlash,
            "beatFlash deve essere true dopo un onset rilevato con RMS >> soglia")
    }

    // MARK: - Test 3: Periodo refrattario — secondo onset ravvicinato viene ignorato

    /// Iniettare due onset con meno di 200ms di distanza: solo il primo deve essere
    /// registrato. Poiché è necessario almeno un inter-onset interval valido per
    /// calcolare un BPM (e almeno 2 intervals per computeCurrentBPM), con un solo
    /// onset registrato currentBPM rimane 0.
    ///
    /// Meccanismo: entrambe le chiamate a process() avvengono in successione sincrona,
    /// ben dentro i 200ms del periodo refrattario. Il secondo onset è bloccato dalla
    /// guard `now - lastOnsetTime >= refractoryPeriod`.
    func test_periodoRefrattario_dueOnsetRavvicinati_secondoIgnorato() async {
        let state = BeatState()
        let detector = BeatDetector(state: state)

        // Warm-up per portare la soglia a un valore significativo.
        let warmupBuffer = makePCMBuffer(rms: 0.05)
        for _ in 0 ..< 5 {
            detector.process(buffer: warmupBuffer)
        }

        // Inietta due buffer ad alta energia in successione sincrona (< 1ms tra i due).
        // Entrambe le chiamate avvengono sullo stesso thread, dunque il delta temporale
        // tra i due CFAbsoluteTimeGetCurrent() sarà << 200ms.
        let highBuffer = makePCMBuffer(rms: 0.5)
        detector.process(buffer: highBuffer)
        detector.process(buffer: highBuffer)

        // Attende che qualsiasi Task @MainActor pendente venga eseguito.
        let drainExpectation = XCTestExpectation(description: "drain main actor")
        Task { @MainActor in drainExpectation.fulfill() }
        await fulfillment(of: [drainExpectation], timeout: 0.2)

        // Con un solo onset valido non ci sono inter-onset intervals: currentBPM deve essere 0.
        XCTAssertEqual(state.currentBPM, 0.0,
            "Con due onset ravvicinati (< 200ms) solo il primo è registrato. " +
            "Non ci sono inter-onset intervals sufficienti per calcolare il BPM.")
    }

    // MARK: - Test 4: BPM calcolato correttamente a ~120 BPM

    /// Iniettare 5 burst di segnale ad alta energia separati da ~500ms reali.
    /// I 4 inter-onset intervals di ~0.5s producono BPM ≈ 120.
    /// Thread.sleep è ammesso qui perché simula intervalli inter-onset realistici,
    /// non serve per aspettare aggiornamenti asincroni di BeatState.
    func test_bpmCalcolato_cinqueBurstA500ms_ritornaCirca120BPM() async {
        let state = BeatState()
        let detector = BeatDetector(state: state)

        // Warm-up rapido con RMS basso-medio per stabilizzare la soglia adattiva
        // prima dei burst ad alta energia. 10 buffer a RMS = 0.03 portano la soglia
        // a ~0.027; i burst a RMS = 0.5 supereranno facilmente soglia × 1.5.
        let warmupBuffer = makePCMBuffer(rms: 0.03)
        for _ in 0 ..< 10 {
            detector.process(buffer: warmupBuffer)
        }

        // 5 burst a ~500ms di distanza → 4 intervals ≈ 0.5s → BPM ≈ 120.
        // Thread.sleep è accettabile solo qui per generare timing inter-onset realistico.
        let burstBuffer = makePCMBuffer(rms: 0.5)
        for _ in 0 ..< 5 {
            detector.process(buffer: burstBuffer)
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Attende propagazione su @MainActor.
        let bpmExpectation = XCTestExpectation(description: "currentBPM aggiornato dopo 5 burst")
        let observationTask = Task { @MainActor in
            for _ in 0 ..< 60 {  // al massimo 60 × 5ms = 300ms di attesa
                if state.currentBPM > 0 {
                    bpmExpectation.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000)  // 5ms
            }
        }

        await fulfillment(of: [bpmExpectation], timeout: 0.5)
        observationTask.cancel()

        XCTAssertEqual(state.currentBPM, 120.0, accuracy: 5.0,
            "5 burst a 500ms di distanza devono produrre BPM ≈ 120 (±5 BPM), " +
            "ma il valore ottenuto è \(state.currentBPM)")
    }

    // MARK: - Test 5: Filtro BPM fuori range

    /// Verificare che onset con intervalli che producono BPM < 40 o BPM > 220 vengano
    /// scartati e non aggiornino state.currentBPM.
    ///
    /// Caso A — 600 BPM (intervallo 0.1s): BPM > 220, viene filtrato.
    /// Caso B — 30 BPM (intervallo 2.0s): BPM < 40, viene filtrato.
    ///
    /// NOTA: questo test usa Thread.sleep per generare gli intervalli inter-onset
    /// necessari a testare i casi limite del filtro range. È l'unico modo deterministico
    /// per controllare il timing di CFAbsoluteTimeGetCurrent() interno a BeatDetector.
    func test_bpmFuoriRange_600BPMe30BPM_vieneScartato() async {
        // --- Caso A: BPM > 220 (intervallo ~0.1s = 600 BPM) ---
        let stateA = BeatState()
        let detectorA = BeatDetector(state: stateA)

        let warmupA = makePCMBuffer(rms: 0.03)
        for _ in 0 ..< 10 {
            detectorA.process(buffer: warmupA)
        }

        // Due burst a ~0.1s di distanza: 60 / 0.1 = 600 BPM > 220 → scartato.
        let burstA = makePCMBuffer(rms: 0.5)
        detectorA.process(buffer: burstA)
        Thread.sleep(forTimeInterval: 0.1)
        detectorA.process(buffer: burstA)

        // Drain main actor
        let drainA = XCTestExpectation(description: "drain A")
        Task { @MainActor in drainA.fulfill() }
        await fulfillment(of: [drainA], timeout: 0.2)

        XCTAssertEqual(stateA.currentBPM, 0.0,
            "BPM di 600 (intervallo 0.1s) è fuori range [40,220] e deve essere scartato. " +
            "currentBPM deve rimanere 0, ma è \(stateA.currentBPM)")

        // --- Caso B: BPM < 40 (intervallo ~2.0s = 30 BPM) ---
        let stateB = BeatState()
        let detectorB = BeatDetector(state: stateB)

        let warmupB = makePCMBuffer(rms: 0.03)
        for _ in 0 ..< 10 {
            detectorB.process(buffer: warmupB)
        }

        // Due burst a ~2.0s di distanza: 60 / 2.0 = 30 BPM < 40 → scartato.
        let burstB = makePCMBuffer(rms: 0.5)
        detectorB.process(buffer: burstB)
        Thread.sleep(forTimeInterval: 2.0)
        detectorB.process(buffer: burstB)

        // Drain main actor
        let drainB = XCTestExpectation(description: "drain B")
        Task { @MainActor in drainB.fulfill() }
        await fulfillment(of: [drainB], timeout: 0.2)

        XCTAssertEqual(stateB.currentBPM, 0.0,
            "BPM di 30 (intervallo 2.0s) è fuori range [40,220] e deve essere scartato. " +
            "currentBPM deve rimanere 0, ma è \(stateB.currentBPM)")
    }

    // MARK: - Test 6: tapOverrideActive impedisce aggiornamento di currentBPM

    /// Con state.tapOverrideActive = true, publishBeatState() deve saltare l'update
    /// di currentBPM (guard `!state.tapOverrideActive`). Anche dopo onset validi
    /// currentBPM rimane invariato.
    func test_tapOverrideActive_onsetValidi_currentBPMNonVieneScritto() async {
        let state = BeatState()
        let detector = BeatDetector(state: state)

        // Attiva tap override prima dei burst.
        state.tapOverrideActive = true

        // Warm-up per stabilizzare la soglia.
        let warmupBuffer = makePCMBuffer(rms: 0.03)
        for _ in 0 ..< 10 {
            detector.process(buffer: warmupBuffer)
        }

        // Genera onset multipli sufficienti a produrre un BPM valido in condizioni normali.
        let burstBuffer = makePCMBuffer(rms: 0.5)
        for _ in 0 ..< 5 {
            detector.process(buffer: burstBuffer)
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Attende propagazione su @MainActor.
        let drainExpectation = XCTestExpectation(description: "drain main actor con tapOverride")
        Task { @MainActor in drainExpectation.fulfill() }
        await fulfillment(of: [drainExpectation], timeout: 0.3)

        XCTAssertEqual(state.currentBPM, 0.0,
            "Con tapOverrideActive = true, BeatDetector non deve scrivere currentBPM. " +
            "Il valore deve rimanere 0, ma è \(state.currentBPM)")
    }

    // MARK: - Test 7: reset() azzera BeatState completamente

    /// Dopo aver prodotto onset validi e un BPM > 0, chiamare reset() deve azzerare
    /// tutti i campi rilevanti di BeatState: currentBPM, recentBPMs, stability.
    func test_reset_dopoBPMValido_azzeraBeatState() async {
        let state = BeatState()
        let detector = BeatDetector(state: state)

        // Porta il detector a uno stato con BPM valido.
        let warmupBuffer = makePCMBuffer(rms: 0.03)
        for _ in 0 ..< 10 {
            detector.process(buffer: warmupBuffer)
        }

        let burstBuffer = makePCMBuffer(rms: 0.5)
        for _ in 0 ..< 5 {
            detector.process(buffer: burstBuffer)
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Attende che BPM sia > 0.
        let bpmPositiveExpectation = XCTestExpectation(description: "currentBPM > 0 prima del reset")
        let waitTask = Task { @MainActor in
            for _ in 0 ..< 60 {
                if state.currentBPM > 0 {
                    bpmPositiveExpectation.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        await fulfillment(of: [bpmPositiveExpectation], timeout: 0.5)
        waitTask.cancel()

        // Precondizione: verifica che BPM sia effettivamente > 0 prima del reset.
        XCTAssertGreaterThan(state.currentBPM, 0,
            "Precondizione: currentBPM deve essere > 0 prima di testare reset()")

        // Esegue il reset.
        detector.reset()

        // Attende che il Task { @MainActor in ... } di reset() sia eseguito.
        let resetDrainExpectation = XCTestExpectation(description: "BeatState azzerato da reset()")
        let resetObservation = Task { @MainActor in
            for _ in 0 ..< 60 {
                if state.currentBPM == 0 && state.recentBPMs.isEmpty && state.stability == 0 {
                    resetDrainExpectation.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        await fulfillment(of: [resetDrainExpectation], timeout: 0.5)
        resetObservation.cancel()

        XCTAssertEqual(state.currentBPM, 0.0,
            "Dopo reset(), currentBPM deve essere 0, ma è \(state.currentBPM)")
        XCTAssertTrue(state.recentBPMs.isEmpty,
            "Dopo reset(), recentBPMs deve essere vuoto, ma contiene \(state.recentBPMs.count) elementi")
        XCTAssertEqual(state.stability, 0.0,
            "Dopo reset(), stability deve essere 0, ma è \(state.stability)")
    }

    // MARK: - Test 8: EMA converge verso il valore target

    /// Processare 30 buffer con RMS = 0.1 deve portare currentThreshold verso 0.1.
    /// Dopo n iterazioni: soglia_n = 0.1 * (1 - 0.9^n)
    /// Dopo 30 iterazioni: 0.1 * (1 - 0.9^30) ≈ 0.1 * (1 - 0.0424) ≈ 0.0958 (>95% del target).
    /// Dopo 46 iterazioni: 0.1 * (1 - 0.9^46) ≈ 0.0991 (entro 1% del target).
    ///
    /// Questo test è sincrono: non richiede async perché currentThreshold è aggiornato
    /// in modo sincrono da process(), senza passare per @MainActor.
    func test_ema_trentaBufferARMS01_sogliaConvergeVerso01() {
        let state = BeatState()
        let detector = BeatDetector(state: state)

        let buffer = makePCMBuffer(rms: 0.1)

        // Prima iterazione: soglia = rms (inizializzazione diretta quando adaptiveThreshold == 0).
        detector.process(buffer: buffer)

        // Iteriamo altre 45 volte per un totale di 46 applicazioni EMA.
        // Dopo 46 frames: soglia = 0.1 * (1 - 0.9^46) ≈ 0.0991 (entro 1% di 0.1).
        for _ in 0 ..< 45 {
            detector.process(buffer: buffer)
        }

        let threshold = detector.currentThreshold

        // Verifica convergenza: la soglia deve essere entro 1% del valore target (0.1).
        // Tolleranza assoluta: 0.1 * 0.01 = 0.001.
        XCTAssertEqual(Double(threshold), 0.1, accuracy: 0.001,
            "Dopo 46 iterazioni EMA con RMS = 0.1, la soglia adattiva deve convergere " +
            "entro 1% di 0.1. Valore atteso ≈ 0.099, valore ottenuto: \(threshold)")

        // Verifica che la soglia sia strettamente maggiore di 0 (nessuna regressione verso 0).
        XCTAssertGreaterThan(threshold, 0.0,
            "La soglia adattiva deve essere > 0 dopo 46 buffer non silenziosi")

        // Verifica che la soglia non abbia superato il valore target (EMA in avvicinamento monotono).
        XCTAssertLessThanOrEqual(Double(threshold), 0.1 + 0.001,
            "La soglia EMA non deve superare il valore target 0.1 (tolleranza ±0.001)")
    }

    // MARK: - Test aggiuntivo: RMS buffer silenzioso

    /// Processare un buffer di silenzio (tutti zero) deve produrre RMS = 0.
    /// La soglia adattiva si inizializza a 0 e non supera mai la warm-up guard (> 0.001),
    /// quindi nessun onset viene rilevato.
    func test_rms_bufferSilenzioso_nessunOnset() {
        let state = BeatState()
        let detector = BeatDetector(state: state)

        let silentBuffer = makeSilentBuffer()
        // Processa 10 buffer silenziosi.
        for _ in 0 ..< 10 {
            detector.process(buffer: silentBuffer)
        }

        XCTAssertEqual(state.currentBPM, 0.0,
            "Buffer silenziosi non devono scatenare onset: currentBPM deve rimanere 0")
        XCTAssertEqual(detector.currentThreshold, 0.0,
            "Con buffer silenziosi (RMS = 0), la soglia adattiva deve rimanere 0 " +
            "perché l'EMA parte da 0 e rms = 0: soglia = 0 + 0.1 * 0 = 0")
    }

    // MARK: - Test aggiuntivo: RMS buffer non silenzioso

    /// Processare un buffer con ampiezza nota deve produrre un currentThreshold > 0.
    /// Verifica la correttezza del calcolo RMS via vDSP_rmsqv usato internamente.
    func test_rms_bufferConAmpiezzaNota_sogliaDiventaPositiva() {
        let state = BeatState()
        let detector = BeatDetector(state: state)

        // RMS = 0.1: dopo il primo frame la soglia viene inizializzata a 0.1.
        let buffer = makePCMBuffer(rms: 0.1)
        detector.process(buffer: buffer)

        XCTAssertGreaterThan(detector.currentThreshold, 0.0,
            "Dopo un buffer con RMS = 0.1, la soglia adattiva deve essere > 0. " +
            "Valore attuale: \(detector.currentThreshold)")

        // La soglia al primo frame è uguale a RMS (inizializzazione diretta: adaptiveThreshold = rms).
        XCTAssertEqual(Double(detector.currentThreshold), 0.1, accuracy: 0.001,
            "Al primo frame la soglia adattiva viene impostata direttamente a RMS = 0.1. " +
            "Valore attuale: \(detector.currentThreshold)")
    }
}
