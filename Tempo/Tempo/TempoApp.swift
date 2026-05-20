import SwiftUI
import UIKit

@main
struct TempoApp: App {

    @State private var beatState = BeatState()
    @State private var audioEngine: AudioEngine?
    @State private var beatDetector: BeatDetector?

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
        let engine   = AudioEngine(state: beatState)
        let detector = BeatDetector(state: beatState)
        audioEngine   = engine
        beatDetector  = detector

        Task.detached(priority: .high) {
            try? engine.startCapture { buffer in
                detector.process(buffer: buffer)
            }
        }
    }

    private func stopAudioPipeline() {
        audioEngine?.stopCapture()
        beatDetector?.reset()
        audioEngine  = nil
        beatDetector = nil
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
