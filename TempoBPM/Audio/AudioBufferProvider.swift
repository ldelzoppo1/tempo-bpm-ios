import AVFoundation

/// Protocollo per l'astrazione della pipeline audio — consente il mock nei test.
protocol AudioBufferProvider {
    func startCapture(handler: @escaping (AVAudioPCMBuffer) -> Void) throws
    func stopCapture()
}
