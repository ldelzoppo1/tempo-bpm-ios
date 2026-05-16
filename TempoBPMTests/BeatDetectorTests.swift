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
//
// Il clock è iniettato via MonotonicClock per evitare Thread.sleep — tutti i test
// che richiedono timing inter-onset usano clock avanzati manualmente.

final class BeatDetectorTests: XCTestCase {

    // MARK: - Helpers

    /// Orologio monotono controllabile per i test: avanza il tempo esplicitamente.
    /// Viene iniettato in BeatDetector(state:now:) per evitare Thread.sleep nei test.
    private final class MonotonicClock {
        private var time: Double
        init(start: Double = 0) { self.time = start }
        func advance(by seconds: Double) { time += seconds }
        func now() -> Double { time }
    }

    /// Genera un AVAudioPCMBuffer sintetico a 44100 Hz mono con ampiezza calibrata
    /// in modo che il suo RMS coincida con `targetRMS`.
    ///
    /// RMS di una sinusoide di ampiezza A è A / sqrt(2), quindi A = targetRMS * sqrt(2).
    private func makePCMBuffer(rms targetRMS: Float,
                               frameCount: AVAudioFrameCount = 2048) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]
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

    /// Esegue warm-up del detector con `count` buffer a RMS basso per stabilizzare
    /// la soglia adattiva. Avanza il clock di 1ms per buffer.
    private func warmUp(detector: BeatDetector,
                        clock: MonotonicClock,
                        count: Int = 10,
                        rms: Float = 0.03) {
        let buffer = makePCMBuffer(rms: rms)
        for _ in 0 ..< count {
            clock.advance(by: 0.001)
            detector.process(buffer: buffer)
        }
    }

    // MARK: - Test 1: Warm-up guard — buffer sotto soglia non scatena onset

    /// Con RMS = 0.0005 la soglia adattiva rimane sotto 0.001: la warm-up guard
    /// blocca il percorso di onset detection e currentBPM rimane 0.
    func test_warmUpGuard_bufferSottoSoglia_nonScatenaNessunOnset() {
        let state = BeatState()
        let clock = MonotonicClock()
        let detector = BeatDetector(state: state, now: clock.now)

        clock.advance(by: 0.001)
        detector.process(buffer: makePCMBuffer(rms: 0.0005))

        XCTAssertEqual(state.currentBPM, 0.0,
            "Con RMS = 0.0005 la soglia adattiva rimane < 0.001: nessun onset deve " +
            "essere rilevato e currentBPM deve rimanere 0")
    }

    // MARK: - Test 2: Onset rilevato sopra soglia — beatFlash diventa true

    /// Dopo warm-up a RMS = 0.05, iniettare buffer con RMS = 0.5 (>> soglia × 1.5).
    /// L'onset viene rilevato e state.beatFlash deve diventare true entro 150ms.
    func test_onsetDetection_bufferSoprasSoglia_beatFlashDiventaTrue() async {
        let state = BeatState()
        let clock = MonotonicClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector: detector, clock: clock, rms: 0.05)

        let expectation = XCTestExpectation(description: "beatFlash deve diventare true")

        // Polling sul main actor: 50 × 3ms = 150ms totali.
        let observationTask = Task { @MainActor in
            for _ in 0 ..< 50 {
                if state.beatFlash {
                    expectation.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 3_000_000)
            }
        }

        // Burst ad alta energia sopra la soglia.
        clock.advance(by: 0.5)
        detector.process(buffer: makePCMBuffer(rms: 0.5))

        await fulfillment(of: [expectation], timeout: 0.15)
        observationTask.cancel()

        // Non asserire state.beatFlash qui: il flag si resetta a false dopo 100ms.
        // La fulfillment dell'expectation è prova sufficiente che beatFlash era true.
    }

    // MARK: - Test 3: Periodo refrattario — secondo onset ravvicinato viene ignorato

    /// Due burst in successione immediata: il clock avanza di soli 0.001s tra i due,
    /// ben dentro il periodo refrattario di 0.2s. Solo il primo onset è registrato.
    /// Con un solo onset non ci sono intervalli inter-onset → currentBPM rimane 0.
    func test_periodoRefrattario_dueOnsetRavvicinati_secondoIgnorato() async {
        let state = BeatState()
        let clock = MonotonicClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector: detector, clock: clock)

        let highBuffer = makePCMBuffer(rms: 0.5)

        clock.advance(by: 0.5)
        detector.process(buffer: highBuffer)

        clock.advance(by: 0.001)  // << 200ms refrattario
        detector.process(buffer: highBuffer)

        // Drain: attende che qualsiasi Task @MainActor pendente sia eseguito.
        let drain = XCTestExpectation(description: "drain main actor")
        Task { @MainActor in drain.fulfill() }
        await fulfillment(of: [drain], timeout: 0.2)

        XCTAssertEqual(state.currentBPM, 0.0,
            "Con due onset a 1ms di distanza solo il primo è registrato. " +
            "Senza un secondo onset valido non ci sono intervalli → BPM deve essere 0.")
    }

    // MARK: - Test 4: BPM calcolato correttamente a ~120 BPM

    /// Cinque burst con clock avanzato di 0.5s tra ognuno → 4 intervalli di 0.5s
    /// → BPM = 60 / 0.5 = 120. Nessun Thread.sleep: il timing è simulato dal clock.
    func test_bpmCalcolato_cinqueBurstA500ms_ritornaCirca120BPM() async {
        let state = BeatState()
        let clock = MonotonicClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector: detector, clock: clock)

        let burstBuffer = makePCMBuffer(rms: 0.5)
        for _ in 0 ..< 5 {
            clock.advance(by: 0.5)
            detector.process(buffer: burstBuffer)
        }

        // Attende propagazione su @MainActor.
        let bpmExpectation = XCTestExpectation(description: "currentBPM > 0 dopo 5 burst")
        let observationTask = Task { @MainActor in
            for _ in 0 ..< 60 {
                if state.currentBPM > 0 {
                    bpmExpectation.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        await fulfillment(of: [bpmExpectation], timeout: 0.5)
        observationTask.cancel()

        XCTAssertEqual(state.currentBPM, 120.0, accuracy: 1.0,
            "5 burst a 500ms (clock simulato) devono produrre BPM = 120 ±1, " +
            "ma il valore ottenuto è \(state.currentBPM)")
    }

    // MARK: - Test 5: Filtro BPM fuori range

    /// Caso A — 0.1s = 600 BPM > 220: scartato.
    /// Caso B — 2.1s = ~28.6 BPM < 40: scartato.
    /// Nessun Thread.sleep: il clock simula i timing.
    func test_bpmFuoriRange_600BPMe30BPM_vieneScartato() async {
        // --- Caso A: BPM > 220 (intervallo 0.1s) ---
        let stateA = BeatState()
        let clockA = MonotonicClock()
        let detectorA = BeatDetector(state: stateA, now: clockA.now)

        warmUp(detector: detectorA, clock: clockA)

        let burstA = makePCMBuffer(rms: 0.5)
        clockA.advance(by: 0.5)
        detectorA.process(buffer: burstA)
        clockA.advance(by: 0.1)  // 600 BPM — fuori range
        detectorA.process(buffer: burstA)

        let drainA = XCTestExpectation(description: "drain A")
        Task { @MainActor in drainA.fulfill() }
        await fulfillment(of: [drainA], timeout: 0.2)

        XCTAssertEqual(stateA.currentBPM, 0.0,
            "BPM di 600 (intervallo 0.1s) è fuori [40,220] e deve essere scartato. " +
            "currentBPM deve rimanere 0, ma è \(stateA.currentBPM)")

        // --- Caso B: BPM < 40 (intervallo 2.1s = ~28.6 BPM) ---
        let stateB = BeatState()
        let clockB = MonotonicClock()
        let detectorB = BeatDetector(state: stateB, now: clockB.now)

        warmUp(detector: detectorB, clock: clockB)

        let burstB = makePCMBuffer(rms: 0.5)
        clockB.advance(by: 0.5)
        detectorB.process(buffer: burstB)
        clockB.advance(by: 2.1)  // ~28.6 BPM — fuori range
        detectorB.process(buffer: burstB)

        let drainB = XCTestExpectation(description: "drain B")
        Task { @MainActor in drainB.fulfill() }
        await fulfillment(of: [drainB], timeout: 0.2)

        XCTAssertEqual(stateB.currentBPM, 0.0,
            "BPM di ~28.6 (intervallo 2.1s) è fuori [40,220] e deve essere scartato. " +
            "currentBPM deve rimanere 0, ma è \(stateB.currentBPM)")
    }

    // MARK: - Test 6: tapOverrideActive impedisce aggiornamento di currentBPM

    /// Con state.tapOverrideActive = true, publishBeatState() salta l'update di currentBPM.
    func test_tapOverrideActive_onsetValidi_currentBPMNonVieneScritto() async {
        let state = BeatState()
        let clock = MonotonicClock()
        let detector = BeatDetector(state: state, now: clock.now)

        state.tapOverrideActive = true

        warmUp(detector: detector, clock: clock)

        let burstBuffer = makePCMBuffer(rms: 0.5)
        for _ in 0 ..< 5 {
            clock.advance(by: 0.5)
            detector.process(buffer: burstBuffer)
        }

        let drain = XCTestExpectation(description: "drain main actor con tapOverride")
        Task { @MainActor in drain.fulfill() }
        await fulfillment(of: [drain], timeout: 0.3)

        XCTAssertEqual(state.currentBPM, 0.0,
            "Con tapOverrideActive = true, BeatDetector non deve scrivere currentBPM. " +
            "Il valore deve rimanere 0, ma è \(state.currentBPM)")
    }

    // MARK: - Test 7: reset() azzera BeatState completamente

    /// Dopo onset validi e BPM > 0, reset() deve azzerare tutti i campi BeatState.
    func test_reset_dopoBPMValido_azzeraBeatState() async {
        let state = BeatState()
        let clock = MonotonicClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector: detector, clock: clock)

        let burstBuffer = makePCMBuffer(rms: 0.5)
        for _ in 0 ..< 5 {
            clock.advance(by: 0.5)
            detector.process(buffer: burstBuffer)
        }

        // Attende che BPM sia > 0.
        let bpmPositive = XCTestExpectation(description: "currentBPM > 0 prima del reset")
        let waitTask = Task { @MainActor in
            for _ in 0 ..< 60 {
                if state.currentBPM > 0 { bpmPositive.fulfill(); return }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        await fulfillment(of: [bpmPositive], timeout: 0.5)
        waitTask.cancel()

        XCTAssertGreaterThan(state.currentBPM, 0,
            "Precondizione: currentBPM deve essere > 0 prima di testare reset()")

        detector.reset()

        // Polling: attende che tutti i campi siano azzerati.
        let resetDone = XCTestExpectation(description: "BeatState azzerato da reset()")
        let resetTask = Task { @MainActor in
            for _ in 0 ..< 60 {
                if state.currentBPM == 0 && state.recentBPMs.isEmpty && state.stability == 0 {
                    resetDone.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        await fulfillment(of: [resetDone], timeout: 0.5)
        resetTask.cancel()

        XCTAssertEqual(state.currentBPM, 0.0,
            "Dopo reset(), currentBPM deve essere 0, ma è \(state.currentBPM)")
        XCTAssertTrue(state.recentBPMs.isEmpty,
            "Dopo reset(), recentBPMs deve essere vuoto, ma contiene \(state.recentBPMs.count) elementi")
        XCTAssertEqual(state.stability, 0.0,
            "Dopo reset(), stability deve essere 0, ma è \(state.stability)")
    }

    // MARK: - Test 8: EMA converge verso il valore target

    /// 46 buffer con RMS = 0.1: la soglia adattiva converge entro 1% di 0.1.
    /// Test sincrono: currentThreshold è aggiornato direttamente da process().
    func test_ema_quarantaseiBufferARMS01_sogliaConvergeVerso01() {
        let state = BeatState()
        let clock = MonotonicClock()
        let detector = BeatDetector(state: state, now: clock.now)

        let buffer = makePCMBuffer(rms: 0.1)

        // 46 applicazioni EMA: dopo 46 frame soglia ≈ 0.1 * (1 - 0.9^46) ≈ 0.0991.
        for _ in 0 ..< 46 {
            clock.advance(by: 0.001)
            detector.process(buffer: buffer)
        }

        let threshold = detector.currentThreshold

        XCTAssertEqual(Double(threshold), 0.1, accuracy: 0.001,
            "Dopo 46 iterazioni EMA con RMS = 0.1, la soglia deve essere entro 1% di 0.1. " +
            "Valore atteso ≈ 0.099, valore ottenuto: \(threshold)")
        XCTAssertGreaterThan(threshold, 0.0,
            "La soglia adattiva deve essere > 0 dopo 46 buffer non silenziosi")
        XCTAssertLessThanOrEqual(Double(threshold), 0.1 + 0.001,
            "La soglia EMA non deve superare il valore target 0.1 (±0.001)")
    }

    // MARK: - Test aggiuntivo: buffer silenzioso

    /// Buffer di silenzio: soglia rimane 0, nessun onset.
    func test_rms_bufferSilenzioso_nessunOnset() {
        let state = BeatState()
        let clock = MonotonicClock()
        let detector = BeatDetector(state: state, now: clock.now)

        for _ in 0 ..< 10 {
            clock.advance(by: 0.001)
            detector.process(buffer: makeSilentBuffer())
        }

        XCTAssertEqual(state.currentBPM, 0.0,
            "Buffer silenziosi non devono scatenare onset: currentBPM deve rimanere 0")
        XCTAssertEqual(detector.currentThreshold, 0.0,
            "Con buffer silenziosi (RMS = 0), soglia EMA = 0 * 0.9 + 0 * 0.1 = 0")
    }

    // MARK: - Test aggiuntivo: soglia positiva dopo buffer non silenzioso

    /// Il primo buffer non silenzioso inizializza la soglia a RMS esattamente.
    func test_rms_bufferConAmpiezzaNota_sogliaDiventaPositiva() {
        let state = BeatState()
        let clock = MonotonicClock()
        let detector = BeatDetector(state: state, now: clock.now)

        clock.advance(by: 0.001)
        detector.process(buffer: makePCMBuffer(rms: 0.1))

        XCTAssertGreaterThan(detector.currentThreshold, 0.0,
            "Dopo un buffer con RMS = 0.1, la soglia deve essere > 0. " +
            "Valore: \(detector.currentThreshold)")
        XCTAssertEqual(Double(detector.currentThreshold), 0.1, accuracy: 0.001,
            "Al primo frame la soglia viene inizializzata direttamente a RMS = 0.1. " +
            "Valore: \(detector.currentThreshold)")
    }

    // MARK: - Test NC-4: stability 0 con meno di 2 onset registrati

    /// Con meno di 2 onset validi, computeStability() restituisce 0
    /// e state.stability rimane 0.
    func test_stability_menodiDueOnset_ritornaZero() async {
        let state = BeatState()
        let clock = MonotonicClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector: detector, clock: clock)

        // Un solo onset: non ci sono intervalli → nessun BPM pubblicato → stability = 0.
        clock.advance(by: 0.5)
        detector.process(buffer: makePCMBuffer(rms: 0.5))

        let drain = XCTestExpectation(description: "drain main actor")
        Task { @MainActor in drain.fulfill() }
        await fulfillment(of: [drain], timeout: 0.2)

        XCTAssertEqual(state.stability, 0.0,
            "Con un solo onset (nessun inter-onset interval), stability deve essere 0. " +
            "Valore: \(state.stability)")
        XCTAssertEqual(state.currentBPM, 0.0,
            "Con un solo onset, currentBPM deve rimanere 0. " +
            "Valore: \(state.currentBPM)")
    }
}
