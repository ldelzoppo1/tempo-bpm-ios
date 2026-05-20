import Foundation

enum DetectionMode: Sendable, Equatable {
    case solo, live
}

@Observable
final class BeatState {
    // Written by BeatDetector/TapTempo, read by UI
    var currentBPM: Double = 0
    var recentBPMs: [Double] = []
    var minBPM: Double = 0
    var maxBPM: Double = 0
    var avgBPM: Double = 0
    var stability: Double = 0           // 0.0–1.0
    var energyBands: [Float] = []       // 46 values for waveform
    var kickEnergy: Float = 0           // RMS energy in 40–200 Hz band
    var isListening: Bool = false
    var beatFlash: Bool = false         // true for 100 ms per beat
    var beatPosition: Int = 0          // 0–3, cycles on every detected onset

    // Written by TapTempo
    var tapCount: Int = 0
    var tapBPM: Double = 0
    var tapOverrideActive: Bool = false

    // Written by CronoPanel (UI)
    var concertElapsed: TimeInterval = 0
    var concertRunning: Bool = false

    // Detection mode — switched by ModePanel
    var detectionMode: DetectionMode = .solo
}
