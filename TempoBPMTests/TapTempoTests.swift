import XCTest
@testable import TempoBPM

// TBD-62: Test suite completa per TapTempo (epica TBD-5)
//
// Tutti i test che richiedono timing usano un MonotonicClock iniettabile per
// evitare Thread.sleep. L'unica eccezione è testOverrideTimerDeactivatesAfter3Seconds,
// che deve attendere il Task.sleep interno non controllabile dal clock iniettato.
//
// Propagazione @MainActor: le scritture su BeatState avvengono via Task { @MainActor in ... }
// nel codice di produzione. I test asincroni usano XCTestExpectation con un Task di drain
// per attendere che il main actor abbia processato le scritture pendenti.

final class TapTempoTests: XCTestCase {

    // MARK: - Helpers

    /// Orologio monotono controllabile per i test: avanza il tempo esplicitamente.
    /// Viene iniettato in TapTempo(state:now:) per evitare Thread.sleep nei test.
    private final class MonotonicClock {
        private var time: Double = 0
        func advance(by seconds: Double) { time += seconds }
        func now() -> Double { time }
    }

    /// Attende che tutte le scritture pendenti su @MainActor siano state processate.
    /// Usa una XCTestExpectation che viene fulfillata da un Task sul MainActor — poiché
    /// i Task @MainActor si accodano in ordine FIFO, la fulfill arriva dopo tutti i Task
    /// precedentemente schedulati da registerTap() o reset().
    private func waitForMainActor() async {
        let exp = expectation(description: "drain main actor")
        Task { @MainActor in exp.fulfill() }
        await fulfillment(of: [exp], timeout: 1.0)
    }

    // MARK: - Test 1: Primo tap non produce BPM

    /// Un solo tap non ha intervalli da calcolare — nessun BPM viene prodotto.
    /// tapCount rimane 0 perché viene incrementato solo quando un BPM valido è calcolato.
    func testFirstTapDoesNotProduceBPM() async {
        let clock = MonotonicClock()
        let state = BeatState()
        let tap = TapTempo(state: state, now: clock.now)

        clock.advance(by: 1.0)
        tap.registerTap()

        await waitForMainActor()

        XCTAssertEqual(state.tapBPM, 0.0, accuracy: 0.01,
            "Il primo tap non ha intervalli: tapBPM deve rimanere 0, ma è \(state.tapBPM)")
        XCTAssertFalse(state.tapOverrideActive,
            "Il primo tap non deve attivare tapOverrideActive")
        XCTAssertEqual(state.tapCount, 0,
            "tapCount viene incrementato solo al calcolo di un BPM valido: deve essere 0, ma è \(state.tapCount)")
    }

    // MARK: - Test 2: Due tap a 500ms producono BPM 120

    /// Due tap distanziati di 500ms → intervallo = 0.5s → BPM = 60 / 0.5 = 120.
    /// tapOverrideActive diventa true e tapCount sale a 1.
    func testTwoTapsProduceCorrectBPM() async throws {
        let clock = MonotonicClock()
        let state = BeatState()
        let tap = TapTempo(state: state, now: clock.now)

        clock.advance(by: 1.0)
        tap.registerTap()

        clock.advance(by: 0.5)
        tap.registerTap()

        await waitForMainActor()

        XCTAssertEqual(state.tapBPM, 120.0, accuracy: 1.0,
            "Due tap a 500ms devono produrre BPM ≈ 120, ma è \(state.tapBPM)")
        XCTAssertTrue(state.tapOverrideActive,
            "tapOverrideActive deve essere true dopo un BPM valido")
        XCTAssertEqual(state.tapCount, 1,
            "tapCount deve essere 1 dopo il primo intervallo valido, ma è \(state.tapCount)")
    }

    // MARK: - Test 3: Tap dentro il periodo refrattario viene ignorato

    /// Il secondo tap arriva a soli 150ms dal primo (< 200ms di refrattario).
    /// Viene silenziosamente ignorato: tapCount e tapBPM rimangono a 0.
    func testRefractoryPeriodIgnoresTap() async {
        let clock = MonotonicClock()
        let state = BeatState()
        let tap = TapTempo(state: state, now: clock.now)

        clock.advance(by: 1.0)
        tap.registerTap()

        clock.advance(by: 0.15)   // 150ms < 200ms di refrattario
        tap.registerTap()

        await waitForMainActor()

        XCTAssertEqual(state.tapCount, 0,
            "Il secondo tap a 150ms rientra nel refrattario e deve essere ignorato: tapCount = 0, ma è \(state.tapCount)")
        XCTAssertEqual(state.tapBPM, 0.0, accuracy: 0.01,
            "Con il secondo tap ignorato non si produce BPM: tapBPM deve essere 0, ma è \(state.tapBPM)")
        XCTAssertFalse(state.tapOverrideActive,
            "tapOverrideActive deve rimanere false se nessun BPM è stato calcolato")
    }

    // MARK: - Test 4: BPM troppo basso (< 40) viene scartato

    /// Intervallo di 2.5s → BPM = 60 / 2.5 = 24, al di sotto del minimo di 40.
    /// Il valore viene scartato: tapBPM rimane 0 e tapOverrideActive rimane false.
    func testBPMBelowMinIsDiscarded() async {
        let clock = MonotonicClock()
        let state = BeatState()
        let tap = TapTempo(state: state, now: clock.now)

        clock.advance(by: 1.0)
        tap.registerTap()

        clock.advance(by: 2.5)    // 60 / 2.5 = 24 BPM < 40
        tap.registerTap()

        await waitForMainActor()

        XCTAssertEqual(state.tapBPM, 0.0, accuracy: 0.01,
            "BPM di 24 è sotto il minimo di 40: tapBPM deve rimanere 0, ma è \(state.tapBPM)")
        XCTAssertFalse(state.tapOverrideActive,
            "tapOverrideActive deve rimanere false se il BPM calcolato è fuori range")
    }

    // MARK: - Test 5: BPM troppo alto (> 220) viene scartato

    /// Intervallo di 0.201s supera il refrattario ma produce BPM = 60 / 0.201 ≈ 298,
    /// al di sopra del massimo di 220. Il valore viene scartato.
    func testBPMAboveMaxIsDiscarded() async {
        let clock = MonotonicClock()
        let state = BeatState()
        let tap = TapTempo(state: state, now: clock.now)

        clock.advance(by: 1.0)
        tap.registerTap()

        clock.advance(by: 0.201)  // supera il refrattario, 60 / 0.201 ≈ 298 BPM > 220
        tap.registerTap()

        await waitForMainActor()

        XCTAssertEqual(state.tapBPM, 0.0, accuracy: 0.01,
            "BPM ≈ 298 è sopra il massimo di 220: tapBPM deve rimanere 0, ma è \(state.tapBPM)")
        XCTAssertFalse(state.tapOverrideActive,
            "tapOverrideActive deve rimanere false se il BPM calcolato è fuori range")
    }

    // MARK: - Test 6: tapOverrideActive diventa true dopo tap valido

    /// Due tap validi sono sufficienti per attivare tapOverrideActive.
    func testOverrideActiveAfterValidTap() async {
        let clock = MonotonicClock()
        let state = BeatState()
        let tap = TapTempo(state: state, now: clock.now)

        clock.advance(by: 1.0)
        tap.registerTap()

        clock.advance(by: 0.5)    // 120 BPM — valido
        tap.registerTap()

        await waitForMainActor()

        XCTAssertTrue(state.tapOverrideActive,
            "tapOverrideActive deve essere true dopo due tap validi a 500ms")
    }

    // MARK: - Test 7: Timer di override si disattiva dopo ~3s (attesa reale)

    /// NOTA: il Task.sleep interno a TapTempo non è controllabile tramite il clock
    /// iniettato. Questo test usa XCTestExpectation con attesa reale — è la sola
    /// eccezione accettata all'uso di attese reali nell'intera suite TapTempo.
    ///
    /// Verifica che, dopo 3s senza nuovi tap, tapOverrideActive torni false
    /// e tapBPM sia azzerato.
    func testOverrideTimerDeactivatesAfter3Seconds() async throws {
        let clock = MonotonicClock()
        let state = BeatState()
        let tap = TapTempo(state: state, now: clock.now)

        // Produce un BPM valido per attivare tapOverrideActive.
        clock.advance(by: 1.0)
        tap.registerTap()
        clock.advance(by: 0.5)
        tap.registerTap()

        // Attende che tapOverrideActive diventi true (propagazione @MainActor).
        let activeExp = XCTestExpectation(description: "tapOverrideActive diventa true")
        let pollActive = Task {
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
                if await MainActor.run(body: { state.tapOverrideActive }) {
                    activeExp.fulfill()
                    return
                }
            }
        }
        await fulfillment(of: [activeExp], timeout: 2.0)
        pollActive.cancel()

        // Attende che il timer di 3s interno scada e tapOverrideActive torni false.
        let deactiveExp = XCTestExpectation(description: "tapOverrideActive torna false dopo timeout")
        let pollDeactive = Task {
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                if await MainActor.run(body: { !state.tapOverrideActive }) {
                    deactiveExp.fulfill()
                    return
                }
            }
        }
        await fulfillment(of: [deactiveExp], timeout: 4.0)
        pollDeactive.cancel()

        let finalBPM = await MainActor.run { state.tapBPM }
        XCTAssertEqual(finalBPM, 0.0, accuracy: 0.01,
            "Dopo il timeout di 3s, tapBPM deve essere azzerato a 0, ma è \(finalBPM)")
        let overrideActive = await MainActor.run { state.tapOverrideActive }
        XCTAssertFalse(overrideActive,
            "Dopo il timeout di 3s, tapOverrideActive deve essere false")
    }

    // MARK: - Test 8: Pausa > resetPauseS azzera la sequenza

    /// Una pausa di 3.0s (> resetPauseS = 2.0s) tra il primo e il secondo tap
    /// fa sì che il secondo tap venga trattato come primo di una nuova sequenza:
    /// nessun intervallo calcolabile, tapBPM rimane 0.
    func testSequenceResetAfterLongPause() async {
        let clock = MonotonicClock()
        let state = BeatState()
        let tap = TapTempo(state: state, now: clock.now)

        clock.advance(by: 1.0)
        tap.registerTap()

        clock.advance(by: 3.0)    // > 2.0s di resetPauseS → reset della sequenza
        tap.registerTap()

        await waitForMainActor()

        XCTAssertEqual(state.tapBPM, 0.0, accuracy: 0.01,
            "Dopo una pausa di 3s la sequenza si azzera: il secondo tap è trattato come il primo, tapBPM deve essere 0, ma è \(state.tapBPM)")
        XCTAssertEqual(state.tapCount, 0,
            "tapCount deve essere 0 dopo il reset della sequenza, ma è \(state.tapCount)")
    }

    // MARK: - Test 9: Rolling window — media corretta su 5 tap

    /// 5 tap con intervallo di 0.501s ciascuno: il BPM atteso è 60 / 0.501 ≈ 119.7.
    /// L'intervallo supera il refrattario (> 0.2s) ed è nel range valido [40, 220].
    /// La media degli intervalli nella finestra scorrevole deve restituire un BPM
    /// tra 118 e 122.
    func testRollingWindowAveragesBPM() async {
        let clock = MonotonicClock()
        let state = BeatState()
        let tap = TapTempo(state: state, now: clock.now)

        clock.advance(by: 1.0)
        tap.registerTap()

        for _ in 0..<4 {
            clock.advance(by: 0.501)  // 60 / 0.501 ≈ 119.76 BPM
            tap.registerTap()
        }

        await waitForMainActor()

        XCTAssertEqual(state.tapBPM, 119.76, accuracy: 2.0,
            "4 intervalli da 0.501s devono produrre BPM ≈ 119.76 (±2), ma è \(state.tapBPM)")
        XCTAssertGreaterThanOrEqual(state.tapBPM, 118.0,
            "BPM deve essere >= 118, ma è \(state.tapBPM)")
        XCTAssertLessThanOrEqual(state.tapBPM, 122.0,
            "BPM deve essere <= 122, ma è \(state.tapBPM)")
    }

    // MARK: - Test 10: reset() azzera completamente lo stato

    /// Dopo due tap validi (tapBPM > 0, tapOverrideActive = true, tapCount = 1),
    /// reset() deve azzerare tutto e propagare i valori puliti su @MainActor.
    func testResetClearsState() async {
        let clock = MonotonicClock()
        let state = BeatState()
        let tap = TapTempo(state: state, now: clock.now)

        // Produzione di stato non-zero.
        clock.advance(by: 1.0)
        tap.registerTap()
        clock.advance(by: 0.5)    // 120 BPM
        tap.registerTap()

        await waitForMainActor()

        // Precondizione: lo stato deve essere non-zero prima del reset.
        XCTAssertGreaterThan(state.tapBPM, 0.0,
            "Precondizione: tapBPM deve essere > 0 prima di testare reset(), ma è \(state.tapBPM)")

        tap.reset()

        await waitForMainActor()

        XCTAssertEqual(state.tapCount, 0,
            "Dopo reset(), tapCount deve essere 0, ma è \(state.tapCount)")
        XCTAssertEqual(state.tapBPM, 0.0, accuracy: 0.01,
            "Dopo reset(), tapBPM deve essere 0, ma è \(state.tapBPM)")
        XCTAssertFalse(state.tapOverrideActive,
            "Dopo reset(), tapOverrideActive deve essere false")
    }

    // MARK: - Test 11: tapCount cresce di N-1 dopo N tap validi

    /// 4 tap a intervalli uguali producono 3 intervalli validi → tapCount == 3.
    /// Verifica il comportamento del rolling window: ogni tap valido (dopo il primo)
    /// incrementa tapCount di 1.
    func testTapCount_NMinusOne_AfterNValidTaps() async {
        let clock = MonotonicClock()
        let state = BeatState()
        let tap = TapTempo(state: state, now: clock.now)

        clock.advance(by: 1.0)
        tap.registerTap()

        for _ in 0..<3 {
            clock.advance(by: 0.5)  // 120 BPM — valido
            tap.registerTap()
        }

        await waitForMainActor()

        XCTAssertEqual(state.tapCount, 3,
            "4 tap validi devono produrre tapCount == 3 (N-1 intervalli), ma è \(state.tapCount)")
    }
}
