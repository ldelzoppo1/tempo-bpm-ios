import Foundation

#if DEBUG
import OSLog
private let tpLogger = Logger(subsystem: "com.ldelzoppo.tempo", category: "TempoPredictor")
#endif

/// Predice il timing del prossimo beat una volta che il BPM è stabile per
/// almeno `requiredStableBeats` beat consecutivi (default: 4).
///
/// Impulsi fuori dalla finestra di tolleranza (±15%) vengono segnalati come
/// fill o rumore tramite `validate(onsetTime:)`.
///
/// Il predictor è chiamato da BeatDetector su ogni onset valido.
/// Scrive `predictedNextBeatTime` su BeatState via @MainActor.
final class TempoPredictor {

    static let requiredStableBeats: Int = 4
    static let toleranceRatio: Double = 0.15  // ±15% dell'intervallo medio

    private weak var state: BeatState?
    private var stableCount: Int = 0
    private var lastOnsetTime: Double = 0
    private var predictedInterval: Double = 0

    init(state: BeatState) {
        self.state = state
    }

    /// Registra un onset e aggiorna la predizione.
    ///
    /// - Parameter time: CFAbsoluteTimeGetCurrent() al momento dell'onset.
    /// - Parameter meanInterval: intervallo medio corrente (da BeatDetector) in secondi.
    /// - Returns: `true` se l'onset è nella finestra predetta o non c'è ancora predizione,
    ///            `false` se è fuori finestra (fill / rumore).
    @discardableResult
    func register(onsetTime time: Double, meanInterval: Double) -> Bool {
        defer { lastOnsetTime = time }

        guard predictedInterval > 0 && lastOnsetTime > 0 else {
            // Ancora in warm-up: accetta l'onset e inizia a tracciare
            updatePrediction(meanInterval: meanInterval, stableCount: stableCount + 1)
            stableCount = min(stableCount + 1, BeatDetector.ioiWindowSize)
            return true
        }

        let expectedTime = lastOnsetTime + predictedInterval
        let tolerance = predictedInterval * TempoPredictor.toleranceRatio
        let inWindow = abs(time - expectedTime) <= tolerance

        #if DEBUG
        if predictedInterval > 0 {
            if inWindow {
                tpLogger.debug("🎯 in-window — expected=\(expectedTime, format: .fixed(precision: 3)) ±\(tolerance, format: .fixed(precision: 3))s")
            } else {
                tpLogger.debug("🎲 out-of-window — fill? expected=\(expectedTime, format: .fixed(precision: 3)) got=\(time, format: .fixed(precision: 3))")
            }
        }
        #endif

        if inWindow {
            stableCount = min(stableCount + 1, TempoPredictor.requiredStableBeats + 2)
        } else {
            // Onset fuori finestra: fill o rumore
            stableCount = max(0, stableCount - 1)
        }

        updatePrediction(meanInterval: meanInterval, stableCount: stableCount)
        return inWindow
    }

    func reset() {
        stableCount = 0
        lastOnsetTime = 0
        predictedInterval = 0
        Task { @MainActor [weak state] in
            self.state?.predictedNextBeatTime = 0
        }
    }

    private func updatePrediction(meanInterval: Double, stableCount: Int) {
        guard stableCount >= TempoPredictor.requiredStableBeats,
              meanInterval > 0 else { return }
        predictedInterval = meanInterval
        let nextBeat = lastOnsetTime + predictedInterval
        Task { @MainActor [weak state] in
            self.state?.predictedNextBeatTime = nextBeat
        }
    }
}
