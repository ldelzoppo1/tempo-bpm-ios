# Tempo — Beat Detector (iOS)

App iOS per il rilevamento BPM in tempo reale, pensata per batteristi live.
Scritta in Swift/SwiftUI con AVAudioEngine + vDSP.

## Stack tecnico

- **Linguaggio**: Swift 5.9+
- **UI**: SwiftUI
- **Audio**: AVAudioEngine, AVAudioSession, vDSP (Accelerate framework)
- **Test**: XCTest
- **Deployment target**: iOS 17+
- **Architettura**: Observable pattern (`@Observable`) con separazione Audio/UI/Models

## Risorse chiave

- **Architettura**: `docs/ARCHITECTURE.md` — documento canonico di riferimento per tutti gli agenti
- **Jira**: `gardenworks.atlassian.net` — progetto `TBD` (cloud ID: `35eff5dd-e24b-4151-82e5-ae0d4aacc688`)
- **Figma**: file key `skEXOLj2h5Ady5OL3JmRIC` — pagina `Main Screen` (node `0:1`), frame principale `10:2`

## Epiche Jira

| Key    | Titolo                                          | Agente esecutivo        |
|--------|-------------------------------------------------|-------------------------|
| TBD-1  | Audio Engine — Pipeline AVAudioEngine           | Audio Engineer          |
| TBD-2  | Beat Detection — Algoritmo BPM Real-Time        | Audio Engineer          |
| TBD-3  | UI / Display — Interfaccia Live per Batteristi  | UI Agent                |
| TBD-4  | Metro Visivo — Sincronizzazione Beat e Time Sig | UI Agent                |
| TBD-5  | Tap Tempo — Input Manuale BPM                   | Audio Engineer + UI Agent |
| TBD-6  | Distribuzione — TestFlight, Firma e Setup iOS   | Orchestratore           |

## Team di agenti

Vedi `.claude/agents/` per le istruzioni complete di ogni agente.

```
Orchestratore
    ├── Planner/Architect  →  Reviewer (gate 1: plan review)
    ├── Audio Engineer Agent
    ├── UI Agent
    ├── QA Agent           →  Reviewer (gate 2: code + test review)
    └── Git Agent          (solo dopo gate 2)
```

**Flusso per ogni epica:**
1. Orchestratore legge Jira, attiva Planner sull'epica
2. Planner crea subtask tecnici su Jira con AC e specifiche
3. Reviewer valida il plan — approva o rimanda al Planner
4. Orchestratore assegna i task agli agenti esecutivi
5. Audio/UI Agent scrivono il codice, QA Agent scrive i test (in parallelo)
6. Reviewer valida codice + test — approva o rimanda
7. Git Agent committa con Conventional Commits e apre PR
8. Orchestratore aggiorna Jira e verifica DoD

## Struttura progetto

Il progetto Xcode è `Tempo/Tempo.xcodeproj`. Tutto il codice sorgente è in `Tempo/Tempo/`.

```
Tempo/
  Tempo.xcodeproj/           # progetto Xcode — unica fonte di verità
  Tempo/
    Audio/
      AudioEngine.swift        # AVAudioEngine pipeline, mic input, filtri, ring buffer
      BeatDetector.swift       # onset detection, kick discrimination, calcolo BPM
      TapTempo.swift           # input manuale tap, media intervalli
    UI/
      ContentView.swift        # root view, layout principale
      BPMPanel.swift           # display BPM grande, accent-bar, pills, dots, stabilità
      EnergyPanel.swift        # waveform energia bassa frequenza
      ModePanel.swift          # toggle SOLO / LIVE
      StatsRow.swift           # BPM min / max / avg
      TapPanel.swift           # pulsante TAP + contatore (gestisce TapTempo internamente)
      CronoPanel.swift         # orologio corrente + cronometro concerto
      TempoColors.swift        # token colore centralizzati
    Models/
      BeatState.swift          # stato condiviso @Observable
    TempoApp.swift             # @main, wiring pipeline audio
  TempoTests/
    BeatDetectorTests.swift    # test onset detection, holddown, outlier, confidence
    TapTempoTests.swift        # test calcolo BPM tap, override, auto-reset
    SPSCRingBufferTests.swift  # test ring buffer lock-free
```

## Architettura (sintesi)

Vedi `docs/ARCHITECTURE.md` per tutti i dettagli. Punti chiave:
- Stato condiviso via `@Environment(BeatState.self)` — mai singleton globale
- Thread audio → DSP queue → `@MainActor`: nessuna UI update dal thread audio
- Tap Tempo sovrascrive il BPM da microfono per 3s, poi ritorna automaticamente
- Beat detection su energia banda 30–250 Hz (kick drum) con kick discrimination LP@100Hz
- `Audio/` non importa SwiftUI; `UI/` non conosce AVAudioEngine

## Convenzioni

- **Commit**: Conventional Commits — `feat:`, `fix:`, `test:`, `refactor:`, `chore:`
- **Nomi**: PascalCase per tipi, camelCase per variabili e funzioni
- **Commenti**: solo quando il WHY non è ovvio dal codice
- **Nessun** codice di compatibilità retroattiva non necessario
- **Test**: in `Tempo/TempoTests/` — obbligatori per ogni funzione pubblica di `Audio/` e `Models/`
- **Review**: nessun codice entra nel repo senza approvazione del Reviewer

## Design Figma — schermata principale

Schermata unica `iPhone — TEMPO` (390×844). Sezioni dall'alto:

| Layer Figma     | Componente SwiftUI  | Descrizione                                    |
|-----------------|---------------------|------------------------------------------------|
| `header`        | —                   | Titolo "TEMPO" + indicatore "IN ASCOLTO"       |
| `bpm-panel`     | `BPMPanel`          | BPM grande, accent-bar, pills, dots, stabilità |
| `energy-panel`  | `EnergyPanel`       | Waveform energia bassa frequenza               |
| `stats-row`     | `StatsRow`          | BPM MIN · MAX · AVG                            |
| `tap-panel`     | `TapPanel`          | Pulsante TAP + header con contatore tap        |
| `clock-crono`   | `CronoPanel`        | ORA corrente + cronometro CONCERTO             |
| `crono-controls`| `CronoPanel`        | Bottoni START · STOP · RESET                   |
| `start-btn`     | `ContentView`       | Pulsante principale FERMA/AVVIA                |
