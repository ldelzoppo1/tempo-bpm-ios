#!/usr/bin/env python3
"""
beat_simulator.py — Simulatore offline dell'algoritmo BeatDetector di Kickline.

Riproduce in Python l'esatto algoritmo Swift implementato in
Tempo/Tempo/Audio/BeatDetector.swift, frame per frame (2048 campioni @ 44100 Hz).

Uso:
  python3 tools/beat_simulator.py --audio file.wav --known-bpm 129
  python3 tools/beat_simulator.py --audio file.wav --known-bpm 129 --mode live
  python3 tools/beat_simulator.py --audio file.wav --known-bpm 129 --calibrate
  python3 tools/beat_simulator.py --audio file.wav --known-bpm 129 --calibrate --mode live
"""

import argparse
import sys
import numpy as np
import librosa
import scipy.signal as sig
from dataclasses import dataclass, field
from itertools import product
from typing import Optional


# ---------------------------------------------------------------------------
# Parametri DSP — specchio esatto delle costanti Swift in BeatDetector
# ---------------------------------------------------------------------------

@dataclass
class DetectorParams:
    onset_sigma: float        = 1.0
    energy_window_min: int    = 22
    energy_window_max: int    = 64
    refractory_s: float       = 0.400
    holddown_s: float         = 0.450
    holddown_ratio: float     = 0.20
    max_interval_s: float     = 2.000
    outlier_threshold: float  = 0.13
    bpm_window: int           = 4
    min_onset_rms: float      = 0.040
    live_flux_sigma: float    = 1.5
    kick_cutoff_hz: float     = 100.0
    kick_ratio_threshold: float = 0.35


SAMPLE_RATE  = 44100
FRAME_SIZE   = 2048


# ---------------------------------------------------------------------------
# Filtri audio (specchio dei filtri Swift in AudioEngine + BeatDetector)
# ---------------------------------------------------------------------------

def make_bandpass(lo_hz: float, hi_hz: float, sr: int = SAMPLE_RATE):
    """HP@lo_hz + LP@hi_hz — corrisponde ai filtri biquad di AudioEngine."""
    sos_hp = sig.butter(2, lo_hz, btype='high', fs=sr, output='sos')
    sos_lp = sig.butter(2, hi_hz, btype='low',  fs=sr, output='sos')
    return sos_hp, sos_lp


def make_kick_lp(cutoff_hz: float, sr: int = SAMPLE_RATE):
    """LP@100Hz — corrisponde al kickBandRMS filter in BeatDetector."""
    return sig.butter(2, cutoff_hz, btype='low', fs=sr, output='sos')


def apply_sos(sos, audio: np.ndarray) -> np.ndarray:
    return sig.sosfilt(sos, audio)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def rms(frame: np.ndarray) -> float:
    return float(np.sqrt(np.mean(frame ** 2))) if len(frame) > 0 else 0.0


def median(values: list) -> float:
    s = sorted(values)
    n = len(s)
    return (s[n // 2 - 1] + s[n // 2]) / 2 if n % 2 == 0 else s[n // 2]


def compute_stats(window: np.ndarray, count: int, limit: int):
    """Specchio di computeStats() in BeatDetector: media e std degli ultimi `limit` campioni."""
    n = min(count, limit)
    if n == 0:
        return 0.0, 0.0
    vals = window[-n:]
    mean = float(np.mean(vals))
    std  = float(np.std(vals))
    return mean, std


def effective_window_size(last_bpm: float, p: DetectorParams) -> int:
    if last_bpm <= 0:
        return p.energy_window_max
    buffers_per_beat = (SAMPLE_RATE / FRAME_SIZE) * (60.0 / last_bpm)
    target = int(round(buffers_per_beat * 4))
    return max(p.energy_window_min, min(p.energy_window_max, target))


def rounded1(v: float) -> float:
    return round(v * 10) / 10


# ---------------------------------------------------------------------------
# Core detector — specchio di processSolo() / processLive() + registerOnset()
# ---------------------------------------------------------------------------

@dataclass
class DetectorState:
    energy_window: list        = field(default_factory=list)
    flux_window: list          = field(default_factory=list)
    prev_rms: float            = 0.0
    onset_intervals: list      = field(default_factory=list)
    session_bpms: list         = field(default_factory=list)
    last_onset_time: float     = 0.0
    last_onset_rms: float      = 0.0
    last_valid_bpm: float      = 0.0
    rhythm_confidence: float   = 0.0
    current_bpm: float         = 0.0
    onsets: list               = field(default_factory=list)   # timestamps


def run_detector(audio: np.ndarray, kick_audio: np.ndarray,
                 p: DetectorParams, mode: str = 'solo',
                 verbose: bool = False) -> DetectorState:
    """
    Processa l'audio frame per frame, specchiando esattamente l'algoritmo Swift.
    `audio`      — segnale pre-filtrato HP@30Hz + LP@250Hz (mono, float32)
    `kick_audio` — stesso segnale filtrato LP@100Hz (per kickRatio in Solo)
    """
    ds = DetectorState()
    n_frames = len(audio) // FRAME_SIZE

    for f in range(n_frames):
        t = f * FRAME_SIZE / SAMPLE_RATE
        frame      = audio[f * FRAME_SIZE:(f + 1) * FRAME_SIZE]
        kick_frame = kick_audio[f * FRAME_SIZE:(f + 1) * FRAME_SIZE]

        r = rms(frame)
        k = rms(kick_frame)

        if mode == 'solo':
            _process_solo(t, r, k, ds, p, verbose)
        else:
            _process_live(t, r, ds, p, verbose)

    return ds


def _process_solo(t: float, r: float, k: float,
                  ds: DetectorState, p: DetectorParams, verbose: bool):
    ds.energy_window.append(r)
    if len(ds.energy_window) > p.energy_window_max:
        ds.energy_window.pop(0)

    if r < p.min_onset_rms:
        return
    if len(ds.energy_window) < 3:
        return

    win_size = effective_window_size(ds.last_valid_bpm, p)
    mean, std = compute_stats(np.array(ds.energy_window), len(ds.energy_window), win_size)
    threshold = mean + std * p.onset_sigma
    if r <= threshold or threshold <= 0.001:
        return

    elapsed = t - ds.last_onset_time
    if elapsed < p.refractory_s:
        return

    if (elapsed < p.holddown_s and ds.last_onset_rms > 0
            and r < ds.last_onset_rms * p.holddown_ratio):
        if verbose:
            print(f"  t={t:.3f} ⛔ holddown r={r:.4f} lastR={ds.last_onset_rms:.4f}")
        return

    kick_ratio = k / r if r > 0 else 0.0
    if kick_ratio < p.kick_ratio_threshold:
        if verbose:
            print(f"  t={t:.3f} 🪘 snare/tom kickRatio={kick_ratio:.2f}")
        return

    ds.last_onset_rms = r
    _register_onset(t, ds, p, verbose)


def _process_live(t: float, r: float,
                  ds: DetectorState, p: DetectorParams, verbose: bool):
    flux = max(0.0, r - ds.prev_rms)
    ds.prev_rms = r
    ds.flux_window.append(flux)
    if len(ds.flux_window) > p.energy_window_max:
        ds.flux_window.pop(0)

    if r < p.min_onset_rms:
        return
    if len(ds.flux_window) < 3:
        return

    win_size = effective_window_size(ds.last_valid_bpm, p)
    fmean, fstd = compute_stats(np.array(ds.flux_window), len(ds.flux_window), win_size)
    f_threshold = fmean + fstd * p.live_flux_sigma
    if flux <= f_threshold or f_threshold <= 0:
        return

    elapsed = t - ds.last_onset_time
    if elapsed < p.refractory_s:
        return

    if (elapsed < p.holddown_s and ds.last_onset_rms > 0
            and r < ds.last_onset_rms * p.holddown_ratio):
        return

    ds.last_onset_rms = r
    _register_onset(t, ds, p, verbose)


def _register_onset(t: float, ds: DetectorState, p: DetectorParams, verbose: bool):
    if ds.last_onset_time > 0 and t - ds.last_onset_time > 2.0:
        ds.onset_intervals.clear()
        ds.rhythm_confidence = 0.0

    prev_time = ds.last_onset_time
    ds.last_onset_time = t

    if prev_time <= 0:
        ds.onsets.append(t)
        return

    interval = t - prev_time

    if interval < p.refractory_s or interval > p.max_interval_s:
        return

    if ds.onset_intervals:
        med = median(ds.onset_intervals)
        if abs(interval - med) / med > p.outlier_threshold:
            ds.rhythm_confidence = max(0.0, ds.rhythm_confidence - 0.3)
            if verbose:
                print(f"  t={t:.3f} ✗ outlier interval={interval:.3f} med={med:.3f}")
            return

    ds.onset_intervals.append(interval)
    if len(ds.onset_intervals) > p.bpm_window:
        ds.onset_intervals.pop(0)

    if len(ds.onset_intervals) < 2:
        ds.onsets.append(t)
        return

    mean_interval = sum(ds.onset_intervals) / len(ds.onset_intervals)
    raw_bpm = rounded1(60.0 / mean_interval)
    octave  = 2.0 if raw_bpm < 80 else 1.0
    bpm     = rounded1(raw_bpm * octave)

    ds.last_valid_bpm = bpm
    ds.rhythm_confidence = min(1.0, ds.rhythm_confidence + 0.12)

    alpha = 0.85 - 0.25 * ds.rhythm_confidence
    prev  = ds.current_bpm
    ds.current_bpm = rounded1(alpha * bpm + (1 - alpha) * prev) if prev > 0 else bpm

    ds.session_bpms.append(bpm)
    ds.onsets.append(t)

    if verbose:
        print(f"  t={t:.3f} 🥁 bpm={bpm:.1f} current={ds.current_bpm:.1f} "
              f"conf={ds.rhythm_confidence:.2f} interval={interval:.3f}s")


# ---------------------------------------------------------------------------
# Analisi + report
# ---------------------------------------------------------------------------

def analyse(audio_path: str, known_bpm: Optional[float], mode: str,
            p: DetectorParams, verbose: bool = False) -> DetectorState:
    print(f"\n{'='*60}")
    print(f"  File  : {audio_path}")
    print(f"  Modo  : {mode.upper()}")
    if known_bpm:
        print(f"  BPM atteso: {known_bpm}")
    print(f"{'='*60}\n")

    y, _ = librosa.load(audio_path, sr=SAMPLE_RATE, mono=True)

    sos_hp, sos_lp = make_bandpass(30.0, 250.0)
    sos_kick       = make_kick_lp(p.kick_cutoff_hz)

    y_band = apply_sos(sos_lp, apply_sos(sos_hp, y))
    y_kick = apply_sos(sos_kick, y_band)

    ds = run_detector(y_band, y_kick, p, mode=mode, verbose=verbose)

    # Statistiche onset
    n_onsets = len(ds.onsets)
    duration = len(y) / SAMPLE_RATE

    print(f"Durata audio  : {duration:.1f}s")
    print(f"Onset rilevati: {n_onsets}")
    print(f"BPM finale    : {ds.current_bpm:.1f}")

    if ds.session_bpms:
        arr = np.array(ds.session_bpms)
        print(f"BPM mediana   : {np.median(arr):.1f}")
        print(f"BPM std       : {np.std(arr):.2f}")
        print(f"BPM min/max   : {arr.min():.1f} / {arr.max():.1f}")

    if known_bpm and ds.current_bpm > 0:
        err = abs(ds.current_bpm - known_bpm) / known_bpm * 100
        print(f"\n→ Errore vs {known_bpm} BPM: {err:.1f}%  "
              f"({'✅ OK' if err < 5 else '⚠️  ALTO' if err < 15 else '❌ FUORI RANGE'})")

    return ds


# ---------------------------------------------------------------------------
# Calibrazione — sweep parametri
# ---------------------------------------------------------------------------

SWEEP_GRID = {
    'onset_sigma':          [0.7, 1.0, 1.3],
    'outlier_threshold':    [0.10, 0.13, 0.18, 0.25],
    'kick_ratio_threshold': [0.25, 0.30, 0.35, 0.40],
    'min_onset_rms':        [0.020, 0.030, 0.040, 0.060],
}

LIVE_SWEEP_GRID = {
    'onset_sigma':       [0.7, 1.0, 1.3],   # usato per energy window init
    'outlier_threshold': [0.10, 0.13, 0.18, 0.25],
    'live_flux_sigma':   [1.2, 1.5, 1.8, 2.2],
    'min_onset_rms':     [0.010, 0.020, 0.040],
}


def calibrate(audio_path: str, known_bpm: float, mode: str, top_n: int = 5):
    print(f"\n{'='*60}")
    print(f"  CALIBRAZIONE — {mode.upper()}")
    print(f"  File: {audio_path}  |  BPM atteso: {known_bpm}")
    print(f"{'='*60}\n")

    y, _ = librosa.load(audio_path, sr=SAMPLE_RATE, mono=True)
    sos_hp, sos_lp = make_bandpass(30.0, 250.0)
    sos_kick       = make_kick_lp(100.0)
    y_band = apply_sos(sos_lp, apply_sos(sos_hp, y))
    y_kick = apply_sos(sos_kick, y_band)

    grid = LIVE_SWEEP_GRID if mode == 'live' else SWEEP_GRID
    keys = list(grid.keys())
    vals = list(grid.values())

    results = []
    total = 1
    for v in vals:
        total *= len(v)
    print(f"Combinazioni da testare: {total}")

    for combo in product(*vals):
        p = DetectorParams()
        for k, v in zip(keys, combo):
            setattr(p, k, v)

        ds = run_detector(y_band, y_kick, p, mode=mode, verbose=False)

        if ds.current_bpm <= 0:
            err = 999.0
        else:
            err = abs(ds.current_bpm - known_bpm) / known_bpm * 100

        results.append((err, dict(zip(keys, combo)), ds.current_bpm))

    results.sort(key=lambda x: x[0])

    print(f"\nTop {top_n} configurazioni:\n")
    print(f"  {'Errore':>7}  {'BPM':>6}  Parametri")
    print(f"  {'-'*7}  {'-'*6}  {'-'*40}")
    for err, params, bpm in results[:top_n]:
        param_str = '  '.join(f"{k}={v}" for k, v in params.items())
        status = '✅' if err < 5 else '⚠️ ' if err < 15 else '❌'
        print(f"  {status} {err:5.1f}%  {bpm:6.1f}  {param_str}")

    best_err, best_params, best_bpm = results[0]
    print(f"\n{'='*60}")
    print(f"Parametri ottimali (errore {best_err:.1f}%, BPM {best_bpm:.1f}):")
    for k, v in best_params.items():
        current = getattr(DetectorParams(), k)
        marker = " ← CAMBIA" if v != current else ""
        print(f"  {k:28s} = {v}{marker}")
    print(f"{'='*60}\n")

    return best_params


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="Simulatore e calibratore offline di BeatDetector (Kickline)")
    ap.add_argument('--audio',     required=True, help="File audio (.wav, .mp3, .aiff)")
    ap.add_argument('--known-bpm', type=float,    help="BPM noto per calcolare l'errore")
    ap.add_argument('--mode',      choices=['solo', 'live'], default='solo',
                    help="Modalità di rilevamento (default: solo)")
    ap.add_argument('--calibrate', action='store_true',
                    help="Sweep parametri per trovare la configurazione ottimale")
    ap.add_argument('--verbose',   action='store_true',
                    help="Stampa ogni onset/outlier/holddown rilevato")
    ap.add_argument('--top',       type=int, default=5,
                    help="Numero di configurazioni top da mostrare in calibrazione (default: 5)")
    args = ap.parse_args()

    p = DetectorParams()

    if args.calibrate:
        if not args.known_bpm:
            print("Errore: --calibrate richiede --known-bpm", file=sys.stderr)
            sys.exit(1)
        calibrate(args.audio, args.known_bpm, args.mode, top_n=args.top)
    else:
        analyse(args.audio, args.known_bpm, args.mode, p, verbose=args.verbose)


if __name__ == '__main__':
    main()
