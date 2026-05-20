import XCTest
@testable import Tempo

// MARK: - FakeClock (local to this file)

/// Controllable clock whose value can be advanced freely from a test body.
/// Defined as a class so the closure captures it by reference.
private final class FakeClock {
    var t: Double = 1_000.0
    func now() -> Double { t }
}

// MARK: - TapTempoTests

@MainActor
final class TapTempoTests: XCTestCase {

    var state: BeatState!
    var tapTempo: TapTempo!
    var clock: FakeClock!

    override func setUp() async throws {
        clock = FakeClock()
        state = BeatState()
        tapTempo = TapTempo(state: state, now: clock.now)
    }

    override func tearDown() async throws {
        tapTempo.reset()
        tapTempo = nil
        state = nil
        clock = nil
    }

    // MARK: - BPM calculation

    /// TC_TT01 — A single tap cannot form any interval; BPM must remain 0.
    func test_tap_primoTap_nessunBPM() {
        clock.t = 1_000.0
        tapTempo.tap()

        XCTAssertEqual(state.tapBPM, 0,
                       "Un solo tap non produce intervalli — tapBPM deve essere 0, ottenuto \(state.tapBPM)")
        XCTAssertEqual(state.currentBPM, 0,
                       "Un solo tap non deve aggiornare currentBPM — ottenuto \(state.currentBPM)")
    }

    /// TC_TT02 — Two taps 500 ms apart → BPM ≈ 120.0 (60 / 0.500 = 120).
    func test_tap_dueTap_calcolaBPM() {
        clock.t = 1_000.0
        tapTempo.tap()

        clock.t = 1_000.5
        tapTempo.tap()

        XCTAssertEqual(state.tapBPM, 120.0, accuracy: 1.0,
                       "Due tap a 500ms → BPM deve essere ≈ 120.0, ottenuto \(state.tapBPM)")
        XCTAssertEqual(state.currentBPM, 120.0, accuracy: 1.0,
                       "currentBPM deve corrispondere a tapBPM, ottenuto \(state.currentBPM)")
    }

    /// TC_TT03 — Four taps at 500 ms each → averaged BPM still ≈ 120.0.
    func test_tap_quattroTap_mediaCorretta() {
        for i in 0..<4 {
            clock.t = 1_000.0 + Double(i) * 0.500
            tapTempo.tap()
        }

        XCTAssertEqual(state.tapBPM, 120.0, accuracy: 1.0,
                       "Quattro tap a 500ms → media BPM deve essere ≈ 120.0, ottenuto \(state.tapBPM)")
    }

    /// TC_TT04 — Taps at irregular intervals → BPM equals the mean of those intervals.
    /// Intervals: 0.400s, 0.600s, 0.500s → mean = 0.500s → BPM = 120.0.
    func test_tap_intervalliIrregolari_mediaDeglIntervalli() {
        let timestamps = [1_000.0, 1_000.400, 1_001.000, 1_001.500]
        for t in timestamps {
            clock.t = t
            tapTempo.tap()
        }
        // Intervals: 0.400, 0.600, 0.500 → mean = 0.500s → 120 BPM
        XCTAssertEqual(state.tapBPM, 120.0, accuracy: 2.0,
                       "Intervalli irregolari: la media deve produrre ≈ 120 BPM, ottenuto \(state.tapBPM)")
    }

    /// TC_TT05 — A tap that arrives more than 3 s after the previous one resets the
    /// internal timestamp sequence and immediately zeroes tapBPM, currentBPM and
    /// tapOverrideActive so stale values are never shown to the user.
    func test_tap_inattivitaOltre3s_resetSequenza() {
        clock.t = 1_000.0
        tapTempo.tap()
        clock.t = 1_000.5
        tapTempo.tap()
        XCTAssertEqual(state.tapBPM, 120.0, accuracy: 1.0,
                       "Precondizione: tapBPM deve essere 120.0 dopo 2 tap a 500ms")

        // New tap arrives 3.1 s after the last → gap > 3s → sequence clears
        // and BPM values are zeroed immediately.
        clock.t = 1_003.6
        tapTempo.tap()

        XCTAssertEqual(state.tapCount, 1,
                       "Dopo reset sequenza il contatore deve essere 1, ottenuto \(state.tapCount)")
        XCTAssertEqual(state.tapBPM, 0,
                       "tapBPM deve essere azzerato subito dopo il timeout della sequenza, ottenuto \(state.tapBPM)")
        XCTAssertEqual(state.currentBPM, 0,
                       "currentBPM deve essere azzerato subito dopo il timeout della sequenza, ottenuto \(state.currentBPM)")
        XCTAssertFalse(state.tapOverrideActive,
                       "tapOverrideActive deve essere false dopo il timeout della sequenza")

        // A second tap in the new window produces a fresh BPM.
        clock.t = 1_004.1
        tapTempo.tap()
        XCTAssertEqual(state.tapBPM, 120.0, accuracy: 1.0,
                       "La nuova coppia di tap deve produrre ≈ 120 BPM, ottenuto \(state.tapBPM)")
    }

    // MARK: - tapOverrideActive

    /// TC_TT06 — After 2 taps, tapOverrideActive must be true.
    func test_tap_dopoDueTap_tapOverrideAttivo() {
        clock.t = 1_000.0
        tapTempo.tap()

        clock.t = 1_000.5
        tapTempo.tap()

        XCTAssertTrue(state.tapOverrideActive,
                      "Dopo 2 tap, tapOverrideActive deve essere true")
    }

    /// TC_TT07 — Calling reset() must immediately set tapOverrideActive to false.
    func test_reset_tapOverrideDisattivato() {
        clock.t = 1_000.0
        tapTempo.tap()
        clock.t = 1_000.5
        tapTempo.tap()

        // Precondition
        XCTAssertTrue(state.tapOverrideActive, "Precondizione: tapOverrideActive deve essere true dopo 2 tap")

        tapTempo.reset()

        XCTAssertFalse(state.tapOverrideActive,
                       "Dopo reset(), tapOverrideActive deve essere false")
    }

    // MARK: - BeatState integration

    /// TC_TT08 — After 2 taps currentBPM in BeatState is overwritten with the tap BPM.
    func test_tap_currentBPMSovrascrittoDaTapBPM() {
        // Simulate a pre-existing BPM from the audio detector.
        state.currentBPM = 95.0

        clock.t = 1_000.0
        tapTempo.tap()
        clock.t = 1_000.5
        tapTempo.tap()

        XCTAssertEqual(state.currentBPM, 120.0, accuracy: 1.0,
                       "currentBPM deve essere sovrascritto dal tapBPM (≈ 120.0), ottenuto \(state.currentBPM)")
    }

    /// TC_TT09 — tapCount is incremented on every tap.
    func test_tap_tapCountIncrementato() {
        XCTAssertEqual(state.tapCount, 0, "tapCount deve partire da 0")

        clock.t = 1_000.0
        tapTempo.tap()
        XCTAssertEqual(state.tapCount, 1, "tapCount deve essere 1 dopo il primo tap")

        clock.t = 1_000.5
        tapTempo.tap()
        XCTAssertEqual(state.tapCount, 2, "tapCount deve essere 2 dopo il secondo tap")

        clock.t = 1_001.0
        tapTempo.tap()
        XCTAssertEqual(state.tapCount, 3, "tapCount deve essere 3 dopo il terzo tap")
    }

    // MARK: - Reset state

    /// Verify that reset() clears tapCount and tapBPM in addition to tapOverrideActive.
    func test_reset_azzeraTuttoLoStato() {
        clock.t = 1_000.0
        tapTempo.tap()
        clock.t = 1_000.5
        tapTempo.tap()

        tapTempo.reset()

        XCTAssertEqual(state.tapCount, 0,
                       "reset() deve azzerare tapCount, ottenuto \(state.tapCount)")
        XCTAssertEqual(state.tapBPM, 0,
                       "reset() deve azzerare tapBPM, ottenuto \(state.tapBPM)")
        XCTAssertFalse(state.tapOverrideActive,
                       "reset() deve disattivare tapOverrideActive")
    }

    // MARK: - Sequence window cap

    /// TapTempo keeps at most 8 timestamps. After 9 taps the oldest is discarded and
    /// tapCount must not exceed 8.
    func test_tap_finestra8Timestamp_tapCountLimitato() {
        for i in 0..<9 {
            clock.t = 1_000.0 + Double(i) * 0.500
            tapTempo.tap()
        }

        XCTAssertEqual(state.tapCount, 8,
                       "La finestra è limitata a 8 timestamp — tapCount deve essere 8, ottenuto \(state.tapCount)")
    }

    // MARK: - Auto-reset after 3 s (TC_TT10)

    /// TC_TT10 — tapOverrideActive returns to false automatically after 3 seconds of
    /// inactivity. This test uses a real Task.sleep so it takes ~3.5 s. It is
    /// deliberately placed last and uses XCTestExpectation so XCTest can time-box it.
    func test_tap_inattivita3s_tapOverrideDisattivaAutomaticamente() async throws {
        // Use a real-time TapTempo (no FakeClock) because the internal resetTask uses
        // a real Task.sleep(3s) that cannot be controlled via the injected clock.
        let realState = BeatState()
        let realTapTempo = TapTempo(state: realState)

        realTapTempo.tap()

        // Give the first tap a small real-time gap then produce a second tap so that
        // tapOverrideActive is set to true.
        try await Task.sleep(for: .milliseconds(100))
        realTapTempo.tap()

        XCTAssertTrue(realState.tapOverrideActive,
                      "Precondizione: tapOverrideActive deve essere true dopo 2 tap")

        // Wait for the internal resetTask (3s) plus a small margin.
        let expectation = expectation(description: "tapOverrideActive torna false dopo 3s")
        Task {
            // Poll at 200 ms intervals — ceiling at 4 s total.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(200))
                if !realState.tapOverrideActive {
                    expectation.fulfill()
                    return
                }
            }
        }
        await fulfillment(of: [expectation], timeout: 4.5)

        XCTAssertFalse(realState.tapOverrideActive,
                       "Dopo 3s senza tap, tapOverrideActive deve tornare automaticamente a false")
        realTapTempo.reset()
    }
}
