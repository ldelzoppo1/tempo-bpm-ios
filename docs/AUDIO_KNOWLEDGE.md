# Knowledge Base — Audio Engineer

Documento di riferimento per l'Audio Engineer Agent. Contiene:
- Fisica del suono rilevante per il contesto dell'app
- Mappa diagnostica sintomo → causa → fix
- Lezioni apprese dai bug risolti in questo progetto
- Guida alla sensitività dei parametri DSP

Leggi questo documento **prima** di proporre modifiche all'algoritmo.

---

## 1. Fisica del suono — contesto Kickline

### Fondamentali degli strumenti target

| Strumento | Fondamentale | Armoniche principali | Note |
|-----------|-------------|----------------------|------|
| Grancassa (kick) | 40–80 Hz | 80–200 Hz (corpo) | Il fondamentale spesso non è catturato dal mic del telefono |
| Rullante (snare) | 150–250 Hz | 250–800 Hz (rimshot) | Attacco a 1.5–5 kHz — fuori banda, non interferisce |
| Tom basso | 60–120 Hz | 120–300 Hz | Simile al kick, difficile da distinguere in banda stretta |
| Tom medio/alto | 150–400 Hz | overlapping con snare | |
| Hi-hat (chiuso) | 5–10 kHz | — | Completamente fuori banda (< 250 Hz): non interferisce |
| Piatto (crash/ride) | 200–500 Hz | harmonics > 1 kHz | Corpo nella banda — può causare falsi positivi |

### Fisica della membrana del kick drum

Un colpo di cassa produce **due eventi sovrapposti**:

1. **Click del battente** (beater click): transiente broadband, durata 2–5 ms. Contiene energia su tutto lo spettro ma decade quasi istantaneamente. Non è il segnale che usiamo.

2. **Risonanza della membrana**: la testa percossa vibra nei suoi modi normali:
   - **Modo (0,1) — monopolare**: il modo fondamentale. Emette energia in modo molto efficiente → decade *rapidamente* trasferendo energia in pressione sonora. Questo è il fondamentale del kick (40–80 Hz).
   - **Modi superiori (1,1), (2,1), ...**: frequenze più alte (corpo 80–200 Hz), decadimento più lento perché radiano meno efficacemente. **Sono questi che BeatDetector rileva** attraverso la banda LP@100 Hz.

3. **Coda di risonanza del corpo**: la shell del tamburo e la testa anteriore continuano a vibrare per 300–600 ms (kick 20–22"). Produce il secondo picco energetico che holddown deve sopprimere.

**Conseguenza pratica**: il kick che rileva l'app non è il fondamentale puro, ma l'energia dei modi superiori della membrana nel range 80–200 Hz — quella parte dello spettro dove il mic iPhone ha ancora sensibilità accettabile.

### Spettro del rullante — dettaglio completo

Il rullante è una **sorgente broadband** senza un'unica frequenza dominante:

| Zona spettrale | Freq | Contenuto |
|---------------|------|-----------|
| Corpo / fondamentale | 150–250 Hz | Risonanza della testa battuta |
| Corpo medio | 250–800 Hz | Rimshot, armoniche della shell |
| Attacco / stick | 1.5–5 kHz | Impatto del colpo sul centro della testa |
| Sizzle (piattini) | 7–15 kHz | Vibrazione dei filetti metallici sotto la testa |

**Perché il filtro LP@100 Hz blocca il rullante**: il fondamentale del rullante (150–250 Hz) è già sopra il cutoff, e la sua energia sotto 100 Hz è < 5% del totale. Il `kickRatio` del rullante risulta tipicamente 0.05–0.15, ben sotto la soglia 0.35. L'attacco a 1.5–5 kHz è completamente fuori dalla banda di rilevamento (30–250 Hz).

### Risposta del microfono iPhone

Il mic interno iPhone applica un **filtro hardware low-cut con rolloff ~24 dB/ottava** a partire da circa 100–250 Hz (varia per generazione):

| Modello | –3 dB point | Comportamento |
|---------|-------------|---------------|
| iPhone 3GS | ~200 Hz | Rolloff molto severo — kick quasi inudibile |
| iPhone 6S–7 | ~50–60 Hz | Netto miglioramento; corpo kick ancora catturato |
| iPhone 10–15 | ~50–60 Hz | Stabile, variazione < 3 dB tra generazioni |

**Nota importante**: il filtro low-cut è configurabile via `AVAudioSession`. Con la categoria `.measurement` è disabilitato (risposta piatta sotto 100 Hz). Con `.playAndRecord` (la categoria che usa questa app) il filtro è **attivo**. Questo significa che l'attenuazione reale sotto 80 Hz è più severa di quanto indicato dalle specifiche hardware.

Conseguenze pratiche:
- **Il fondamentale della cassa (40–80 Hz) è fortemente attenuato o assente** nel segnale catturato
- L'app rileva in realtà la **banda corpo del kick: 80–200 Hz** (modi (1,1) e superiori)
- Il filtro LP@100 Hz separa questa banda da snare/tom che dominano sopra i 100 Hz
- **kickRatioThreshold = 0.35**: almeno 35% dell'energia 30–250 Hz deve stare sotto 100 Hz

Se in futuro si volesse aumentare la sensibilità al kick, una strada è passare ad `AVAudioSession.Category.measurement` — ma richiede un impatto sulla latenza audio da valutare.

### Acustica da palco vs. sala prove vs. ascolto casuale

| Contesto | Caratteristiche | Modalità consigliata |
|----------|----------------|----------------------|
| Batterista solo (sala prove) | Segnale diretto, kick dominante, poco riverbero | SOLO |
| Batterista su palco (amplificazione) | Monitor, cross-talk da altri strumenti, compressione | SOLO o LIVE |
| Ascolto da speaker (live venue) | Mix compresso, kick spesso sottolineato da PA | LIVE |
| Registrazione compressa (mp3, streaming) | Transienti smussati, livelli normalizzati | LIVE |

### Standing waves — rischio in sale prove piccole

In ambienti non trattati acusticamente, le **standing waves** (onde stazionarie) si formano alle frequenze:

```
f_n = n × c / (2L)    (c = 343 m/s, L = dimensione sala, n = 1, 2, 3...)
```

| Dimensione sala | Prima standing wave | Cade nella nostra banda? |
|----------------|--------------------|-----------------------|
| 3 m | 57 Hz | Sì — coincide con fondamentale kick |
| 5 m | 34 Hz | Sì — sotto banda ma risonanza nella shell |
| 8 m | 21 Hz | No — ma 2° armonica a 43 Hz sì |
| 15 m | 11 Hz | No |

Le standing waves producono un **ronzio stazionario a bassa frequenza** che si accumula nel buffer energetico e alza la baseline. Effetti:
- `minimumOnsetRms` potrebbe non filtrarlo (è un segnale continuo, non un picco)
- La soglia adattiva si alza → kick deboli vengono mancati
- In casi estremi: il ronzio può superare la soglia e generare onset fantasma

**Mitigazione attuale**: `energyWindowMaxSize = 64` buffer (~3s) → la baseline si adatta lentamente, ma il ronzio stazionario viene incluso nella media. Non c'è un fix perfetto a livello software; l'utente deve allontanarsi dalla parete o usare la modalità LIVE.

### Decadimento della cassa (decay / resonance)

Dopo un colpo di cassa, il diaframma della membrana continua a vibrare per 300–600 ms (kick da 20–22"). Questo produce un secondo picco energetico a ~350–500 ms dall'onset originale. Senza holddown, questo picco viene rilevato come secondo onset (BPM ≈ 130 su kick a 65 BPM).

**Soluzione implementata**: `holddownSeconds = 0.450` + `resonanceHolddownRatio = 0.20`.  
Il secondo onset viene accettato solo se la sua energia è ≥ 20% di quella del kick originale. Le risonanze tipicamente sono < 10–15% del picco; il rullante da 250–350 ms dopo il kick ha tipicamente 25–60% dell'energia del kick stesso → passa il filtro correttamente.

---

## 2. Mappa diagnostica — sintomo → causa → fix

Usa questa tabella come **primo punto di accesso** quando ricevi una segnalazione di comportamento errato. Prima di toccare il codice, esegui `tools/beat_simulator.py --verbose` per confermare la diagnosi.

### BPM sbagliato — valore

| Sintomo | Causa più probabile | Verifica | Fix |
|---------|---------------------|---------|-----|
| BPM = ~2× atteso | Kick rilevato su ogni colpo alternato (es. solo i colpi 1 e 3); octave correction porta a 2× | `--verbose`: intervalli ~750ms su pattern 4/4 a 160 BPM | Octave correction già attiva; controllare se `rawBPM < 80` è corretto. Potrebbe essere half-time feel voluto. |
| BPM = ~½ atteso | Half-time feel: kick ogni 2 beat (es. a 120 BPM il kick cade solo sui beat 1 e 3 → intervallo 1s → 60 BPM raw → octave correction → 120) | `--verbose`: intervalli ~1.0s | Comportamento corretto. Se non voluto, verificare la registrazione. |
| BPM oscilla ±10–20 | `outlierThreshold` troppo alto — accetta intervalli con alta varianza | `--verbose`: molti onset accettati con intervalli molto diversi | Abbassare `outlierThreshold` (es. 0.13 → 0.10). Usare `--calibrate`. |
| BPM stabile ma valore fisso sbagliato | Lock su BPM errato dopo warm-up con rumore | `--verbose`: pochi onset nei primi 3s, poi lock sul valore sbagliato | Aumentare `minimumOnsetRms` per filtrare il rumore di warm-up. |
| BPM corretto ma con lag di 2–3s | `energyWindowMaxSize` troppo grande → warm-up lento | `currentEffectiveWindowSize` rimane a 64 a lungo | Non cambiare il max; è normale nella fase iniziale senza BPM noto. |

### BPM non rilevato

| Sintomo | Causa più probabile | Fix |
|---------|---------------------|-----|
| Nessun onset dopo 5+ colpi forti | `minimumOnsetRms` troppo alto per il contesto | Abbassare `minimumOnsetRms` (es. 0.040 → 0.020). Testare in ambiente silenzioso. |
| Onset rilevati ma BPM = 0 | Meno di 2 intervalli validi nella rolling window | Normale durante il warm-up (primi 2 beat). Se persiste, outlier rejection troppo aggressivo. |
| Kick non passa il kick filter | `kickRatioThreshold` troppo alto per il mic/contesto | Abbassare (es. 0.35 → 0.28). Verificare con `--verbose` che `kickRatio` sia calcolato. |
| Solo mode non rileva su mix compresso | Il segnale filtrato HP+LP è troppo livellato — flux più informativo | Passare a modalità LIVE. |

### Falsi positivi (onset non voluti)

| Sintomo | Causa più probabile | Fix |
|---------|---------------------|-----|
| BPM rilevato in silenzio o rumore | `minimumOnsetRms` troppo basso | Alzare `minimumOnsetRms`. |
| Tom/piatto rilevato come kick | `kickRatioThreshold` troppo basso | Alzare `kickRatioThreshold` (es. 0.28 → 0.35). |
| Doppio onset su ogni kick | Holddown non funziona: secondo picco supera `resonanceHolddownRatio` | Alzare `resonanceHolddownRatio` (es. 0.20 → 0.30). Attenzione: potrebbe bloccare rullante ravvicinato. |
| BPM 2× su groove con snare forte | Snare a 250 ms dal kick classificato come onset | In Solo mode: kick filter deve bloccarlo. Verificare kickRatio del snare con `--verbose`. |

### Instabilità / jitter

| Sintomo | Causa più probabile | Fix |
|---------|---------------------|-----|
| BPM "balla" tra due valori vicini | EMA alpha troppo alto (bassa `rhythmConfidence`) | Lasciare che si accumuli confidenza. Se non converge: outlier rejection troppo permissivo. |
| Stabilità 0 anche con ritmo regolare | `onsetSigma` troppo basso → troppi onset → intervalli molto variabili | Alzare `onsetSigma` (es. 1.0 → 1.3). |
| BPM si congela su valore sbagliato dopo fill | `outlierThreshold` troppo basso → il fill abbatte `rhythmConfidence` troppo rapidamente | Non modificare: il comportamento è corretto. La confidenza si ricostruisce in 8–10 beat. |

---

## 3. Lezioni apprese — bug risolti in questo progetto

### Bug #1 — BPM 60 rilevato invece di 160 (kick + snare alternati)

**Sintomo**: su pattern 4/4 a 160 BPM, il BPM rilevato era ~75–80 (la metà).  
**Causa**: il rullante cade ~375 ms dopo il kick. Senza kick discrimination, veniva rilevato come secondo onset → intervallo di ~375 ms → BPM ≈ 160. Ma il kick *seguente* arrivava a ~375 ms dal rullante → l'algoritmo stimava ~375 ms come intervallo medio → 160 BPM. Il problema era il contrario: il rullante a 200–250 Hz era il segnale più forte nel buffer HP+LP, e **il kick veniva mancato** perché il suo fondamentale era sotto la soglia.  
**Fix**: aggiunta kick discrimination via LP@100 Hz. Solo onset con `kickRatio ≥ 0.35` (poi abbassato a 0.28, poi rialzato a 0.35 dopo test su device).

### Bug #2 — BPM dimezzato su brani con kick rado

**Sintomo**: su brani a 120–130 BPM con kick in half-time (ogni 2 beat), il BPM rilevato era ~60–65 (la metà).  
**Causa**: `kickRatioThreshold = 0.40` (valore originale) era troppo conservativo: molti kick legittimi a dinamica normale venivano filtrati, lasciando solo quelli fortissimi. Con kick rado + filtro aggressivo, gli intervalli erano ~2× il valore corretto.  
**Fix**: abbassato a 0.28, poi calibrato a 0.35. Aggiunta **octave correction**: se BPM raw < 80, moltiplica × 2.

### Bug #3 — Doppio onset sulla coda del kick

**Sintomo**: il detector rilevava 2 onset per ogni colpo di cassa su kit con lunga risonanza (membrana 22", in sala con poco smorzamento).  
**Causa**: il decadimento della cassa produceva un secondo picco energetico a ~350–450 ms dall'onset, sufficiente a superare la soglia adattiva.  
**Fix**: `holddownSeconds = 0.450` + `resonanceHolddownRatio = 0.20`. Il secondo picco (tipicamente < 15% dell'originale) viene bloccato; il rullante (tipicamente 30–60% del kick) passa.

### Bug #4 — BPM congelato su 120.0 dopo fill

**Sintomo**: dopo un fill di batteria, il BPM rimaneva bloccato sul valore precedente anche se il tempo era cambiato.  
**Causa**: EMA con alpha fisso (es. 0.85) convergeva lentamente dopo che `rhythmConfidence` era scesa per effetto degli outlier del fill.  
**Fix**: EMA adattiva `α = 0.85 − 0.25 × rhythmConfidence`. Con confidenza bassa (post-fill), α è alto → aggiornamento rapido al nuovo BPM. Con confidenza alta (ritmo stabile), α è basso → smoothing.

### Bug #5 — `outlierThreshold = 0.40` accettava troppo

**Sintomo**: il BPM oscillava tra valori molto diversi anche su ritmo regolare.  
**Causa**: 40% di tolleranza sulla mediana è eccessivo per un batterista professionista (che non supera il 5–8% di variazione). Il threshold lasciava passare onset non-kick che causavano intervalli errati.  
**Fix**: abbassato a 0.13 (13%). Un batterista umano può variare fino al 10–12% in situazioni estreme; 13% lascia margine senza aprire a falsi positivi.

---

## 4. Guida alla sensitività dei parametri

Prima di cambiare un parametro, leggi la riga corrispondente. Ogni parametro ha un effetto primario e uno o più effetti collaterali.

| Parametro | Effetto primario | Effetto collaterale se alzato | Effetto collaterale se abbassato |
|-----------|-----------------|-------------------------------|----------------------------------|
| `onsetSigma` | Soglia onset (in σ sopra la media) | Meno falsi positivi, ma manca onset deboli | Più onset, ma rischio di rumore e doppi onset |
| `outlierThreshold` | Tolleranza variazione inter-onset | Più robusto a swing/rubato, ma BPM meno preciso | Più stabile, ma esclude fill e cambi di tempo |
| `kickRatioThreshold` | Filtro snare/tom in Solo mode | Meno falsi positivi da snare, ma può escludere kick deboli | Più kick rilevati, ma snare e tom entrano come onset |
| `minimumOnsetRms` | Gate energetico assoluto | Filtra rumore ambiente, ma esclude kick soft | Più sensibile, ma attivabile da rumore o risonanza |
| `refractorySeconds` | Pausa minima tra onset | Blocca doppi onset, ma limita il BPM max rilevabile (max BPM = 60/refractory) | Più onset possibili, ma rischio doppi |
| `holddownSeconds` | Finestra anti-risonanza dopo onset | Blocca risonanze più lunghe, ma può escludere note ravvicinate | Meno protezione da risonanza |
| `resonanceHolddownRatio` | Energia minima per passare holddown | Blocca risonanze deboli E rullante debole | Solo le risonanze fortissime vengono bloccate |
| `energyWindowMaxSize` | Dimensione massima finestra energia | Warm-up più lento ma stima baseline più robusta | Warm-up veloce ma baseline instabile |
| `liveFluxSigma` | Soglia flux in modalità LIVE | Meno falsi positivi su segnale continuo | Più onset, ma rischio su parti sostenute |

### Vincoli derivati

- **BPM massimo rilevabile** = `60.0 / refractorySeconds` = 150 BPM con 400ms
- **BPM minimo prima di octave correction** = 80 (hardcoded nella octave correction logic)
- **Warm-up minimo** ≈ 3 frames per la soglia (vedi `guard energyWindowCount >= 3`)
- **Outlier rejection attivo** solo da 2+ intervalli nella rolling window

---

## 5. Procedure operative consigliate

### Prima di proporre una modifica parametrica

1. Identifica il sintomo nella mappa diagnostica (sezione 2)
2. Esegui `beat_simulator.py --audio <file> --known-bpm <N> --verbose` per confermare la diagnosi
3. Esegui `beat_simulator.py --calibrate` per trovare il valore ottimale
4. Verifica che la modifica non peggiori altri scenari (usa più file test se disponibili)
5. Documenta il motivo nel codice Swift accanto alla costante modificata

### Prima di aggiungere un nuovo stadio di filtering

1. Verifica che il problema non sia già coperto da un parametro esistente
2. Controlla la mappa symptom→fix: esiste già una soluzione nell'algoritmo corrente?
3. Il nuovo stadio va inserito **nell'ordine corretto** del pipeline (vedi sezione algoritmo in `audio-engineer.md`)
4. Ogni nuovo stadio deve avere un log `#if DEBUG` con il motivo del rifiuto

### Quando non toccare l'algoritmo

- Se il comportamento è corretto ma l'utente non lo riconosce (es. octave correction su half-time feel)
- Se il problema è nel contesto (stanza risonante, mic coperto) — non nel codice
- Se la variazione BPM è < 5 BPM su ritmo stabile — è normale anche con parametri ottimali

---

## 6. Teoria dell'onset detection — basi scientifiche

### Spectral flux vs. energy flux

**Spectral flux** (metodo accademico standard):
```
SF(n) = Σ_k  max(0,  |X(n,k)| − |X(n−1,k)|)
```
Somma delle differenze positive tra magnitudini spettrali di frame adiacenti. Rileva qualsiasi cambio nel contenuto spettrale, non solo l'aumento di energia complessiva. È il metodo usato da sistemi come BeatRoot (Dixon, 2001) e dalla maggior parte dei tracker in letteratura.

**Energy flux** (implementazione LIVE di questa app):
```
flux = max(0, rms_current − rms_previous)
```
Versione semplificata nel dominio temporale: rileva solo aumenti di energia RMS totale. Meno discriminante dello spectral flux completo, ma:
- Latenza minima: il calcolo è O(1) per frame
- Non richiede FFT per frame aggiuntive — il buffer 2048 @ 44100 Hz già produce ~46 ms di latenza
- Sufficiente per il segnale di cassa in un mix compresso, dove i transienti del kick producono un picco energetico netto

**Quando energy flux non basta**: su mix fortemente compressi o limitati, i transienti sono livellati → la derivata dell'energia RMS è quasi piatta. In questi casi la modalità LIVE perde efficacia. Soluzione futura potenziale: spectral flux sulla sola banda 30–250 Hz.

### Onset Detection Function (ODF) e soglia adattiva

L'algoritmo Solo usa una soglia adattiva classica:
```
threshold(n) = mean(energy_window) + sigma × std(energy_window)
```
Questo è equivalente a un z-score: onset rilevato quando l'energia corrente supera la media di `onsetSigma` deviazioni standard. Nella letteratura (Bello et al., 2005; Dixon, 2006), valori tipici di sigma sono 0.5–2.0 a seconda del tipo di segnale.

Il valore `onsetSigma = 1.0` è nella zona mediana: non troppo sensibile, non troppo conservativo. Per batterie acustiche con dinamica naturale (non compressa) è il valore ottimale empiricamente validato.

### Latenza minima del sistema

Con buffer di 2048 campioni @ 44100 Hz:
```
latenza_per_frame = 2048 / 44100 = 46.4 ms
```

Latenza end-to-end (da colpo di cassa a aggiornamento BPM):
- 1 frame di acquisizione: ~46 ms
- Processing DSP: < 1 ms (vDSP)
- Aggiornamento @MainActor: < 16 ms (next UI frame)
- **Totale: ~60–65 ms**

A 120 BPM (500 ms/beat), il lag di 65 ms rappresenta il 13% di un beat — percepibile ma accettabile per un'app di monitoraggio (non di metronomo). Un buffer più piccolo (es. 1024) dimezzherebbe la latenza a ~35 ms ma aumenterebbe il numero di frame al secondo e il carico CPU.

### Inter-onset interval (IOI) e stima BPM

La stima BPM da un singolo intervallo è rumorosa. L'algoritmo usa una rolling window di 4 intervalli con outlier rejection sulla mediana:
```
|IOI_i − median(IOI_window)| / median(IOI_window) > 0.13  →  outlier
```

Il valore 13% (0.13) corrisponde a ±39 ms su un beat da 300 ms (200 BPM) e ±78 ms su un beat da 600 ms (100 BPM). Studi su variabilità ritmica umana (Repp, 2005; London, 2012) mostrano che anche batteristi professionisti producono varianza di 10–20 ms per beat a 120 BPM → il 13% copre circa 4–6 deviazioni standard della varianza umana normale.

### EMA adattiva — motivazione

L'Exponential Moving Average con alpha fisso ha un problema noto: dopo un perturbazione (fill, pausa), converge lentamente al nuovo valore. La soluzione implementata (`α = 0.85 − 0.25 × rhythmConfidence`) è equivalente a un filtro passa-basso con frequenza di taglio variabile:
- Confidenza alta (0.8–1.0): α = 0.60–0.65 → smoothing aggressivo, BPM stabile
- Confidenza bassa (0.0–0.3): α = 0.77–0.85 → aggiornamento rapido, BPM insegue il cambio

Questo approccio è analogo al Kalman filter con varianza del processo adattiva, senza il costo computazionale.

---

## 7. Fonti bibliografiche

- Dixon, S. (2001). *Automatic extraction of tempo and beat from expressive performances.* Journal of New Music Research.
- Bello, J.P. et al. (2005). *A tutorial on onset detection in music signals.* IEEE TSAP.
- Repp, B.H. (2005). *Sensorimotor synchronization: A review of the tapping literature.* Psychonomic Bulletin & Review.
- London, J. (2012). *Hearing in Time: Psychological Aspects of Musical Meter.* Oxford University Press.
- Faber Acoustical Blog (2009). *iPhone Microphone Frequency Response Comparison.*
- Signal Essence (2023). *Can You Use an iPhone's Internal Microphone for Acoustic Testing?*
- iDrumTune (2024). *Guide To Mixing Drums — Know Your Drum Frequencies.*
- Penn State Acoustics (2017). *Vibrational Mode Shapes of a Circular Membrane.*
- ISMIR/TISMIR (2024). *A Real-Time Beat Tracking System with Zero Latency.*
