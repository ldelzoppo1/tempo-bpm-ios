import XCTest
import AVFoundation
@testable import Tempo

// MARK: - FakeClock

/// Injectable clock whose time can be advanced from the test body.
/// Must be a class (reference type) so the closure captures it by reference.
private final class FakeClock {
    var t: Double = 1000.0
    func now() -> Double { t }
}

// MARK: - BeatDetectorTests

@MainActor
final class BeatDetectorTests: XCTestCase {

    // MARK: Helpers

    /// Creates a mono 44100 Hz PCM buffer filled with a sinusoid calibrated to produce
    /// the target RMS: amplitude = rms * sqrt(2).
    func makePCMBuffer(rms: Float, frameCount: AVAudioFrameCount = 2048) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buf.frameLength = frameCount
        let amplitude = rms * Float(2.0.squareRoot())
        let data = buf.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            data[i] = amplitude * sin(2.0 * .pi * Float(i) / Float(frameCount))
        }
        return buf
    }

    /// Warms up the energy window with `count` silent-ish buffers so adaptive threshold
    /// is populated before the test onset arrives.
    func warmUp(_ detector: BeatDetector, rms: Float = 0.03, count: Int = 25) {
        let buf = makePCMBuffer(rms: rms)
        for _ in 0..<count { detector.process(buffer: buf) }
    }

    /// Drains pending @MainActor tasks. 100 ms is sufficient for Task { @MainActor }.
    func drainMainActor() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    /// Sets up an onset counter on `detector.onOnset` and returns a closure that
    /// returns the count of valid onsets received so far.
    ///
    /// Usage:
    /// ```swift
    /// let onsetCount = installOnsetCounter(on: detector)
    /// // ... process buffers ...
    /// XCTAssertEqual(onsetCount(), 2)
    /// ```
    func installOnsetCounter(on detector: BeatDetector) -> () -> Int {
        // Use a class box to capture a mutable counter from a non-mutating closure.
        final class Box { var value: Int = 0 }
        let box = Box()
        detector.onOnset = { _, _ in box.value += 1 }
        return { box.value }
    }

    // MARK: - ST2: Onset detection

    /// TC01 — 30 silent buffers (rms=0.001) must produce no onset via onOnset.
    func test_silenceProducesNoOnset() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)
        let onsetCount = installOnsetCounter(on: detector)

        let silentBuf = makePCMBuffer(rms: 0.001)
        for _ in 0..<30 { detector.process(buffer: silentBuf) }

        await drainMainActor()
        XCTAssertEqual(onsetCount(), 0,
                       "Silence must not trigger any onset callback — got \(onsetCount())")
    }

    /// TC02 — 1st pulse calls onOnset once; 2nd and 3rd pulses call it again.
    func test_singleStrongPulseOnOnsetCalledOnFirstThenSubsequent() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        let onsetCount = installOnsetCounter(on: detector)
        let pulse = makePCMBuffer(rms: 0.10)

        // First pulse — first onset: onOnset called once (first onset, no IOI check).
        clock.t = 1001.0
        detector.process(buffer: pulse)
        await drainMainActor()
        XCTAssertEqual(onsetCount(), 1,
                       "First onset must call onOnset once — got \(onsetCount())")

        // Advance past refractory + holddown.
        clock.t += 0.500

        // Second pulse.
        detector.process(buffer: pulse)
        await drainMainActor()
        XCTAssertEqual(onsetCount(), 2,
                       "Second onset must call onOnset a second time — got \(onsetCount())")

        clock.t += 0.500
        detector.process(buffer: pulse)
        await drainMainActor()
        XCTAssertEqual(onsetCount(), 3,
                       "Third onset must call onOnset a third time — got \(onsetCount())")
    }

    /// TC03 — After warmUp(25), currentThreshold must be positive.
    func test_thresholdExposedReflectsWindow() {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector, rms: 0.03, count: 25)

        XCTAssertGreaterThan(detector.currentThreshold, 0,
                             "Adaptive threshold must be > 0 after warm-up")
    }

    /// TC04 — Pulse at rms=0.039 (below minimumOnsetRms=0.040) must not call onOnset.
    func test_minimumRmsGuard() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)
        let onsetCount = installOnsetCounter(on: detector)

        warmUp(detector, rms: 0.01, count: 25)  // very low warm-up so threshold stays low

        // Send three pulses just below minimumOnsetRms at valid intervals.
        let subMinBuf = makePCMBuffer(rms: 0.039)
        for i in 0..<5 {
            clock.t += 0.500 * Double(i + 1)
            detector.process(buffer: subMinBuf)
        }

        await drainMainActor()
        XCTAssertEqual(onsetCount(), 0,
                       "Pulse below minimumOnsetRms=0.040 must not call onOnset — got \(onsetCount())")
    }

    // MARK: - ST3: Refractory / holddown / outlier

    /// TC05 — Two pulses at t=1000.0 and t=1000.350 (< refractorySeconds) → only first calls onOnset.
    func test_refractoryBlocksEarlyOnset() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)
        let onsetCount = installOnsetCounter(on: detector)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        // First pulse at t=1000.0
        clock.t = 1000.0
        detector.process(buffer: pulse)

        // Second pulse at t=1000.350 — within refractory (< 0.350s)
        // Note: refractorySeconds is now 0.350 (updated from 0.400).
        // At exactly 0.350s elapsed it will be blocked (guard: elapsed >= refractorySeconds).
        clock.t = 1000.300
        detector.process(buffer: pulse)

        await drainMainActor()
        // Only the first onset must have called onOnset.
        XCTAssertEqual(onsetCount(), 1,
                       "Onset within refractory window must be blocked — onOnset called \(onsetCount()) times, expected 1")
    }

    /// TC06 — Two pulses separated by > refractorySeconds → both call onOnset.
    func test_refractoryPassesAfter400ms() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)
        let onsetCount = installOnsetCounter(on: detector)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        clock.t = 1000.0
        detector.process(buffer: pulse)

        // 401ms later — just past refractory
        clock.t = 1000.401
        detector.process(buffer: pulse)

        await drainMainActor()
        XCTAssertEqual(onsetCount(), 2,
                       "Onset at 401ms must pass refractory — onOnset called \(onsetCount()) times, expected 2")
    }

    /// TC07 — Strong onset, then weak echo within holddown window → echo does not call onOnset.
    func test_holddownBlocksWeakEcho() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)
        let onsetCount = installOnsetCounter(on: detector)

        warmUp(detector)

        // Strong onset: rms=0.15 at t=1000.0
        clock.t = 1000.0
        let strongPulse = makePCMBuffer(rms: 0.15)
        detector.process(buffer: strongPulse)

        // Echo at t=1000.420 (within holddown 0.450s, beyond refractory 0.400s — but
        // refractorySeconds is 0.350 so also past that)
        // rms=0.025 < 0.15 * 0.20 = 0.030 → holddown blocks it
        clock.t = 1000.420
        let echoPulse = makePCMBuffer(rms: 0.025)
        detector.process(buffer: echoPulse)

        await drainMainActor()
        // The echo must be blocked. Only the first onset should have called onOnset.
        XCTAssertEqual(onsetCount(), 1,
                       "Weak echo within holddown must be blocked — onOnset called \(onsetCount()) times, expected 1")
    }

    /// TC08 — Strong onset, then follow-up >= resonanceHolddownRatio within holddown → passes.
    func test_holddownPassesStrongFollowUp() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)
        let onsetCount = installOnsetCounter(on: detector)

        warmUp(detector)

        // Strong onset: rms=0.15 at t=1000.0
        clock.t = 1000.0
        let strongPulse = makePCMBuffer(rms: 0.15)
        detector.process(buffer: strongPulse)

        // Follow-up at t=1000.420 (within holddown window, past refractory).
        // rms=0.20 > minimumOnsetRms(0.040), exceeds any adaptive threshold after one
        // warm-up pulse, AND >= 0.15 * 0.20 = 0.030 → passes holddown.
        clock.t = 1000.420
        let followUp = makePCMBuffer(rms: 0.20)
        detector.process(buffer: followUp)

        await drainMainActor()
        XCTAssertEqual(onsetCount(), 2,
                       "Follow-up above holddown ratio must register — onOnset called \(onsetCount()) times, expected 2")
    }

    /// TC09 — Establish 3 intervals at 0.500s (120 BPM), then an outlier at 1.000s → rejected (no extra onOnset).
    func test_outlierRejected() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)
        let onsetCount = installOnsetCounter(on: detector)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        // Send 4 pulses at 0.500s intervals to build 3 intervals in the window.
        clock.t = 1000.0
        detector.process(buffer: pulse)
        clock.t = 1000.500
        detector.process(buffer: pulse)
        clock.t = 1001.000
        detector.process(buffer: pulse)
        clock.t = 1001.500
        detector.process(buffer: pulse)

        await drainMainActor()
        let countBeforeOutlier = onsetCount()
        XCTAssertGreaterThan(countBeforeOutlier, 0, "Should have onsets before outlier test")

        // Outlier: 1.000s interval (100% deviation from median 0.500s, > 13% → rejected)
        clock.t = 1002.500
        detector.process(buffer: pulse)

        await drainMainActor()
        // onOnset must NOT have been called for the outlier.
        XCTAssertEqual(onsetCount(), countBeforeOutlier,
                       "Outlier interval must not call onOnset; count before=\(countBeforeOutlier), after=\(onsetCount())")
    }

    /// TC10 — 3 intervals at 0.500s, then 0.560s (12% deviation, within ±13%) → accepted (extra onOnset call).
    func test_outlierAcceptedWithinRange() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)
        let onsetCount = installOnsetCounter(on: detector)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        // Build 3 intervals at 0.500s.
        clock.t = 1000.0
        detector.process(buffer: pulse)
        clock.t = 1000.500
        detector.process(buffer: pulse)
        clock.t = 1001.000
        detector.process(buffer: pulse)
        clock.t = 1001.500
        detector.process(buffer: pulse)

        await drainMainActor()
        let countBeforeVariation = onsetCount()
        XCTAssertGreaterThan(countBeforeVariation, 0, "Should have onsets before variation test")

        // Interval of 0.560s is 12% from median 0.500s — within ±13% → accepted.
        clock.t = 1002.060
        detector.process(buffer: pulse)

        await drainMainActor()
        // onOnset must have been called once more.
        XCTAssertEqual(onsetCount(), countBeforeVariation + 1,
                       "Interval within ±13% of median must be accepted — expected \(countBeforeVariation + 1) calls, got \(onsetCount())")
    }

    /// TC09b — Interval at exactly 12% from median (0.560s) is within outlierThreshold=0.13 → accepted.
    func test_outlierBoundary_12pctDeviation_accepted() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)
        let onsetCount = installOnsetCounter(on: detector)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        // Build 3 stable intervals at 0.500s so median = 0.500s.
        clock.t = 1000.0
        detector.process(buffer: pulse)
        clock.t = 1000.500
        detector.process(buffer: pulse)
        clock.t = 1001.000
        detector.process(buffer: pulse)
        clock.t = 1001.500
        detector.process(buffer: pulse)

        await drainMainActor()
        let countBefore = onsetCount()
        XCTAssertGreaterThan(countBefore, 0, "Precondition: must have onsets before boundary test")

        // 0.560s interval: deviation = |0.560 - 0.500| / 0.500 = 0.12 ≤ 0.13 → accepted.
        clock.t = 1002.060
        detector.process(buffer: pulse)

        await drainMainActor()
        XCTAssertEqual(onsetCount(), countBefore + 1,
                       "12% deviation is within outlierThreshold(0.13) — onOnset must fire; expected \(countBefore + 1) calls, got \(onsetCount())")
    }

    /// TC09c — Interval at 14% from median (0.570s) exceeds outlierThreshold=0.13 → rejected.
    func test_outlierBoundary_14pctDeviation_rejected() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)
        let onsetCount = installOnsetCounter(on: detector)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        // Build 3 stable intervals at 0.500s so median = 0.500s.
        clock.t = 1000.0
        detector.process(buffer: pulse)
        clock.t = 1000.500
        detector.process(buffer: pulse)
        clock.t = 1001.000
        detector.process(buffer: pulse)
        clock.t = 1001.500
        detector.process(buffer: pulse)

        await drainMainActor()
        let countBefore = onsetCount()
        XCTAssertGreaterThan(countBefore, 0, "Precondition: must have onsets before boundary test")

        // 0.570s interval: deviation = |0.570 - 0.500| / 0.500 = 0.14 > 0.13 → rejected.
        clock.t = 1002.070
        detector.process(buffer: pulse)

        await drainMainActor()
        XCTAssertEqual(onsetCount(), countBefore,
                       "14% deviation exceeds outlierThreshold(0.13) — onOnset must NOT fire; expected \(countBefore) calls, got \(onsetCount())")
    }

    // MARK: - ST5: BeatDetector state (reset, beatFlash, beatPosition)

    /// TC18 — Feed beats → call reset() → drain → beatFlash and beatPosition are cleared.
    func test_resetClearsDetectorState() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)
        let onsetCount = installOnsetCounter(on: detector)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)
        for i in 0..<5 {
            clock.t = 1000.0 + Double(i) * 0.500
            detector.process(buffer: pulse)
        }

        await drainMainActor()
        XCTAssertGreaterThan(onsetCount(), 0,
                             "Precondition: must have onsets before reset")

        detector.reset()
        await drainMainActor()

        XCTAssertFalse(state.beatFlash,
                       "reset() must clear beatFlash")
        XCTAssertEqual(state.beatPosition, 0,
                       "reset() must reset beatPosition to 0; got \(state.beatPosition)")
    }

    /// TC20 — 3 beats → pause 2.5s (> maxIntervalSeconds=2.400) → 3 more beats.
    ///
    /// After the pause the interval window is cleared. The FIRST onset of the second
    /// group has an elapsed time > maxIntervalSeconds from the previous onset, so its
    /// IOI fails the range guard and onOnset is NOT called for it (but lastOnsetTime is
    /// updated). The 2nd and 3rd onsets of the second group have a valid IOI (0.430s)
    /// and call onOnset. Total new calls after the pause: 2.
    func test_pauseOver2sResetsIntervalWindow() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)
        let onsetCount = installOnsetCounter(on: detector)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        // First 3 beats at 0.500s intervals.
        // Onset 1: first-onset path → onOnset fires. Count = 1.
        // Onset 2: IOI=0.500s valid → onOnset fires. Count = 2.
        // Onset 3: IOI=0.500s valid → onOnset fires. Count = 3.
        clock.t = 1000.0
        detector.process(buffer: pulse)
        clock.t = 1000.500
        detector.process(buffer: pulse)
        clock.t = 1001.000
        detector.process(buffer: pulse)

        await drainMainActor()
        let countAfterFirstGroup = onsetCount()
        XCTAssertEqual(countAfterFirstGroup, 3,
                       "First group must produce 3 onset calls; got \(countAfterFirstGroup)")

        // Pause 2.5s — exceeds maxIntervalSeconds(2.400) → window clears on next registerOnset.
        clock.t = 1003.500

        // Second group: 3 beats at 0.430s intervals.
        // Onset A: elapsed from last = 2.5s > maxIntervalSeconds → IOI range guard fails
        //          → onOnset NOT called. lastOnsetTime updated to 1003.500. Count unchanged.
        // Onset B: IOI = 0.430s valid → onOnset fires. Count += 1.
        // Onset C: IOI = 0.430s valid → onOnset fires. Count += 1.
        detector.process(buffer: pulse)
        clock.t = 1003.930
        detector.process(buffer: pulse)
        clock.t = 1004.360
        detector.process(buffer: pulse)

        await drainMainActor()
        // 2 new onset calls from the second group.
        XCTAssertEqual(onsetCount(), countAfterFirstGroup + 2,
                       "After pause, 2nd and 3rd beats of new group must call onOnset; expected \(countAfterFirstGroup + 2), got \(onsetCount())")
    }

    // MARK: - ST6: Live mode

    /// TC21 — setMode(.live) then setMode(.solo) → no crash, onOnset not called.
    func test_liveModeSetModeResetsFlux() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)
        let onsetCount = installOnsetCounter(on: detector)

        detector.setMode(.live)
        detector.setMode(.solo)

        // Must not crash; no onset without any buffer processing.
        await drainMainActor()
        XCTAssertEqual(onsetCount(), 0,
                       "After mode switches without beats, onOnset must not have been called")
    }

    /// TC22 — Live mode detects flux transients and calls onOnset after valid onsets.
    func test_liveModeDetectsFluxTransient() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)
        let onsetCount = installOnsetCounter(on: detector)

        detector.setMode(.live)

        // Warm up flux window with low-energy buffers.
        let lowBuf = makePCMBuffer(rms: 0.01)
        for _ in 0..<25 { detector.process(buffer: lowBuf) }

        // Large flux spike: jump from ~0.01 to 0.15 → flux = 0.14 >> fluxThreshold.
        let highBuf = makePCMBuffer(rms: 0.15)

        clock.t = 1000.0
        detector.process(buffer: highBuf)

        // Reset to low energy then spike again for second onset.
        for _ in 0..<3 { detector.process(buffer: lowBuf) }

        clock.t = 1000.500
        detector.process(buffer: highBuf)

        // Third onset.
        for _ in 0..<3 { detector.process(buffer: lowBuf) }
        clock.t = 1001.000
        detector.process(buffer: highBuf)

        await drainMainActor()
        XCTAssertGreaterThan(onsetCount(), 0,
                             "Live mode must call onOnset after flux transients — got \(onsetCount()) calls")
    }

    /// TC23 — Live mode: constant energy (flux=0) → no onset, onOnset never called.
    func test_liveModeNoOnsetWithConstantEnergy() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)
        let onsetCount = installOnsetCounter(on: detector)

        detector.setMode(.live)

        // Constant rms=0.08 → flux = rms - prevRMS = 0 after first buffer.
        let constantBuf = makePCMBuffer(rms: 0.08)
        for _ in 0..<30 { detector.process(buffer: constantBuf) }

        await drainMainActor()
        XCTAssertEqual(onsetCount(), 0,
                       "Constant energy produces zero flux → no onset, onOnset must not be called; got \(onsetCount())")
    }

    /// TC24 — Live mode: two flux transients within refractorySeconds → only first calls onOnset.
    func test_liveModeRefractoryRespected() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)
        let onsetCount = installOnsetCounter(on: detector)

        detector.setMode(.live)

        let lowBuf = makePCMBuffer(rms: 0.01)
        for _ in 0..<25 { detector.process(buffer: lowBuf) }

        let highBuf = makePCMBuffer(rms: 0.15)

        // First transient.
        clock.t = 1000.0
        detector.process(buffer: highBuf)

        // Return to low then spike within 300ms (< refractorySeconds=0.350).
        for _ in 0..<2 { detector.process(buffer: lowBuf) }
        clock.t = 1000.300
        detector.process(buffer: highBuf)

        await drainMainActor()
        // Second transient blocked by refractory → only one onOnset call.
        XCTAssertEqual(onsetCount(), 1,
                       "Live mode must respect refractorySeconds; second onset at 300ms must be blocked — got \(onsetCount()) calls")
    }

    /// TC31 — Live mode: strong transient then weak echo within holddown → echo does not call onOnset.
    func test_liveModeHolddownRespected() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)
        let onsetCount = installOnsetCounter(on: detector)

        detector.setMode(.live)

        let lowBuf = makePCMBuffer(rms: 0.01)
        for _ in 0..<25 { detector.process(buffer: lowBuf) }

        let strongBuf = makePCMBuffer(rms: 0.15)
        let echoBuf   = makePCMBuffer(rms: 0.020)  // < 0.15 * 0.20 = 0.030

        // Strong onset at t=1000.0
        clock.t = 1000.0
        detector.process(buffer: strongBuf)

        // Weak echo at t=1000.420 (within holddown window 0.450s, past refractory 0.350s)
        // rms=0.020 < lastOnsetRms(0.15) * 0.20(=0.030) → holddown blocks
        clock.t = 1000.420
        detector.process(buffer: echoBuf)

        await drainMainActor()
        // Echo blocked → only 1 onOnset call.
        XCTAssertEqual(onsetCount(), 1,
                       "Live mode must block weak echo within holddown window — got \(onsetCount()) calls, expected 1")
    }

    // MARK: - Integrations

    /// TC30 — Pulses at 0.300s intervals cannot all fire because refractory is 0.350s.
    ///         Out of 10 consecutive pulses only those at least 0.350s apart from the previous
    ///         accepted onset can fire — so the count must be less than 10.
    func test_150BPMLimitViaRefractory() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)
        let onsetCount = installOnsetCounter(on: detector)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        // Pulses every 0.300s < refractorySeconds(0.350) → consecutive pulses are suppressed.
        // Accepted onsets happen roughly every 2 pulses (0.600s ≥ 0.350s), so out of 10
        // pulses we expect at most ~5 onset calls, not 10.
        for i in 0..<10 {
            clock.t = 1000.0 + Double(i) * 0.300
            detector.process(buffer: pulse)
        }

        await drainMainActor()
        // Refractory suppresses consecutive pulses: must be strictly fewer than 10 calls.
        XCTAssertLessThan(onsetCount(), 10,
                          "Refractory must suppress consecutive 300ms pulses — expected < 10 onset calls, got \(onsetCount())")
        XCTAssertGreaterThan(onsetCount(), 0,
                             "At least the first pulse must always call onOnset — got \(onsetCount())")
    }

    /// TC32 — Fewer than 3 buffers processed: the energyWindowCount guard blocks onset detection.
    ///
    /// The implementation requires `energyWindowCount >= 3` before computing the adaptive
    /// threshold. With only 1 or 2 buffers in the window the guard fires and no onset is
    /// reported, even when rms > minimumOnsetRms.
    func test_thresholdGuardPreventsNoiseTrigger() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)
        let onsetCount = installOnsetCounter(on: detector)

        // Send only 2 strong pulses without any warm-up.
        // energyWindowCount will be 1 after the first, 2 after the second.
        // The guard `energyWindowCount >= 3` blocks onset detection for both.
        let strongBuf = makePCMBuffer(rms: 0.15)
        clock.t = 1000.0
        detector.process(buffer: strongBuf)     // count = 1 → blocked

        clock.t = 1000.500
        detector.process(buffer: strongBuf)     // count = 2 → still blocked

        await drainMainActor()
        XCTAssertEqual(onsetCount(), 0,
                       "energyWindowCount guard must block onset when fewer than 3 buffers have been processed; got \(onsetCount()) calls")
    }

    // MARK: - ST8: effectiveWindowSize

    /// TC35 — effectiveWindowSize is 64 without a known BPM and shrinks once BPM is established.
    func test_effectiveWindowSize_largerAtLowBPM() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        // Without any warm-up or beats, effectiveWindowSize must equal energyWindowMaxSize (64).
        XCTAssertEqual(detector.currentEffectiveWindowSize, 64,
                       "Without known BPM, effectiveWindowSize must be 64 (energyWindowMaxSize)")

        warmUp(detector, rms: 0.05, count: 25)

        let pulse = makePCMBuffer(rms: 0.5)

        // Inject 5 bursts at 0.5s intervals to establish a known IOI.
        for i in 0..<5 {
            clock.t = 1000.0 + Double(i) * 0.5
            detector.process(buffer: pulse)
        }

        await drainMainActor()
        XCTAssertLessThan(detector.currentEffectiveWindowSize, 64,
                          "With known IOI the window must shrink from the maximum; got \(detector.currentEffectiveWindowSize)")
        XCTAssertGreaterThanOrEqual(detector.currentEffectiveWindowSize, 22,
                                    "Window must not fall below the minimum of 22; got \(detector.currentEffectiveWindowSize)")
    }

    // MARK: - ST9: onOnset closure

    /// TBD-69 / TC-A — Valid onset above threshold and past refractory calls onOnset
    /// with timestamp > 0 and rms > 0.
    func test_onOnset_calledOnValidOnset() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        var onOnsetCalled = false
        var capturedTimestamp: Double = 0
        var capturedRms: Float = 0

        detector.onOnset = { t, rms in
            onOnsetCalled = true
            capturedTimestamp = t
            capturedRms = rms
        }

        // Deliver a pulse strong enough to clear all gates (minimumOnsetRms, adaptive threshold,
        // kick filter) at a time well past any previous onset.
        clock.t = 2000.0
        let pulse = makePCMBuffer(rms: 0.15)
        detector.process(buffer: pulse)

        await drainMainActor()

        XCTAssertTrue(onOnsetCalled,
                      "onOnset must be called for a valid onset above threshold and past refractory")
        XCTAssertGreaterThan(capturedTimestamp, 0,
                             "Captured timestamp must be > 0; got \(capturedTimestamp)")
        XCTAssertGreaterThan(capturedRms, 0,
                             "Captured rms must be > 0; got \(capturedRms)")
    }

    /// TBD-69 / TC-B — Two onsets within refractorySeconds → onOnset called only once.
    func test_onOnset_notCalledDuringRefractory() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        var callCount = 0
        detector.onOnset = { _, _ in callCount += 1 }

        let pulse = makePCMBuffer(rms: 0.15)

        // First onset at t=1000.0 — passes all gates (first-onset path).
        clock.t = 1000.0
        detector.process(buffer: pulse)

        // Second onset at t=1000.200 — within refractorySeconds(0.350) → must be blocked.
        clock.t = 1000.200
        detector.process(buffer: pulse)

        await drainMainActor()

        XCTAssertEqual(callCount, 1,
                       "onOnset must be called exactly once when the second onset falls within refractory (200ms < 350ms); got \(callCount)")
    }

    // MARK: - ST10: beatFlash and beatPosition

    /// TC-BP1 — After a valid onset, state.beatFlash is set to true then cleared within 200ms.
    func test_validOnset_setsBeatFlash() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        // Need at least two valid onsets with one IOI for beatFlash to be published
        // (publishOnsetToState is called only after IOI validation in registerOnset).
        let pulse = makePCMBuffer(rms: 0.15)

        // First onset (first-onset path — no IOI stored yet; onOnset fires but beatFlash not set).
        clock.t = 1000.0
        detector.process(buffer: pulse)

        // Second onset past refractory — IOI=0.500s is valid → publishOnsetToState called.
        clock.t = 1000.500
        detector.process(buffer: pulse)

        // Allow @MainActor task to fire.
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(state.beatFlash,
                      "beatFlash must be true shortly after a valid onset's publishOnsetToState")

        // Wait for beatFlash to be cleared (100ms sleep inside publishOnsetToState).
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertFalse(state.beatFlash,
                       "beatFlash must auto-clear to false within 200ms of onset")
    }

    /// TC-BP2 — beatPosition increments modulo 4 across consecutive valid onsets.
    func test_validOnsets_incrementBeatPosition() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        // First onset: first-onset path, no publishOnsetToState → beatPosition stays 0.
        clock.t = 1000.0
        detector.process(buffer: pulse)
        await drainMainActor()
        XCTAssertEqual(state.beatPosition, 0,
                       "First onset (first-onset path) must not increment beatPosition")

        // Second onset: IOI=0.500s → valid → publishOnsetToState → beatPosition = 1.
        clock.t = 1000.500
        detector.process(buffer: pulse)
        await drainMainActor()
        XCTAssertEqual(state.beatPosition, 1,
                       "After 2nd onset beatPosition must be 1; got \(state.beatPosition)")

        // Third onset → beatPosition = 2.
        clock.t = 1001.000
        detector.process(buffer: pulse)
        await drainMainActor()
        XCTAssertEqual(state.beatPosition, 2,
                       "After 3rd onset beatPosition must be 2; got \(state.beatPosition)")

        // Continue up to 4 and verify wrap-around.
        clock.t = 1001.500
        detector.process(buffer: pulse)
        await drainMainActor()
        XCTAssertEqual(state.beatPosition, 3,
                       "After 4th onset beatPosition must be 3; got \(state.beatPosition)")

        clock.t = 1002.000
        detector.process(buffer: pulse)
        await drainMainActor()
        XCTAssertEqual(state.beatPosition, 0,
                       "After 5th onset beatPosition must wrap to 0; got \(state.beatPosition)")
    }

    // MARK: - ST11: minimumOnsetRms gate

    /// TC37 — Pulses with rms below minimumOnsetRms (0.040) must not call onOnset.
    func test_minimumOnsetRms_blocksLowEnergyOnset() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)
        let onsetCount = installOnsetCounter(on: detector)

        warmUp(detector, rms: 0.005, count: 25)

        // Inject burst with rms=0.035, below minimumOnsetRms=0.040.
        let subThresholdBuf = makePCMBuffer(rms: 0.035)
        clock.t += 0.5
        detector.process(buffer: subThresholdBuf)

        await drainMainActor()
        XCTAssertEqual(onsetCount(), 0,
                       "RMS below 0.040 must not call onOnset; got \(onsetCount()) calls")
    }
}
