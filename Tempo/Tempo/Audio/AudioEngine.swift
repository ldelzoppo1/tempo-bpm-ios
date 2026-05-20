import AVFoundation
import Accelerate
import Darwin

// MARK: - AudioBufferProvider

protocol AudioBufferProvider: AnyObject {
    /// Registers the handler and starts audio capture.
    /// Must NOT be called from the main thread — uses a semaphore to await
    /// the microphone permission prompt synchronously.
    func startCapture(handler: @escaping (AVAudioPCMBuffer) -> Void) throws
    func stopCapture()
}

// MARK: - AudioEngineError

enum AudioEngineError: Error {
    case microphonePermissionDenied
    case engineStartFailed
}

// MARK: - SPSC Ring Buffer

/// Lock-free single-producer / single-consumer ring buffer for Float32 PCM samples.
///
/// Producer = AVAudioEngine tap callback (real-time thread): `write(_:count:)` is wait-free
/// and allocation-free. Consumer = dspQueue (serial): `read(into:count:)`.
///
/// Capacity must be a power of 2; wrap-around uses bitmasking instead of modulo.
/// Memory ordering is enforced via `atomic_thread_fence(memory_order_seq_cst)`.
private final class SPSCRingBuffer {

    // nonisolated(unsafe): all stored properties accessed from nonisolated real-time
    // threads; manual concurrency contract = single producer / single consumer.
    let capacity: Int
    nonisolated(unsafe) private let storage: UnsafeMutablePointer<Float>
    private let mask: Int
    nonisolated(unsafe) private var writeIndex: Int = 0
    nonisolated(unsafe) private var readIndex:  Int = 0

    init(capacity: Int) {
        precondition(capacity > 0 && (capacity & (capacity - 1)) == 0,
                     "SPSCRingBuffer: capacity must be a power of 2, got \(capacity)")
        self.capacity = capacity
        self.mask     = capacity - 1
        self.storage  = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        self.storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    // MARK: Producer API — real-time safe

    /// Writes up to `count` samples from `source`. Excess samples are silently dropped.
    nonisolated func write(_ source: UnsafePointer<Float>, count: Int) {
        let available = capacity - (writeIndex - readIndex)
        let toWrite   = min(count, max(0, available))
        guard toWrite > 0 else { return }

        let start = writeIndex & mask
        if start + toWrite <= capacity {
            (storage + start).update(from: source, count: toWrite)
        } else {
            let first = capacity - start
            (storage + start).update(from: source, count: first)
            storage.update(from: source + first, count: toWrite - first)
        }
        // store-release: make data visible to consumer before advancing writeIndex
        atomic_thread_fence(memory_order_seq_cst)
        writeIndex += toWrite
    }

    // MARK: Consumer API — dspQueue only

    @discardableResult
    nonisolated func read(into dest: UnsafeMutablePointer<Float>, count: Int) -> Int {
        // load-acquire: ensure data written before writeIndex advance is now visible
        atomic_thread_fence(memory_order_seq_cst)
        let filled = writeIndex - readIndex
        let toRead  = min(count, max(0, filled))
        guard toRead > 0 else { return 0 }

        let start = readIndex & mask
        if start + toRead <= capacity {
            dest.update(from: storage + start, count: toRead)
        } else {
            let first = capacity - start
            dest.update(from: storage + start, count: first)
            (dest + first).update(from: storage, count: toRead - first)
        }
        readIndex += toRead
        return toRead
    }

    nonisolated var availableSamples: Int { writeIndex - readIndex }
}

// MARK: - AudioEngine

/// AVAudioEngine pipeline for real-time kick-drum BPM detection.
///
/// ## Signal chain
/// ```
/// Mic (44.1 kHz, mono)
///   → ring buffer (lock-free, real-time thread)
///   → DSP queue: HP@30 Hz → LP@250 Hz → RMS + FFT(40–200 Hz)
///   → @MainActor: BeatState
/// ```
///
/// ## Threading contract
/// - The tap callback writes to the ring buffer only — no allocations, no locks.
/// - `drainRingBuffer()` runs exclusively on `dspQueue` (serial).
/// - All `BeatState` writes happen via `Task { @MainActor in … }`.
///
/// - Important: Call `start()` / `startCapture(handler:)` from a non-main thread
///   to avoid deadlocking the semaphore used for the microphone permission prompt.
final class AudioEngine: AudioBufferProvider, @unchecked Sendable {

    // MARK: DSP constants
    // Declared as nonisolated static computed properties so they are accessible
    // from nonisolated methods without actor-isolation constraints.

    private nonisolated static var tapBufferSize: AVAudioFrameCount { 2048 }

    /// 4 × tapBufferSize; must be a power of 2.
    private nonisolated static var ringCapacity: Int { 8192 }

    private nonisolated static var fftSize: Int { 1024 }
    private nonisolated static var fftLog2n: vDSP_Length { 10 }
    private nonisolated static var fftBinCount: Int { 512 }   // fftSize / 2
    private nonisolated static var energyBandCount: Int { 46 }

    /// Throttle energyBands updates to ≈ 60 ms (≈ 16 fps).
    private nonisolated static var energyThrottleInterval: Double { 0.060 }

    /// High-pass cutoff: removes DC offset and sub-30 Hz content.
    private nonisolated static var hpCutoffHz: Double { 30.0 }
    /// Low-pass cutoff: isolates kick drum fundamental + low harmonics.
    private nonisolated static var lpCutoffHz: Double { 250.0 }

    /// Kick drum FFT analysis band.
    private nonisolated static var kickLowHz:  Double { 40.0 }
    private nonisolated static var kickHighHz: Double { 200.0 }

    // MARK: Private state
    // nonisolated(unsafe): accessed from real-time / DSP threads, not MainActor.

    nonisolated(unsafe) private weak var state: BeatState?
    nonisolated(unsafe) private let avEngine = AVAudioEngine()
    // dspQueue and ringBuffer are let constants; DispatchQueue is Sendable, and
    // SPSCRingBuffer's own nonisolated methods handle its internal thread safety.
    private let dspQueue  = DispatchQueue(label: "com.tempo.dsp", qos: .userInteractive)
    private let ringBuffer: SPSCRingBuffer

    nonisolated(unsafe) private let drainBuffer: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private let fftBuffer:   UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var handlerPCMBuffer: AVAudioPCMBuffer?
    nonisolated(unsafe) private var captureHandler: ((AVAudioPCMBuffer) -> Void)?
    nonisolated(unsafe) private var notificationObservers: [NSObjectProtocol] = []

    // Biquad filter state — nil until start() has configured the session
    nonisolated(unsafe) private var hpSetup: vDSP_biquad_Setup?
    nonisolated(unsafe) private var lpSetup: vDSP_biquad_Setup?
    /// IIR delay buffers: 2 × sections + 2 = 4 elements for a single biquad section.
    /// Must persist across buffer boundaries to maintain IIR continuity.
    nonisolated(unsafe) private var hpDelay: [Float] = [0, 0, 0, 0]
    nonisolated(unsafe) private var lpDelay: [Float] = [0, 0, 0, 0]

    // FFT state — all pre-allocated in init, zero alloc in DSP loop
    nonisolated(unsafe) private var fftSetup: FFTSetup?
    nonisolated(unsafe) private var hannWindow: [Float]
    nonisolated(unsafe) private var fftWorkBuffer: [Float]
    nonisolated(unsafe) private var fftRealBuffer: [Float]
    nonisolated(unsafe) private var fftImagBuffer: [Float]
    nonisolated(unsafe) private var magnitudesBuffer: [Float]
    nonisolated(unsafe) private var lastEnergyTime: Double = 0

    /// FFT bin indices covering kickLowHz–kickHighHz. Set in computeKickBins().
    nonisolated(unsafe) private var kickBinLow:  Int = 1
    nonisolated(unsafe) private var kickBinHigh: Int = 5

    // MARK: Init / deinit

    init(state: BeatState) {
        self.state = state

        ringBuffer  = SPSCRingBuffer(capacity: AudioEngine.ringCapacity)
        let bufSize = Int(AudioEngine.tapBufferSize)
        drainBuffer = UnsafeMutablePointer<Float>.allocate(capacity: bufSize)
        drainBuffer.initialize(repeating: 0, count: bufSize)
        fftBuffer   = UnsafeMutablePointer<Float>.allocate(capacity: bufSize)
        fftBuffer.initialize(repeating: 0, count: bufSize)

        let fftSz    = AudioEngine.fftSize
        let binCount = AudioEngine.fftBinCount
        var hann = [Float](repeating: 0, count: fftSz)
        vDSP_hann_window(&hann, vDSP_Length(fftSz), Int32(vDSP_HANN_NORM))
        hannWindow       = hann
        fftWorkBuffer    = [Float](repeating: 0, count: fftSz)
        fftRealBuffer    = [Float](repeating: 0, count: binCount)
        fftImagBuffer    = [Float](repeating: 0, count: binCount)
        magnitudesBuffer = [Float](repeating: 0, count: binCount)

        fftSetup = vDSP_create_fftsetup(AudioEngine.fftLog2n, FFTRadix(kFFTRadix2))
    }

    deinit {
        if let hp  = hpSetup  { vDSP_biquad_DestroySetup(hp) }
        if let lp  = lpSetup  { vDSP_biquad_DestroySetup(lp) }
        if let fft = fftSetup { vDSP_destroy_fftsetup(fft) }
        drainBuffer.deallocate()
        fftBuffer.deallocate()
    }

    // MARK: AudioBufferProvider

    nonisolated func startCapture(handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        captureHandler = handler
        try start()
    }

    nonisolated func stopCapture() { stop() }

    // MARK: Public interface

    nonisolated func start() throws {
        try requestMicrophonePermission()
        try configureAudioSession()
        let sr = AVAudioSession.sharedInstance().sampleRate
        computeFilters(sampleRate: sr)
        computeKickBins(sampleRate: sr)
        installTap()
        do {
            try avEngine.start()
        } catch {
            avEngine.inputNode.removeTap(onBus: 0)
            throw AudioEngineError.engineStartFailed
        }
        setupObservers()
        Task { @MainActor [weak state] in state?.isListening = true }
    }

    nonisolated func stop() {
        teardownObservers()
        avEngine.inputNode.removeTap(onBus: 0)
        avEngine.stop()
        captureHandler = nil
        Task { @MainActor [weak state] in state?.isListening = false }
    }

    // MARK: Private — filter setup

    /// Computes RBJ-cookbook biquad coefficients for HP@30 Hz and LP@250 Hz.
    ///
    /// Butterworth (maximally-flat) Q = 1/√2.
    /// Layout expected by `vDSP_biquad_CreateSetup`: [b0/a0, b1/a0, b2/a0, a1/a0, a2/a0].
    /// No sign flip on a1/a2: vDSP's recurrence already subtracts them, matching RBJ.
    nonisolated private func computeFilters(sampleRate: Double) {
        let q = 1.0 / 2.0.squareRoot()

        func biquad(fc: Double, highPass: Bool) -> [Double] {
            let w0    = 2.0 * .pi * fc / sampleRate
            let cosW  = cos(w0)
            let alpha = sin(w0) / (2.0 * q)
            let a0    = 1.0 + alpha
            let a1    = -2.0 * cosW
            let a2    = 1.0 - alpha
            let b0, b1, b2: Double
            if highPass {
                b0 =  (1.0 + cosW) / 2.0
                b1 = -(1.0 + cosW)
                b2 =  (1.0 + cosW) / 2.0
            } else {
                b0 = (1.0 - cosW) / 2.0
                b1 =  1.0 - cosW
                b2 = (1.0 - cosW) / 2.0
            }
            return [b0/a0, b1/a0, b2/a0, a1/a0, a2/a0]
        }

        let hpCoeffs = biquad(fc: AudioEngine.hpCutoffHz, highPass: true)
        if let old = hpSetup { vDSP_biquad_DestroySetup(old) }
        hpSetup = vDSP_biquad_CreateSetup(hpCoeffs, 1)

        let lpCoeffs = biquad(fc: AudioEngine.lpCutoffHz, highPass: false)
        if let old = lpSetup { vDSP_biquad_DestroySetup(old) }
        lpSetup = vDSP_biquad_CreateSetup(lpCoeffs, 1)
    }

    /// Maps kickLowHz–kickHighHz to FFT bin indices at the given sample rate.
    nonisolated private func computeKickBins(sampleRate: Double) {
        let binWidth = sampleRate / Double(AudioEngine.fftSize)
        kickBinLow  = max(1, Int(AudioEngine.kickLowHz  / binWidth))
        kickBinHigh = min(AudioEngine.energyBandCount - 1,
                          Int(AudioEngine.kickHighHz / binWidth) + 1)
    }

    // MARK: Private — tap + DSP loop

    nonisolated private func installTap() {
        let inputNode  = avEngine.inputNode
        let format     = inputNode.inputFormat(forBus: 0)
        let frameCount = AudioEngine.tapBufferSize
        handlerPCMBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)

        inputNode.installTap(onBus: 0, bufferSize: frameCount, format: format) {
            [weak self] buffer, _ in
            // ── Real-time thread: zero alloc, zero lock ──────────────────────
            guard let self, let ch = buffer.floatChannelData else { return }
            self.ringBuffer.write(ch[0], count: Int(buffer.frameLength))
            self.dspQueue.async { [weak self] in self?.drainRingBuffer() }
        }
    }

    /// Drains the ring buffer and processes each batch through the DSP chain.
    /// Called exclusively from dspQueue (serial).
    nonisolated private func drainRingBuffer() {
        guard let handler  = captureHandler,
              let pcmBuf   = handlerPCMBuffer else { return }

        let batchSize = Int(AudioEngine.tapBufferSize)
        while ringBuffer.availableSamples >= batchSize {
            let read = ringBuffer.read(into: drainBuffer, count: batchSize)
            guard read > 0, let ch = pcmBuf.floatChannelData else { break }

            // Apply HP@30 Hz then LP@250 Hz in-place.
            // vDSP_biquad supports src == dst; delay buffers carry IIR state across blocks.
            if let hp = hpSetup, let lp = lpSetup {
                let n = vDSP_Length(read)
                vDSP_biquad(hp, &hpDelay, drainBuffer, 1, drainBuffer, 1, n)
                vDSP_biquad(lp, &lpDelay, drainBuffer, 1, drainBuffer, 1, n)
            }

            // Deliver filtered buffer to the capture handler (e.g. BeatDetector).
            // BORROW: handler must be synchronous and must not retain pcmBuf.
            ch[0].update(from: drainBuffer, count: read)
            pcmBuf.frameLength = AVAudioFrameCount(read)
            handler(pcmBuf)

            // FFT energy analysis — throttled to ≈ 60 ms
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastEnergyTime >= AudioEngine.energyThrottleInterval,
                  read >= AudioEngine.fftSize else { continue }
            fftBuffer.update(from: drainBuffer, count: read)
            computeAndPublishEnergy(buffer: fftBuffer, sampleCount: read, timestamp: now)
        }
    }

    /// Computes 46 FFT energy bands (full spectrum) and kick-drum band energy (40–200 Hz).
    /// All buffers are pre-allocated; no heap allocation in this path.
    /// `buffer` must be a caller-owned snapshot — it must not alias `drainBuffer`.
    nonisolated private func computeAndPublishEnergy(
        buffer: UnsafePointer<Float>, sampleCount: Int, timestamp: Double
    ) {
        guard let fft = fftSetup else { return }

        // Step 1 — Apply Hann window to the first fftSize samples.
        vDSP_vmul(buffer, 1, &hannWindow, 1, &fftWorkBuffer, 1,
                  vDSP_Length(AudioEngine.fftSize))

        // Steps 2–4 — Pack into split complex, run FFT, compute magnitudes.
        fftRealBuffer.withUnsafeMutableBufferPointer { realSlice in
            fftImagBuffer.withUnsafeMutableBufferPointer { imagSlice in
                guard let rp = realSlice.baseAddress,
                      let ip = imagSlice.baseAddress else { return }

                var split = DSPSplitComplex(realp: rp, imagp: ip)

                // Pack interleaved float pairs as split complex (required by vDSP_fft_zrip).
                fftWorkBuffer.withUnsafeBufferPointer { floatSlice in
                    guard let fp = floatSlice.baseAddress else { return }
                    fp.withMemoryRebound(to: DSPComplex.self,
                                         capacity: AudioEngine.fftBinCount) { cp in
                        vDSP_ctoz(cp, 1, &split, 1, vDSP_Length(AudioEngine.fftBinCount))
                    }
                }

                vDSP_fft_zrip(fft, &split, 1, AudioEngine.fftLog2n, FFTDirection(FFT_FORWARD))

                // Magnitudes for the first energyBandCount bins (visualization + kick analysis).
                magnitudesBuffer.withUnsafeMutableBufferPointer { magSlice in
                    guard let mp = magSlice.baseAddress else { return }
                    vDSP_zvabs(&split, 1, mp, 1, vDSP_Length(AudioEngine.energyBandCount))
                }
            }
        }

        // Step 5 — Kick band energy (40–200 Hz): mean magnitude in [kickBinLow, kickBinHigh).
        // Computed from raw (pre-normalization) magnitudes to capture absolute energy.
        var kickEnergyValue: Float = 0
        let kickCount = kickBinHigh - kickBinLow
        if kickCount > 0 {
            magnitudesBuffer.withUnsafeBufferPointer { magSlice in
                guard let mp = magSlice.baseAddress else { return }
                var sum: Float = 0
                vDSP_sve(mp + kickBinLow, 1, &sum, vDSP_Length(kickCount))
                kickEnergyValue = sum / Float(kickCount)
            }
        }

        // Step 6 — Normalize energy bands to [0, 1] for the waveform UI.
        var maxMag: Float = 0
        vDSP_maxv(magnitudesBuffer, 1, &maxMag, vDSP_Length(AudioEngine.energyBandCount))
        magnitudesBuffer.withUnsafeMutableBufferPointer { magSlice in
            guard let mp = magSlice.baseAddress else { return }
            if maxMag > 0 {
                var invMax = 1.0 / maxMag
                // In-place scale: single pointer avoids the overlapping-access violation
                // that arises from passing &magnitudesBuffer twice to vDSP_vsmul.
                vDSP_vsmul(mp, 1, &invMax, mp, 1, vDSP_Length(AudioEngine.energyBandCount))
            } else {
                var zero: Float = 0
                vDSP_vfill(&zero, mp, 1, vDSP_Length(AudioEngine.energyBandCount))
            }
        }

        lastEnergyTime = timestamp

        // Step 7 — Publish to BeatState on @MainActor.
        // Array copy happens on dspQueue before the Task, isolating DSP buffer lifetime
        // from the SwiftUI render cycle.
        let bands = Array(magnitudesBuffer.prefix(AudioEngine.energyBandCount))
        let kick  = kickEnergyValue
        Task { @MainActor [weak state] in
            state?.energyBands = bands
            state?.kickEnergy  = kick
        }
    }

    // MARK: Private — session setup

    /// Requests microphone permission synchronously via semaphore.
    /// Blocks until the system dialog is dismissed — must not be called from main thread.
    nonisolated private func requestMicrophonePermission() throws {
        let app = AVAudioApplication.shared
        switch app.recordPermission {
        case .granted:
            return
        case .denied:
            throw AudioEngineError.microphonePermissionDenied
        case .undetermined:
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            AVAudioApplication.requestRecordPermission { result in ok = result; sem.signal() }
            sem.wait()
            if !ok { throw AudioEngineError.microphonePermissionDenied }
        @unknown default:
            throw AudioEngineError.microphonePermissionDenied
        }
    }

    nonisolated private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.mixWithOthers, .allowBluetoothHFP])
        try session.setPreferredSampleRate(44100)
        try session.setPreferredIOBufferDuration(0.005)  // ≈ 5 ms latency
        try session.setActive(true)
    }

    // MARK: Private — interruption / route observers

    nonisolated private func setupObservers() {
        let shared = AVAudioSession.sharedInstance()
        let iObs = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: shared, queue: nil
        ) { [weak self] n in self?.handleInterruption(n) }

        let rObs = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: shared, queue: nil
        ) { [weak self] n in self?.handleRouteChange(n) }

        notificationObservers = [iObs, rObs]
    }

    nonisolated private func teardownObservers() {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
    }

    nonisolated private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let raw  = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            Task { @MainActor [weak state] in state?.isListening = false }

        case .ended:
            guard let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
            else { stop(); return }
            try? avEngine.start()
            Task { @MainActor [weak state] in state?.isListening = true }

        @unknown default:
            break
        }
    }

    nonisolated private func handleRouteChange(_ notification: Notification) {
        guard let info   = notification.userInfo,
              let raw    = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
              reason == .oldDeviceUnavailable else { return }
        stop()
    }
}
