import Foundation

enum TimeSignatureOption: Int, CaseIterable, Identifiable {
    case three = 3
    case four  = 4
    case five  = 5
    case six   = 6
    case seven = 7

    var id: Int { rawValue }
    var label: String { "\(rawValue)/4" }
}

@Observable
final class BeatState {
    // Scritto da BeatDetector, letto da UI
    var currentBPM: Double = 0
    var recentBPMs: [Double] = []
    var minBPM: Double = 0
    var maxBPM: Double = 0
    var avgBPM: Double = 0
    var stability: Double = 0           // 0.0–1.0
    var energyBands: [Float] = []       // ~46 valori per la waveform
    var isListening: Bool = false
    var beatFlash: Bool = false         // true per 100ms ad ogni beat

    // Scritto da TapTempo
    var tapCount: Int = 0
    var tapBPM: Double = 0
    var tapOverrideActive: Bool = false

    // Scritto da CronoPanel (UI)
    var concertElapsed: TimeInterval = 0
    var concertRunning: Bool = false
    var timeSignature: TimeSignatureOption = .four

    // Scritto da BeatDetector (Audio layer) — la UI legge, non scrive mai
    var currentBeat: Int = 0
}
