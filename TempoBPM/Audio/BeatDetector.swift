import AVFoundation

// TBD-10: Onset detection con soglia dinamica adattiva
// TBD-11: Calcolo BPM con media mobile ultimi 4 battiti
final class BeatDetector {
    static let onsetMultiplier: Float = 1.5
    static let adaptiveAlpha: Float = 0.1
    static let bpmWindowSize: Int = 4
    static let bpmMin: Double = 40
    static let bpmMax: Double = 220
    static let refractoryMs: Double = 200

    init(state: BeatState) {
        // TODO: implementato dall'Audio Engineer Agent (TBD-2)
    }

    func process(buffer: AVAudioPCMBuffer) {
        // TODO: implementato dall'Audio Engineer Agent (TBD-2)
    }
}
