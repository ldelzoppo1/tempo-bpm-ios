import AVFoundation

// TBD-7: Setup progetto Xcode con AVAudioEngine
// TBD-8: Implementazione filtri audio passa-alto e passa-basso
// TBD-9: FFT real-time su thread dedicato con Accelerate/vDSP
final class AudioEngine: AudioBufferProvider {
    func start() throws {
        // TODO: implementato dall'Audio Engineer Agent (TBD-1)
    }

    func stop() {
        // TODO: implementato dall'Audio Engineer Agent (TBD-1)
    }

    func startCapture(handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        // TODO: implementato dall'Audio Engineer Agent (TBD-1)
    }

    func stopCapture() {
        // TODO: implementato dall'Audio Engineer Agent (TBD-1)
    }
}
