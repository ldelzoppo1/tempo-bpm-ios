# Architettura — Tempo BPM

Documento di riferimento per tutti gli agenti. Definisce le scelte architetturali, i confini tra moduli, le interfacce pubbliche e il modello di threading. Nessun agente può deviare da queste decisioni senza una revisione esplicita dell'architettura.

---

## Decisioni architetturali

| # | Decisione | Scelta | Alternativa scartata |
|---|-----------|--------|----------------------|
| 1 | Condivisione stato Audio→UI | `@Environment(BeatState.self)` | Singleton globale |
| 2 | Threading audio | Queue DSP dedicata + `@MainActor` per UI | Aggiornamento diretto dal thread audio |
| 3 | Fusione Tap Tempo + microfono | Override con timeout (3s) | Media pesata |
| 4 | Algoritmo beat detection | Energia in banda bassa 20–200 Hz | FFT full spectrum |

---

## Struttura dei moduli

```
TempoBPM/
  Audio/
    AudioEngine.swift       # pipeline AVAudioEngine, microfono, filtri
    BeatDetector.swift      # onset detection, calcolo BPM
    TapTempo.swift          # input manuale, override con timeout
  UI/
    ContentView.swift       # root view, @Environment injection
    BPMPanel.swift
    EnergyPanel.swift
    StatsRow.swift
    TapPanel.swift
    CronoPanel.swift
  Models/
    BeatState.swift         # stato condiviso @Observable
TempoBPMTests/
  AudioEngineTests.swift
  BeatDetectorTests.swift
  TapTempoTests.swift
```

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
    // Scritto da BeatDetector / TapTempo, letto da UI
    var currentBPM: Double = 0
    var recentBPMs: [Double] = []       // ultimi 4 valori (pills)
    var minBPM: Double = 0
    var maxBPM: Double = 0
    var avgBPM: Double = 0
    var stability: Double = 0           // 0.0–1.0, barra stabilità
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
}
```

**Regole di scrittura**:
- `BeatState` viene scritto **solo sul `@MainActor`** (main thread)
- `Audio` calcola sul DSP thread, poi chiama `Task { @MainActor in state.currentBPM = ... }`
- La UI non scrive mai `currentBPM`, `recentBPMs`, `stability`, `energyBands`

---

## Modello di threading

```
┌─────────────────────────────────────────────────────────┐
│  Thread audio real-time (AVAudioEngine tap callback)    │
│  • Lettura buffer PCM                                   │
│  • NESSUNA allocazione, NESSUN lock, NESSUNA ObjC call  │
│  • Copia buffer in un ring buffer lock-free             │
└───────────────────┬─────────────────────────────────────┘
                    │ dati grezzi
                    ▼
┌─────────────────────────────────────────────────────────┐
│  DSP DispatchQueue (serial, QoS: .userInteractive)      │
│  • Filtro passa-basso 20–200 Hz (vDSP biquad)           │
│  • Calcolo energia RMS (vDSP_rmsqv)                     │
│  • Onset detection + soglia adattiva                    │
│  • Calcolo BPM (media mobile ultimi 4 onset)            │
│  • Calcolo bande energia per waveform                   │
└───────────────────┬─────────────────────────────────────┘
                    │ solo quando c'è un beat o ogni ~60ms
                    ▼
┌─────────────────────────────────────────────────────────┐
│  @MainActor (main thread)                               │
│  • Aggiornamento BeatState                              │
│  • SwiftUI re-render                                    │
└─────────────────────────────────────────────────────────┘
```

**Frequenza aggiornamenti UI**:
- `currentBPM`, `recentBPMs`, `stability`: ad ogni beat rilevato
- `energyBands`: ogni ~60ms (≈16 fps, sufficiente per la waveform animata)
- `beatFlash`: `true` ad ogni beat, ritorna `false` dopo 100ms

---

## Pipeline audio (TBD-1)

```
Microfono (44.1 kHz, mono)
    │
    ▼ AVAudioEngine inputNode tap (bufferSize: 2048)
    │
    ▼ Copia in ring buffer (lock-free, sul thread real-time)
    │
    ▼ DSP Queue legge il ring buffer
    │
    ├─► Filtro DC offset (passa-alto > 20 Hz, vDSP biquad)
    │
    ├─► Filtro passa-basso 200 Hz (isola banda kick drum, vDSP biquad)
    │
    ├─► Calcolo RMS energia (vDSP_rmsqv) → per onset detection
    │
    └─► Calcolo 46 bande energia (vDSP_desamp) → per waveform UI
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

## Algoritmo beat detection (TBD-2)

```
energia RMS corrente
        │
        ▼
  energia > soglia × 1.5 ?
        │
       YES → onset rilevato
        │
        ▼
  Δt dall'onset precedente → intervallo in millisecondi
        │
        ▼
  40 BPM < (60000 / Δt) < 220 BPM ?  → se no, scarta
        │
       YES
        │
        ▼
  buffer ultimi 4 intervalli → media → BPM corrente
        │
        ▼
  aggiorna soglia adattiva:
  soglia = soglia × 0.9 + energiaCorrente × 0.1
```

**Parametri configurabili** (costanti in `BeatDetector`):
```swift
static let onsetMultiplier: Float = 1.5   // soglia = media × 1.5
static let adaptiveAlpha: Float = 0.1     // velocità adattamento soglia
static let bpmWindowSize: Int = 4         // media mobile ultimi N beat
static let bpmMin: Double = 40
static let bpmMax: Double = 220
static let refractoryMs: Double = 200     // minimo tra due onset (anti-rimbalzo)
```

---

## Tap Tempo — override con timeout (TBD-5)

```
Utente tappa
    │
    ▼
TapTempo registra timestamp (CFAbsoluteTimeGetCurrent())
    │
    ▼
≥ 2 tap → calcola media intervalli → tapBPM
    │
    ▼
BeatState.tapOverrideActive = true
BeatState.currentBPM = tapBPM     ← sovrascrive il BPM da microfono
    │
    ▼
Timer di 3s si (ri)avvia ad ogni tap
    │
    ▼ timer scaduto
BeatState.tapOverrideActive = false
BeatState.currentBPM = bpmDaMicrofono  ← ritorna al microfono
```

**Regola di fusione in `BeatDetector`**:
- Se `tapOverrideActive == true` → non aggiornare `currentBPM` (il tap ha priorità)
- Se `tapOverrideActive == false` → aggiorna `currentBPM` normalmente

---

## Interfacce pubbliche tra moduli

### AudioEngine (pubblico)
```swift
final class AudioEngine {
    func start() throws
    func stop()
}
```

### BeatDetector (pubblico)
```swift
final class BeatDetector {
    init(state: BeatState)
    func process(buffer: AVAudioPCMBuffer)  // chiamato dalla DSP queue
}
```

### TapTempo (pubblico)
```swift
final class TapTempo {
    init(state: BeatState)
    func registerTap()         // chiamato dalla UI (main thread)
    func reset()
}
```

### ContentView — injection root
```swift
@main struct TempoBPMApp: App {
    @State private var beatState = BeatState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(beatState)
        }
    }
}
```

---

## Protocolli per testabilità

Il QA Agent usa questi protocolli per mockare le dipendenze nei test:

```swift
protocol AudioBufferProvider {
    func startCapture(handler: @escaping (AVAudioPCMBuffer) -> Void) throws
    func stopCapture()
}

// AudioEngine implementa AudioBufferProvider
// MockAudioBufferProvider usato nei test
```

---

## DoD architetturale (Definition of Done)

Ogni PR deve rispettare:
- [ ] Nessun accesso a `BeatState` fuori dal `@MainActor`
- [ ] Nessuna chiamata UI dal thread audio o dalla DSP queue
- [ ] Nessun `BeatDetector` o `TapTempo` che conosce tipi SwiftUI
- [ ] Nessun `import SwiftUI` in `Audio/`
- [ ] Ogni classe pubblica di `Audio/` è mockabile via protocollo
- [ ] I parametri DSP sono costanti named, non magic numbers
