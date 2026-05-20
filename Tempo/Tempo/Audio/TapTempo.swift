import Foundation

final class TapTempo {

    private weak var state: BeatState?
    private var timestamps: [Double] = []
    private var resetTask: Task<Void, Never>?

    init(state: BeatState) {
        self.state = state
    }

    @MainActor func tap() {
        let t = CFAbsoluteTimeGetCurrent()
        if let last = timestamps.last, t - last > 3.0 { timestamps.removeAll() }
        timestamps.append(t)
        if timestamps.count > 8 { timestamps.removeFirst() }

        let count = timestamps.count
        state?.tapCount = count

        guard count >= 2 else { return }

        var sumIntervals = 0.0
        for i in 1..<count { sumIntervals += timestamps[i] - timestamps[i - 1] }
        let bpm = (60.0 / (sumIntervals / Double(count - 1)) * 10).rounded() / 10

        state?.tapBPM = bpm
        state?.currentBPM = bpm
        state?.tapOverrideActive = true

        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.state?.tapOverrideActive = false
        }
    }

    @MainActor func reset() {
        timestamps.removeAll()
        resetTask?.cancel()
        resetTask = nil
        state?.tapCount = 0
        state?.tapBPM = 0
        state?.tapOverrideActive = false
    }
}
