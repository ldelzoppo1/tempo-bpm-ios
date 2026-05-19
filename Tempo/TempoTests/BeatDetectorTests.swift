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

    // MARK: - ST2: Onset detection

    /// TC01 — 30 silent buffers (rms=0.001) must produce no BPM.
    func test_silenceProducesNoBPM() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        let silentBuf = makePCMBuffer(rms: 0.001)
        for _ in 0..<30 { detector.process(buffer: silentBuf) }

        await drainMainActor()
        XCTAssertEqual(state.currentBPM, 0,
                       "Silence must not produce any BPM — got \(state.currentBPM)")
    }

    /// TC02 — 1st pulse produces no BPM (needs 2 intervals); 2nd pulse publishes BPM.
    func test_singleStrongPulseNoBPMUntilSecond() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.10)

        // First pulse — registers onset timestamp but cannot publish BPM yet.
        detector.process(buffer: pulse)
        await drainMainActor()
        XCTAssertEqual(state.currentBPM, 0,
                       "Single onset must not publish BPM — got \(state.currentBPM)")

        // Advance past refractory + holddown.
        clock.t += 0.500

        // Second pulse — now we have 1 interval → but we still need count >= 2.
        // After the 2nd onset we have 1 interval; publishBeatState requires count >= 2.
        detector.process(buffer: pulse)
        await drainMainActor()

        // A third pulse at another +500ms gives us 2 intervals → BPM published.
        clock.t += 0.500
        detector.process(buffer: pulse)
        await drainMainActor()

        XCTAssertGreaterThan(state.currentBPM, 0,
                             "After 3 pulses (2 intervals) BPM must be published")
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

    /// TC04 — Pulse at rms=0.039 (below minimumOnsetRms=0.040) must not register onset.
    func test_minimumRmsGuard() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector, rms: 0.01, count: 25)  // very low warm-up so threshold stays low

        // Send three pulses just below minimumOnsetRms at valid intervals.
        let subMinBuf = makePCMBuffer(rms: 0.039)
        for i in 0..<5 {
            clock.t += 0.500 * Double(i + 1)
            detector.process(buffer: subMinBuf)
        }

        await drainMainActor()
        XCTAssertEqual(state.currentBPM, 0,
                       "Pulse below minimumOnsetRms=0.040 must not register onset — got \(state.currentBPM)")
    }

    // MARK: - ST3: Refractory / holddown / outlier

    /// TC05 — Two pulses at t=1000.0 and t=1000.350 (< 400ms) → only first registers.
    func test_refractoryBlocksEarlyOnset() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        // First pulse at t=1000.0
        clock.t = 1000.0
        detector.process(buffer: pulse)

        // Second pulse at t=1000.350 — within refractory (< 0.400s)
        clock.t = 1000.350
        detector.process(buffer: pulse)

        await drainMainActor()
        // Only first onset registered; no BPM because we need 2 intervals (minimum 3 onsets for BPM).
        // The second pulse was blocked → no interval recorded → no BPM.
        XCTAssertEqual(state.currentBPM, 0,
                       "Onset within refractory window must be blocked — got \(state.currentBPM)")
    }

    /// TC06 — Two pulses at t=1000.0 and t=1000.401 → both register → with a 3rd, BPM published.
    func test_refractoryPassesAfter400ms() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        clock.t = 1000.0
        detector.process(buffer: pulse)

        // 401ms later — just past refractory
        clock.t = 1000.401
        detector.process(buffer: pulse)

        // Third pulse for 2nd interval → BPM published.
        clock.t = 1000.802
        detector.process(buffer: pulse)

        await drainMainActor()
        XCTAssertGreaterThan(state.currentBPM, 0,
                             "Onset at 401ms must pass refractory and produce BPM")
    }

    /// TC07 — Strong onset, then weak echo within holddown window (rms < 0.20 * lastOnsetRms) → echo blocked.
    func test_holddownBlocksWeakEcho() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        // Strong onset: rms=0.15 at t=1000.0
        clock.t = 1000.0
        let strongPulse = makePCMBuffer(rms: 0.15)
        detector.process(buffer: strongPulse)

        // Echo at t=1000.420 (within holddown 0.450s, beyond refractory 0.400s)
        // rms=0.025 < 0.15 * 0.20 = 0.030 → holddown blocks it
        clock.t = 1000.420
        let echoPulse = makePCMBuffer(rms: 0.025)
        detector.process(buffer: echoPulse)

        // Third strong pulse to attempt BPM publication
        clock.t = 1000.500
        detector.process(buffer: strongPulse)

        await drainMainActor()
        // The echo was blocked. We only have 2 valid onsets (t=1000.0 and t=1000.500),
        // giving 1 interval → still need 2 intervals for BPM → BPM should be 0.
        XCTAssertEqual(state.currentBPM, 0,
                       "Weak echo within holddown must be blocked — got \(state.currentBPM)")
    }

    /// TC08 — Strong onset, then follow-up >= resonanceHolddownRatio within holddown → passes.
    func test_holddownPassesStrongFollowUp() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        // Strong onset: rms=0.10 at t=1000.0
        clock.t = 1000.0
        let strongPulse = makePCMBuffer(rms: 0.10)
        detector.process(buffer: strongPulse)

        // Follow-up at t=1000.420: rms=0.030 >= 0.10 * 0.20 = 0.020 → passes holddown
        clock.t = 1000.420
        let followUp = makePCMBuffer(rms: 0.030)
        detector.process(buffer: followUp)

        // Third pulse for 2nd interval
        clock.t = 1000.840
        detector.process(buffer: strongPulse)

        await drainMainActor()
        XCTAssertGreaterThan(state.currentBPM, 0,
                             "Follow-up above holddown ratio must register and produce BPM")
    }

    /// TC09 — Establish 3 intervals at 0.500s (120 BPM), then an outlier at 1.000s → rejected.
    func test_outlierRejected() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

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
        let bpmAfterStable = state.currentBPM

        XCTAssertGreaterThan(bpmAfterStable, 0, "Should have BPM before outlier test")

        // Outlier: 1.000s interval (100% deviation from median 0.500s, > 40% → rejected)
        clock.t = 1002.500
        detector.process(buffer: pulse)

        await drainMainActor()
        // BPM should remain approximately the same (outlier rejected).
        XCTAssertEqual(state.currentBPM, bpmAfterStable, accuracy: 5.0,
                       "Outlier interval must be rejected; BPM must remain ~\(bpmAfterStable), got \(state.currentBPM)")
    }

    /// TC10 — 3 intervals at 0.500s, then 0.650s (30% deviation < 40%) → accepted.
    func test_outlierAcceptedWithinRange() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

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

        // Interval of 0.650s is 30% from median 0.500s — within ±40% → accepted.
        // New mean ≈ (0.500+0.500+0.500+0.650)/4 = 0.538s → ~111 BPM (raw).
        clock.t = 1002.150
        detector.process(buffer: pulse)

        await drainMainActor()
        // BPM should shift from ~120 toward ~111 (raw), then EMA-smoothed.
        XCTAssertGreaterThan(state.currentBPM, 0,
                             "Interval within ±40% of median must be accepted; BPM must update")
    }

    // MARK: - ST4: BPM convergence

    /// TC11 — 6 beats at 0.500s intervals → state.currentBPM in [115, 125].
    func test_120BPMConverges() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        clock.t = 1000.0
        for i in 0..<6 {
            clock.t = 1000.0 + Double(i) * 0.500
            detector.process(buffer: pulse)
        }

        await drainMainActor()
        XCTAssertGreaterThanOrEqual(state.currentBPM, 115,
                                    "120 BPM should converge >= 115, got \(state.currentBPM)")
        XCTAssertLessThanOrEqual(state.currentBPM, 125,
                                 "120 BPM should converge <= 125, got \(state.currentBPM)")
    }

    /// TC12 — 6 beats at 0.750s intervals → BPM in [75, 85].
    func test_80BPMConverges() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        for i in 0..<6 {
            clock.t = 1000.0 + Double(i) * 0.750
            detector.process(buffer: pulse)
        }

        await drainMainActor()
        XCTAssertGreaterThanOrEqual(state.currentBPM, 75,
                                    "80 BPM should converge >= 75, got \(state.currentBPM)")
        XCTAssertLessThanOrEqual(state.currentBPM, 85,
                                 "80 BPM should converge <= 85, got \(state.currentBPM)")
    }

    /// TC13 — 6 beats at 0.432s intervals → BPM in [134, 144].
    func test_139BPMConverges() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        for i in 0..<6 {
            clock.t = 1000.0 + Double(i) * 0.432
            detector.process(buffer: pulse)
        }

        await drainMainActor()
        XCTAssertGreaterThanOrEqual(state.currentBPM, 134,
                                    "139 BPM should converge >= 134, got \(state.currentBPM)")
        XCTAssertLessThanOrEqual(state.currentBPM, 144,
                                 "139 BPM should converge <= 144, got \(state.currentBPM)")
    }

    /// TC14 — Beats at 1.100s intervals (raw ≈ 54.5 BPM < 80) → octave correction doubles to ≈ 109.
    func test_octaveCorrectionApplied() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        // 1.100s interval → raw = 60/1.1 ≈ 54.5 BPM → corrected ≈ 109 BPM.
        for i in 0..<7 {
            clock.t = 1000.0 + Double(i) * 1.100
            detector.process(buffer: pulse)
        }

        await drainMainActor()
        XCTAssertGreaterThanOrEqual(state.currentBPM, 100,
                                    "Octave correction must double raw ~54 BPM → ~109; got \(state.currentBPM)")
        XCTAssertLessThanOrEqual(state.currentBPM, 118,
                                 "Octave-corrected BPM must be <= 118; got \(state.currentBPM)")
    }

    /// TC15 — After 8 beats, only the last 4 intervals influence BPM (window capped).
    func test_bpmWindowCapsAt4() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        // First 4 pulses at 0.500s intervals (120 BPM region).
        for i in 0..<4 {
            clock.t = 1000.0 + Double(i) * 0.500
            detector.process(buffer: pulse)
        }

        // Next 4 pulses at 0.430s intervals (~140 BPM region).
        // These should replace the window and dominate the BPM.
        let baseTime = 1000.0 + 3 * 0.500  // last of the 120 BPM pulses
        for i in 1...4 {
            clock.t = baseTime + Double(i) * 0.430
            detector.process(buffer: pulse)
        }

        await drainMainActor()
        // Window is now all 0.430s intervals → BPM should be ≈ 140, not ≈ 120.
        XCTAssertGreaterThanOrEqual(state.currentBPM, 130,
                                    "After 8 beats, window must reflect last 4 intervals (~140 BPM); got \(state.currentBPM)")
        XCTAssertLessThanOrEqual(state.currentBPM, 150,
                                 "BPM must be <= 150 for ~140 BPM target; got \(state.currentBPM)")
    }

    // MARK: - ST5: Stability under perturbation

    /// TC16 — 6 identical intervals → state.stability > 0.8.
    func test_perfectRhythmStabilityHigh() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        for i in 0..<6 {
            clock.t = 1000.0 + Double(i) * 0.500
            detector.process(buffer: pulse)
        }

        await drainMainActor()
        XCTAssertGreaterThan(state.stability, 0.8,
                             "Perfect rhythm must yield stability > 0.8; got \(state.stability)")
    }

    /// TC17 — 6 intervals with ±30% jitter → state.stability < 0.5.
    func test_irregularRhythmStabilityLow() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        // Jittered intervals: ±30% around 0.500s but constrained to pass refractory.
        // Intervals: 0.500, 0.650, 0.420, 0.650, 0.420 — all within ±40% of median(~0.500).
        // Actual jitter: std/mean ≈ 0.10 → CV=0.10 → stability = 1 - 0.10*5 = 0.5
        // Use wider spread to guarantee stability < 0.5
        let intervals: [Double] = [0.500, 0.650, 0.420, 0.700, 0.430]
        var t = 1000.0
        clock.t = t
        detector.process(buffer: pulse) // first onset

        for interval in intervals {
            t += interval
            clock.t = t
            detector.process(buffer: pulse)
        }

        await drainMainActor()
        XCTAssertLessThan(state.stability, 0.5,
                          "High jitter rhythm must yield stability < 0.5; got \(state.stability)")
    }

    /// TC18 — Feed beats → verify BPM > 0 → call reset() → drain → state.currentBPM == 0.
    func test_resetClearsBPM() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)
        for i in 0..<5 {
            clock.t = 1000.0 + Double(i) * 0.500
            detector.process(buffer: pulse)
        }

        await drainMainActor()
        XCTAssertGreaterThan(state.currentBPM, 0,
                             "BPM must be > 0 before reset")

        detector.reset()
        await drainMainActor()

        XCTAssertEqual(state.currentBPM, 0,
                       "reset() must zero currentBPM; got \(state.currentBPM)")
    }

    /// TC19 — tapOverrideActive = true suppresses BPM updates from detector.
    func test_tapOverrideSuppressesUpdate() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        // Activate tap override before any beat arrives.
        await MainActor.run { state.tapOverrideActive = true }

        let pulse = makePCMBuffer(rms: 0.15)
        for i in 0..<6 {
            clock.t = 1000.0 + Double(i) * 0.500
            detector.process(buffer: pulse)
        }

        await drainMainActor()
        XCTAssertEqual(state.currentBPM, 0,
                       "tapOverrideActive must suppress BPM updates; got \(state.currentBPM)")
    }

    /// TC20 — 3 beats → pause 2.1s → 3 more beats → BPM recalculates from fresh window.
    func test_pauseOver2sResetsIntervalWindow() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        // First 3 beats at 0.500s intervals.
        clock.t = 1000.0
        detector.process(buffer: pulse)
        clock.t = 1000.500
        detector.process(buffer: pulse)
        clock.t = 1001.000
        detector.process(buffer: pulse)

        await drainMainActor()

        // Pause 2.1s — exceeds maxIntervalSeconds(2.0) → window clears on next onset.
        clock.t = 1003.100

        // Second group: 3 beats at 0.430s intervals.
        detector.process(buffer: pulse)
        clock.t = 1003.530
        detector.process(buffer: pulse)
        clock.t = 1003.960
        detector.process(buffer: pulse)

        await drainMainActor()
        // Fresh window now reflects ~0.430s intervals → ~140 BPM, not mixed with old ~0.500s.
        XCTAssertGreaterThan(state.currentBPM, 0,
                             "BPM must be published after pause + new beats")
        XCTAssertGreaterThanOrEqual(state.currentBPM, 125,
                                    "BPM after reset window must reflect new 0.430s intervals (~140 BPM); got \(state.currentBPM)")
    }

    // MARK: - ST6: Live mode

    /// TC21 — setMode(.live) then setMode(.solo) → no crash, state consistent.
    func test_liveModeSetModeResetsFlux() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        detector.setMode(.live)
        detector.setMode(.solo)

        // Must not crash; BPM starts at 0.
        await drainMainActor()
        XCTAssertEqual(state.currentBPM, 0,
                       "After mode switches without beats, BPM must remain 0")
    }

    /// TC22 — Live mode detects flux transients and publishes BPM after 2 valid onsets.
    func test_liveModeDetectsFluxTransient() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

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

        // Third onset for 2nd interval → BPM published.
        for _ in 0..<3 { detector.process(buffer: lowBuf) }
        clock.t = 1001.000
        detector.process(buffer: highBuf)

        await drainMainActor()
        XCTAssertGreaterThan(state.currentBPM, 0,
                             "Live mode must publish BPM after 3 flux transients (2 intervals)")
    }

    /// TC23 — Live mode: constant energy (flux=0) → no onset, BPM=0.
    func test_liveModeNoOnsetWithConstantEnergy() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        detector.setMode(.live)

        // Constant rms=0.08 → flux = rms - prevRMS = 0 after first buffer.
        let constantBuf = makePCMBuffer(rms: 0.08)
        for _ in 0..<30 { detector.process(buffer: constantBuf) }

        await drainMainActor()
        XCTAssertEqual(state.currentBPM, 0,
                       "Constant energy produces zero flux → no onset, BPM must be 0; got \(state.currentBPM)")
    }

    /// TC24 — Live mode: two flux transients within 400ms → only first registers.
    func test_liveModeRefractoryRespected() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        detector.setMode(.live)

        let lowBuf = makePCMBuffer(rms: 0.01)
        for _ in 0..<25 { detector.process(buffer: lowBuf) }

        let highBuf = makePCMBuffer(rms: 0.15)

        // First transient.
        clock.t = 1000.0
        detector.process(buffer: highBuf)

        // Return to low then spike within 350ms.
        for _ in 0..<2 { detector.process(buffer: lowBuf) }
        clock.t = 1000.350  // < refractorySeconds(0.400)
        detector.process(buffer: highBuf)

        await drainMainActor()
        // Second transient blocked by refractory → no interval recorded → BPM=0.
        XCTAssertEqual(state.currentBPM, 0,
                       "Live mode must respect 400ms refractory; second onset at 350ms must be blocked")
    }

    /// TC31 — Live mode: strong transient then weak echo within holddown → echo blocked.
    func test_liveModeHolddownRespected() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        detector.setMode(.live)

        let lowBuf = makePCMBuffer(rms: 0.01)
        for _ in 0..<25 { detector.process(buffer: lowBuf) }

        let strongBuf = makePCMBuffer(rms: 0.15)
        let echoBuf   = makePCMBuffer(rms: 0.020)  // < 0.15 * 0.20 = 0.030

        // Strong onset at t=1000.0
        clock.t = 1000.0
        detector.process(buffer: strongBuf)

        // Weak echo at t=1000.420 (within holddown window 0.450s, past refractory 0.400s)
        // rms=0.020 < lastOnsetRms(0.15) * 0.20(=0.030) → holddown blocks
        clock.t = 1000.420
        detector.process(buffer: echoBuf)

        await drainMainActor()
        // Echo blocked → only 1 onset registered → no BPM.
        XCTAssertEqual(state.currentBPM, 0,
                       "Live mode must block weak echo within holddown window; got \(state.currentBPM)")
    }

    // MARK: - ST7: Session stats

    /// TC25 — Feed beats at 120 BPM → state.minBPM > 0.
    func test_sessionMinBPMTracked() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)
        for i in 0..<6 {
            clock.t = 1000.0 + Double(i) * 0.500
            detector.process(buffer: pulse)
        }

        await drainMainActor()
        XCTAssertGreaterThan(state.minBPM, 0,
                             "minBPM must be tracked after beats; got \(state.minBPM)")
    }

    /// TC26 — Feed beats → state.maxBPM >= state.currentBPM.
    func test_sessionMaxBPMTracked() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)
        for i in 0..<6 {
            clock.t = 1000.0 + Double(i) * 0.500
            detector.process(buffer: pulse)
        }

        await drainMainActor()
        XCTAssertGreaterThanOrEqual(state.maxBPM, state.currentBPM,
                                    "maxBPM must be >= currentBPM; maxBPM=\(state.maxBPM), currentBPM=\(state.currentBPM)")
        XCTAssertGreaterThan(state.maxBPM, 0,
                             "maxBPM must be > 0 after beats; got \(state.maxBPM)")
    }

    /// TC27 — Feed beats → state.avgBPM > 0.
    func test_sessionAvgBPMTracked() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)
        for i in 0..<6 {
            clock.t = 1000.0 + Double(i) * 0.500
            detector.process(buffer: pulse)
        }

        await drainMainActor()
        XCTAssertGreaterThan(state.avgBPM, 0,
                             "avgBPM must be tracked after beats; got \(state.avgBPM)")
    }

    /// TC28 — Feed beats → reset() → drain → all session stats == 0.
    func test_resetClearsSessionStats() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)
        for i in 0..<5 {
            clock.t = 1000.0 + Double(i) * 0.500
            detector.process(buffer: pulse)
        }

        await drainMainActor()
        XCTAssertGreaterThan(state.minBPM, 0, "minBPM must be > 0 before reset")

        detector.reset()
        await drainMainActor()

        XCTAssertEqual(state.minBPM, 0,
                       "reset() must zero minBPM; got \(state.minBPM)")
        XCTAssertEqual(state.maxBPM, 0,
                       "reset() must zero maxBPM; got \(state.maxBPM)")
        XCTAssertEqual(state.avgBPM, 0,
                       "reset() must zero avgBPM; got \(state.avgBPM)")
    }

    // MARK: - Integrations (TC29–32)

    /// TC29 — Intervals at 1.0s (raw=60 BPM) → octave correction → ~120 BPM (±5 tolerance).
    func test_octaveCorrection2xApplied() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        // 1.000s interval → raw=60 BPM < 80 → corrected=120 BPM.
        for i in 0..<7 {
            clock.t = 1000.0 + Double(i) * 1.000
            detector.process(buffer: pulse)
        }

        await drainMainActor()
        XCTAssertGreaterThanOrEqual(state.currentBPM, 115,
                                    "Octave-corrected 60→120 BPM must be >= 115; got \(state.currentBPM)")
        XCTAssertLessThanOrEqual(state.currentBPM, 125,
                                 "Octave-corrected 60→120 BPM must be <= 125; got \(state.currentBPM)")
    }

    /// TC30 — Pulses at 0.350s intervals (171 BPM) blocked by refractory (400ms) → no BPM.
    func test_150BPMLimitViaRefractory() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        warmUp(detector)

        let pulse = makePCMBuffer(rms: 0.15)

        // All inter-pulse intervals are 0.350s < refractorySeconds(0.400)
        // → every subsequent pulse is rejected by the refractory guard.
        for i in 0..<10 {
            clock.t = 1000.0 + Double(i) * 0.350
            detector.process(buffer: pulse)
        }

        await drainMainActor()
        XCTAssertEqual(state.currentBPM, 0,
                       "Pulses at 350ms (< refractory 400ms) must all be blocked → BPM=0; got \(state.currentBPM)")
    }

    /// TC32 — Energy window filled with zeros (rms=0), then pulse at rms=0.05:
    ///         threshold guard (threshold > 0.001) prevents false onset.
    func test_thresholdGuardPreventsNoiseTrigger() async {
        let state = BeatState()
        let clock = FakeClock()
        let detector = BeatDetector(state: state, now: clock.now)

        // Fill energy window with silence (rms=0) → mean=0, std=0, threshold=0.
        let zeroBuf = makePCMBuffer(rms: 0.0)
        for _ in 0..<25 { detector.process(buffer: zeroBuf) }

        // Single pulse above minimumOnsetRms but threshold guard blocks it (threshold ≤ 0.001).
        clock.t = 1000.0
        let noisePulse = makePCMBuffer(rms: 0.05)
        detector.process(buffer: noisePulse)

        clock.t = 1000.500
        detector.process(buffer: noisePulse)

        clock.t = 1001.000
        detector.process(buffer: noisePulse)

        await drainMainActor()
        XCTAssertEqual(state.currentBPM, 0,
                       "Threshold guard must prevent onset when energy window history is all-zero; got \(state.currentBPM)")
    }
}
