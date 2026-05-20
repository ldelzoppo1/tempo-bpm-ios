import SwiftUI
import UIKit

@main
struct TempoApp: App {

    @State private var beatState = BeatState()
    @State private var audioEngine: AudioEngine?
    @State private var beatDetector: BeatDetector?
    @State private var rhythmAnalyzer: RhythmAnalyzer?

    var body: some Scene {
        WindowGroup {
            ContentView(onToggle: toggleAudioPipeline)
                .environment(beatState)
                .task { startAudioPipeline() }
                .onChange(of: beatState.detectionMode) { _, mode in
                    beatDetector?.setMode(mode)
                }
        }
    }

    private func startAudioPipeline() {
        guard audioEngine == nil else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        let engine   = AudioEngine(state: beatState)
        let detector = BeatDetector(state: beatState)
        let analyzer = RhythmAnalyzer(state: beatState)
        audioEngine   = engine
        beatDetector  = detector
        rhythmAnalyzer = analyzer

        detector.onOnset = { [weak analyzer] timestamp, rms in
            analyzer?.registerOnset(timestamp: timestamp, rms: rms)
        }

        Task.detached(priority: .high) {
            try? engine.startCapture { buffer in
                detector.process(buffer: buffer)
            }
        }
    }

    private func stopAudioPipeline() {
        audioEngine?.stopCapture()
        beatDetector?.reset()
        rhythmAnalyzer?.reset()
        audioEngine    = nil
        beatDetector   = nil
        rhythmAnalyzer = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func toggleAudioPipeline() {
        if beatState.isListening {
            stopAudioPipeline()
        } else {
            startAudioPipeline()
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }
}
