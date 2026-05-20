# Architettura — Tempo BPM

Documento di riferimento per tutti gli agenti. Definisce le scelte architetturali, i confini tra moduli, le interfacce pubbliche e il modello di threading. Nessun agente può deviare da queste decisioni senza una revisione esplicita dell'architettura.

---

## Struttura del progetto

Il progetto Xcode si trova in `Tempo/Tempo.xcodeproj`. Il codice sorgente è in `Tempo/Tempo/`. I test sono in `Tempo/TempoTests/`.

```
Tempo/
  Tempo.xcodeproj/
  Tempo/
    Audio/
      AudioEngine.swift       # pipeline AVAudioEngine, microfono, filtri, ring buffer
      BeatDetector.swift      # onset detection, calcolo BPM, kick discrimination
      TapTempo.swift          # input manuale, override con timeout
    UI/
      ContentView.swift       # root view, @Environment injection
      BPMPanel.swift
      EnergyPanel.swift
      StatsRow.swift
      TapPanel.swift
      CronoPanel.swift
      TempoColors.swift       # token colore centralizzati
    Models/
      BeatState.swift         # stato condiviso @Observable
    TempoApp.swift            # @main, wiring pipeline audio
  TempoTests/
    TempoTests.swift
```

---

## Decisioni architetturali

| # | Decisione | Scelta | Alternativa scartata |
|---|-----------|--------|----------------------|
| 1 | Condivisione stato Audio→UI | `@Environment(BeatState.self)` | Singleton globale |
| 2 | Threading audio | DSP queue dedicata + `@MainActor` per UI | Aggiornamento diretto dal thread audio |
| 3 | Fusione Tap Tempo + microfono | Override con timeout (3s) | Media pesata |
| 4 | Algoritmo beat detection | Energia in banda bassa 30–250 Hz + kick discrimination | FFT full spectrum |
| 5 | Soglia onset | Finestra scorrevole media + σ×0.7 (~1s) | EMA adattiva |
| 6 | TapTempo ownership | Lazy @State in TapPanel — si auto-crea al primo tap | Iniettato dall'App |

---

## Struttura dei moduli

**Regola di dipendenza**: `UI` dipende solo da `Models`. `Audio` dipende solo da `Models`. `UI` e `Audio` non si conoscono direttamente.

```
Audio ──writes──► BeatState ◄──reads── UI
```

---

## BeatState — stato condiviso

`BeatState` è l'unico canale di comunicazione tra Audio e UI.

```swift
@Observable
final class BeatState {
    // Scritto da BeatDetector, letto da UI
    var currentBPM: Double = 0
    var recentBPMs: [Double] = []       // BPM individuali per le pills UI
    var minBPM: Double = 0
    var maxBPM: Double = 0
    var avgBPM: Double = 0
    var stability: Double = 0           // 0.0–1.0
    var energyBands: [Float] = []       // 46 valori per la waveform
    var kickEnergy: Float = 0           // RMS energia banda 40–200 Hz
    var isListening: Bool = false
    var beatFlash: Bool = false         // true per 100ms ad ogni beat

    // Scritto da TapTempo
    var tapCount: Int = 0
    var tapBPM: Double = 0
    var tapOverrideActive: Bool = false

    // Scritto da CronoPanel (UI)
    var concertElapsed: TimeInterval = 0
    var concertRunning: Bool = false
}
```

**Regole di scrittura**:
- `BeatState` viene scritto **solo sul `@MainActor`** (main thread)
- `Audio` calcola sul DSP thread, poi chiama `Task { @MainActor in state.currentBPM = ... }`
- La UI non scrive mai `currentBPM`, `recentBPMs`, `stability`, `energyBands`, `kickEnergy`

---

## Modello di threading

```
┌─────────────────────────────────────────────────────────┐
│  Thread audio real-time (AVAudioEngine tap callback)    │
│  • Lettura buffer PCM                                   │
│  • NESSUNA allocazione, NESSUN lock, NESSUNA ObjC call  │
│  • Copia buffer in ring buffer lock-free                │
└───────────────────┬─────────────────────────────────────┘
                    │ dati grezzi
                    ▼
┌─────────────────────────────────────────────────────────┐
│  DSP DispatchQueue (serial, QoS: .userInteractive)      │
│  • Filtro HP@30Hz + LP@250Hz (vDSP biquad)              │
│  • Calcolo energia RMS (vDSP_rmsqv)                     │
│  • Onset detection + kick discrimination                │
│  • Calcolo BPM (media mobile ultimi 4 onset)            │
│  • Calcolo 46 bande energia per waveform                │
└───────────────────┬─────────────────────────────────────┘
                    │ solo quando c'è un beat o ogni ~60ms
                    ▼
┌─────────────────────────────────────────────────────────┐
│  @MainActor (main thread)                               │
│  • Aggiornamento BeatState                              │
│  • SwiftUI re-render                                    │
└─────────────────────────────────────────────────────────┘
```

---

## Pipeline audio

```
Microfono (44.1 kHz, mono)
    │
    ▼ AVAudioEngine inputNode tap (bufferSize: 2048)
    │
    ▼ Ring buffer lock-free (SPSC, capacità 4×bufferSize)
    │
    ▼ DSP Queue
    │
    ├─► Filtro HP@30Hz + LP@250Hz (vDSP biquad) → buffer filtrato
    │
    ├─► Calcolo RMS energia (vDSP_rmsqv) → onset detection
    │
    └─► Calcolo 46 bande energia (downsampling) → waveform UI
```

**Configurazione AVAudioSession**:
```swift
category: .playAndRecord
mode: .measurement
options: [.mixWithOthers, .allowBluetooth]
sampleRate: 44100
ioBufferDuration: 0.005  // ~5ms latenza
```

---

## Algoritmo beat detection

```
Modalità SOLO (sala prove, batterista da solo)
──────────────────────────────────────────────
1. RMS buffer corrente (vDSP_rmsqv)
2. Gate: rms < 0.040 (minimumOnsetRms) → scarta
3. Finestra scorrevole adattiva: size = 4 × buffersPerBeat, clamp [22, 64]
4. Soglia = media_finestra + std_finestra × 1.0 (onsetSigma)
5. rms ≤ soglia → scarta
6. Refrattario: Δt < 400ms → scarta  (max 150 BPM)
7. Holddown anti-risonanza: Δt < 450ms  AND  rms < lastOnsetRms × 0.20 → scarta
8. Kick filter LP@100Hz: kickRMS / totalRMS < 0.35 → scarta
9. Outlier rejection: |IOI − mediana_ultimi_4| / mediana > 13% → scarta
        (abbassa rhythmConfidence di 0.3 su outlier)
10. Octave correction: rawBPM < 80 → rawBPM × 2
11. rhythmConfidence += 0.12  (cap 1.0)
12. EMA adattiva: α = 0.85 − 0.25 × rhythmConfidence → currentBPM
13. Pubblica su BeatState via @MainActor
14. beatResetTask: nessun onset per 3s → azzera currentBPM

Modalità LIVE (palco con altri strumentisti, noise floor alto)
──────────────────────────────────────────────────────────────
Stesso gate RMS (minimumOnsetRms) e stessa finestra adattiva.
flux = max(0, rms − prevRMS)   ← derivata positiva dell'energia
Soglia flux = media_flux + std_flux × 1.5 (liveFluxSigma)
flux > soglia → onset  (stesso refrattario + holddown, senza kick filter)
```

**Parametri** (costanti in `BeatDetector`):
```swift
onsetSigma:             Float  = 1.0    // soglia = media + std × onsetSigma
energyWindowSize:       Int    = 22     // minimo (BPM alti, ~1s)
energyWindowMaxSize:    Int    = 64     // massimo (warm-up / BPM bassi, ~3s)
refractorySeconds:      Double = 0.400  // max 150 BPM (60 / 0.400)
holddownSeconds:        Double = 0.450  // finestra anti-risonanza cassa
resonanceHolddownRatio: Float  = 0.20   // energia minima per superare holddown
maxIntervalSeconds:     Double = 2.000
outlierThreshold:       Double = 0.13   // 13% dalla mediana (varianza umana ~10%)
bpmWindowSize:          Int    = 4
minimumOnsetRms:        Float  = 0.040  // gate energetico assoluto
liveFluxSigma:          Float  = 1.5
kickCutoffHz:           Double = 100.0
kickRatioThreshold:     Float  = 0.35   // Solo mode: energia kick / energia totale
```

---

## Tap Tempo

```
Utente tappa TapPanel
    │
    ▼
TapPanel.button action → TapTempo.tap()   (lazy @State, creato al primo tap)
    │
    ▼
Pausa > 3s dall'ultimo tap? → azzera sequenza timestamps
    │
    ▼
≥ 2 tap → BPM = 60 / media_intervalli (arrotondato a 1 decimale)
    │
    ▼
BeatState.tapOverrideActive = true
BeatState.currentBPM = tapBPM     ← sovrascrive il BPM da microfono
BeatState.tapCount = N
    │
    ▼
Task.sleep(3s) senza nuovi tap
    │
    ▼
BeatState.tapOverrideActive = false   ← BeatDetector riprende il controllo
```

**Regola di fusione in `BeatDetector.publishBeatState`**:
- Se `tapOverrideActive == true` → non aggiornare `currentBPM`
- Se `tapOverrideActive == false` → aggiorna `currentBPM` normalmente

---

## Interfacce pubbliche tra moduli

### AudioEngine
```swift
final class AudioEngine {
    init(state: BeatState)
    func startCapture(handler: @escaping (AVAudioPCMBuffer) -> Void) throws
    func stopCapture()
}
```

### BeatDetector
```swift
final class BeatDetector {
    init(state: BeatState, now: @escaping () -> Double = CFAbsoluteTimeGetCurrent)
    func process(buffer: AVAudioPCMBuffer)  // chiamato dalla DSP queue, sincrono
    func reset()
    var currentThreshold: Float { get }    // esposto per i test
}
```

### TapTempo
```swift
final class TapTempo {
    init(state: BeatState)
    func tap()    // chiamato da TapPanel (main thread)
    func reset()
}
```

### TempoApp — wiring
```swift
@main struct TempoApp: App {
    @State private var beatState = BeatState()
    @State private var audioEngine: AudioEngine?
    @State private var beatDetector: BeatDetector?

    // startAudioPipeline(), stopAudioPipeline(), toggleAudioPipeline()
    // TapTempo è gestito da TapPanel internamente (lazy @State)
}
```

---

## DoD architetturale (Definition of Done)

Ogni PR deve rispettare:
- [ ] Nessun accesso a `BeatState` fuori dal `@MainActor`
- [ ] Nessuna chiamata UI dal thread audio o dalla DSP queue
- [ ] Nessun `BeatDetector` o `TapTempo` che conosce tipi SwiftUI
- [ ] Nessun `import SwiftUI` in `Audio/`
- [ ] I parametri DSP sono costanti named, non magic numbers
- [ ] Ogni modifica all'algoritmo è accompagnata da test in `Tempo/TempoTests/`
