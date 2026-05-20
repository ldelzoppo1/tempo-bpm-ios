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
1. RMS buffer corrente
        │
        ▼
2. Aggiorna finestra scorrevole energia (~22 campioni, ~1s)
        │
        ▼
3. Soglia = media_finestra + std_finestra × 0.7
        │
        ▼
4. RMS > soglia  AND  soglia > 0.001 ?
        │
       YES
        │
        ▼
5. Kick discrimination: LP@100Hz → kickRMS / totalRMS ≥ 0.28 ?
        │
       YES → onset confermato
        │
        ▼
6. Refrattario: Δt ≥ 300ms dal precedente onset ?
        │
       YES
        │
        ▼
7. Outlier rejection: |intervallo - mediana_ultimi_N| / mediana ≤ 40% ?
        │
       YES
        │
        ▼
8. Rolling window ultimi 4 intervalli → media → BPM
        │
        ▼
9. Pubblica su BeatState via @MainActor
        │
        ▼
10. Avvia/riavvia timer 3s: se nessun onset arriva, azzera currentBPM
```

**Parametri** (costanti in `BeatDetector`):
```swift
static var onsetSigma: Float      = 0.7    // soglia = media + std × onsetSigma
static var energyWindowSize: Int  = 22     // campioni finestra ~1s
static var refractorySeconds: Double = 0.300
static var maxIntervalSeconds: Double = 2.000
static var outlierThreshold: Double  = 0.40
static var bpmWindowSize: Int     = 4
static var kickRatioThreshold: Float = 0.28
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
