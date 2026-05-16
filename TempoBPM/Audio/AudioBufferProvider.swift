import AVFoundation

/// Protocollo per l'astrazione della pipeline audio — consente il mock nei test.
protocol AudioBufferProvider {
    /// Registra l'handler e avvia la cattura audio.
    ///
    /// - Parameter handler: Closure invocata dalla DSP queue per ogni buffer PCM prodotto.
    /// - Throws: `AudioEngineError.microphonePermissionDenied` o `engineStartFailed`.
    /// - Important: Il buffer passato all'handler è riutilizzabile (borrow semantics).
    ///   L'handler deve essere sincrono. Non trattenere il riferimento al buffer
    ///   oltre il ritorno della chiamata — il suo contenuto può essere sovrascritto.
    func startCapture(handler: @escaping (AVAudioPCMBuffer) -> Void) throws
    func stopCapture()
}
