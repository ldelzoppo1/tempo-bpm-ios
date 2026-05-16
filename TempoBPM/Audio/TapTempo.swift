import Foundation

// TBD-61: Tap Tempo — Input Manuale BPM (Audio layer)

final class TapTempo {

    // MARK: - Configuration

    /// Maximum number of inter-tap intervals kept in the rolling window.
    static let windowSize: Int = 4

    /// Minimum milliseconds between two taps — prevents accidental double-tap registration.
    static let refractoryMs: Double = 200

    /// Minimum valid BPM — intervals producing BPM below this are discarded.
    static let bpmMin: Double = 40

    /// Maximum valid BPM — intervals producing BPM above this are discarded.
    static let bpmMax: Double = 220

    /// Seconds of inactivity before the tap override on currentBPM is released.
    static let overrideTimeoutS: Double = 3.0

    /// Pause longer than this resets the tap sequence, treating the next tap as the first.
    static let resetPauseS: Double = 2.0

    // MARK: - Private state

    private weak var state: BeatState?
    private let now: () -> Double

    /// Refractory period in seconds — derived from refractoryMs to avoid repeated conversion.
    private let refractoryPeriod: Double = TapTempo.refractoryMs / 1000.0

    /// Sliding window of absolute timestamps (seconds). Max size is windowSize + 1
    /// so we always have enough pairs to compute windowSize intervals.
    private var tapTimestamps: [Double] = []

    private var lastTapTime: Double = 0
    private var overrideTask: Task<Void, Never>?

    // MARK: - Init

    init(state: BeatState, now: @escaping () -> Double = CFAbsoluteTimeGetCurrent) {
        self.state = state
        self.now = now
    }

    // MARK: - Public interface

    /// Records a tap from the UI and updates BeatState if a valid BPM can be computed.
    ///
    /// Must be called from the main thread. All BeatState writes happen via @MainActor.
    func registerTap() {
        let currentTime = now()

        // Refractory guard: ignore taps that arrive too soon after the previous one.
        if lastTapTime > 0 && currentTime - lastTapTime < refractoryPeriod {
            return
        }

        // Pause reset: a gap larger than resetPauseS means a new rhythmic phrase.
        // Clear the window so the next tap is treated as the very first of a new sequence.
        if lastTapTime > 0 && currentTime - lastTapTime > TapTempo.resetPauseS {
            tapTimestamps.removeAll()
            Task { @MainActor [weak state] in
                state?.tapCount = 0
                state?.tapBPM = 0
                state?.tapOverrideActive = false
            }
        }

        tapTimestamps.append(currentTime)
        // Keep only the timestamps needed to compute the last windowSize intervals.
        if tapTimestamps.count > TapTempo.windowSize + 1 {
            tapTimestamps.removeFirst()
        }

        lastTapTime = currentTime

        // At least two timestamps are required to compute one interval.
        guard tapTimestamps.count >= 2 else { return }

        // Compute average interval across consecutive timestamp pairs in the window.
        var intervalSum: Double = 0
        let count = tapTimestamps.count
        for i in 1 ..< count {
            intervalSum += tapTimestamps[i] - tapTimestamps[i - 1]
        }
        let avgInterval = intervalSum / Double(count - 1)
        let bpm = 60.0 / avgInterval

        guard bpm >= TapTempo.bpmMin && bpm <= TapTempo.bpmMax else { return }

        Task { @MainActor [weak state] in
            guard let state else { return }
            state.tapBPM = bpm
            state.currentBPM = bpm
            state.tapCount += 1
            state.tapOverrideActive = true
        }

        // Cancel any pending deactivation timer and start a fresh one.
        overrideTask?.cancel()
        overrideTask = Task { @MainActor [weak state] in
            try? await Task.sleep(nanoseconds: UInt64(TapTempo.overrideTimeoutS * 1_000_000_000))
            state?.tapOverrideActive = false
            state?.tapBPM = 0
        }
    }

    /// Resets all tap state and publishes cleared values to BeatState via @MainActor.
    func reset() {
        tapTimestamps.removeAll()
        lastTapTime = 0
        overrideTask?.cancel()
        overrideTask = nil
        Task { @MainActor [weak state] in
            state?.tapCount = 0
            state?.tapBPM = 0
            state?.tapOverrideActive = false
        }
    }
}
