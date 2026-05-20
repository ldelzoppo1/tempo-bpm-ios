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
| Rullante (snare) | 150–250 Hz | 250–800 Hz (rimshot) | Picco energetico ben sopra il kick |
| Tom basso | 60–120 Hz | 120–300 Hz | Simile al kick, difficile da distinguere in banda stretta |
| Tom medio/alto | 150–400 Hz | overlapping con snare | |
| Hi-hat (chiuso) | 5–10 kHz | — | Completamente fuori banda (< 250 Hz): non interferisce |
| Piatto (crash/ride) | 200–500 Hz | harmonics > 1 kHz | Corpo nella banda — può causare falsi positivi |

### Risposta del microfono iPhone

Il mic integrale iPhone ha un roll-off naturale sotto ~120 Hz (guadagno ridotto di ~6–12 dB a 80 Hz rispetto a 200 Hz). Conseguenza pratica:
- **Il fondamentale della cassa (40–80 Hz) è attenuato o assente** nel segnale catturato
- Quello che BeatDetector chiama "kick" rileva in realtà la **banda corpo del kick: 80–200 Hz**
- Il filtro LP@100 Hz separa questa banda da snare/tom che dominano sopra i 100 Hz
- **kickRatioThreshold = 0.35** significa: almeno 35% dell'energia 30–250 Hz deve stare sotto 100 Hz

### Acustica da palco vs. sala prove vs. ascolto casuale

| Contesto | Caratteristiche | Modalità consigliata |
|----------|----------------|----------------------|
| Batterista solo (sala prove) | Segnale diretto, kick dominante, poco riverbero | SOLO |
| Batterista su palco (amplificazione) | Monitor, cross-talk da altri strumenti, compressione | SOLO o LIVE |
| Ascolto da speaker (live venue) | Mix compresso, kick spesso sottolineato da PA | LIVE |
| Registrazione compressa (mp3, streaming) | Transienti smussati, livelli normalizzati | LIVE |

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
