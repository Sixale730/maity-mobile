"""Parameter sweep — run multiple VAD configurations in sequence.

Shares a single model instance across all experiments for efficiency.
Results are saved and compared at the end.

Usage:
    python tools/autoresearch/sweep.py --model-dir tools/autoresearch/models/parakeet-tdt-0.6b-v3
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

_AUTORESEARCH_DIR = Path(__file__).resolve().parent
if str(_AUTORESEARCH_DIR) not in sys.path:
    sys.path.insert(0, str(_AUTORESEARCH_DIR))

from config import CORPUS_DIR, RESULTS_DIR, MODEL_CONFIGS, SAMPLE_RATE, load_corpus
from evaluator import evaluate, evaluate_corpus, format_markdown, save_results, ClipResult, EvalResult
from stt_runner import (
    load_wav, _create_recognizer, _create_vad, _process_full,
    pad_with_silence, truncate_repetitions, SttResult, SttSegment,
)

# ── Parameter grid ────────────────────────────────────────────────────────────
# Each experiment changes ONE parameter from baseline.
# Baseline: threshold=0.5, min_speech=0.8, min_silence=1.0, max_speech=30.0

EXPERIMENTS = [
    {"name": "baseline",         "threshold": 0.5, "min_speech": 0.8, "min_silence": 1.0, "max_speech": 30.0},
    # Layer 1: VAD threshold
    {"name": "threshold-0.3",    "threshold": 0.3, "min_speech": 0.8, "min_silence": 1.0, "max_speech": 30.0},
    {"name": "threshold-0.4",    "threshold": 0.4, "min_speech": 0.8, "min_silence": 1.0, "max_speech": 30.0},
    {"name": "threshold-0.6",    "threshold": 0.6, "min_speech": 0.8, "min_silence": 1.0, "max_speech": 30.0},
    {"name": "threshold-0.7",    "threshold": 0.7, "min_speech": 0.8, "min_silence": 1.0, "max_speech": 30.0},
    # Layer 1: min_silence_duration
    {"name": "silence-0.3",      "threshold": 0.5, "min_speech": 0.8, "min_silence": 0.3, "max_speech": 30.0},
    {"name": "silence-0.5",      "threshold": 0.5, "min_speech": 0.8, "min_silence": 0.5, "max_speech": 30.0},
    {"name": "silence-1.5",      "threshold": 0.5, "min_speech": 0.8, "min_silence": 1.5, "max_speech": 30.0},
    {"name": "silence-2.0",      "threshold": 0.5, "min_speech": 0.8, "min_silence": 2.0, "max_speech": 30.0},
    # Layer 1: min_speech_duration
    {"name": "min-speech-0.3",   "threshold": 0.5, "min_speech": 0.3, "min_silence": 1.0, "max_speech": 30.0},
    {"name": "min-speech-0.5",   "threshold": 0.5, "min_speech": 0.5, "min_silence": 1.0, "max_speech": 30.0},
    {"name": "min-speech-1.2",   "threshold": 0.5, "min_speech": 1.2, "min_silence": 1.0, "max_speech": 30.0},
    # Layer 1: max_speech_duration
    {"name": "max-speech-15",    "threshold": 0.5, "min_speech": 0.8, "min_silence": 1.0, "max_speech": 15.0},
    {"name": "max-speech-45",    "threshold": 0.5, "min_speech": 0.8, "min_silence": 1.0, "max_speech": 45.0},
    {"name": "max-speech-60",    "threshold": 0.5, "min_speech": 0.8, "min_silence": 1.0, "max_speech": 60.0},
]


def run_sweep(model_dir: Path, corpus_dir: Path, model_type: str = "parakeet"):
    corpus = load_corpus(corpus_dir)
    if not corpus:
        print(f"ERROR: No corpus found in {corpus_dir}")
        sys.exit(1)

    print(f"+{'=' * 54}+")
    print(f"|  STT Autoresearch Parameter Sweep                    |")
    print(f"+{'=' * 54}+")
    print(f"  Model:       {model_type}")
    print(f"  Model dir:   {model_dir}")
    print(f"  Corpus:      {len(corpus)} clips")
    print(f"  Experiments: {len(EXPERIMENTS)}")
    print()

    # Load model once (recognizer is stateless, can be reused)
    print("[sweep] Loading recognizer...")
    recognizer = _create_recognizer(model_dir, model_type)
    print("[sweep] Recognizer loaded.")
    print()

    # Pre-load all audio
    audio_data = []
    for wav_path, gt in corpus:
        samples = load_wav(wav_path)
        audio_data.append((wav_path, gt, samples))
        print(f"  Loaded: {wav_path.name} ({len(samples)/SAMPLE_RATE:.1f}s)")
    print()

    # Run experiments
    all_results: list[dict] = []

    for i, exp in enumerate(EXPERIMENTS, 1):
        name = exp["name"]
        print(f"[{i}/{len(EXPERIMENTS)}] Running: {name}")
        print(f"  threshold={exp['threshold']}, min_speech={exp['min_speech']}s, "
              f"min_silence={exp['min_silence']}s, max_speech={exp['max_speech']}s")

        clip_results: list[ClipResult] = []

        for wav_path, gt, samples in audio_data:
            # Create fresh VAD for each experiment (VAD has state)
            vad = _create_vad(
                model_dir,
                threshold=exp["threshold"],
                min_speech_duration=exp["min_speech"],
                min_silence_duration=exp["min_silence"],
                max_speech_duration=exp["max_speech"],
            )

            t0 = time.perf_counter()
            segments = _process_full(
                samples, vad, recognizer, model_type, exp["max_speech"]
            )
            decode_ms = (time.perf_counter() - t0) * 1000
            duration_s = len(samples) / SAMPLE_RATE

            full_text = " ".join(seg.text for seg in segments)

            cr = evaluate(
                ground_truth=gt,
                hypothesis=full_text,
                clip_name=wav_path.stem,
                decode_time_ms=decode_ms,
                audio_duration_s=duration_s,
            )
            clip_results.append(cr)

        result = evaluate_corpus(clip_results, model_type, "full", exp)
        all_results.append({
            "name": name,
            "params": exp,
            "wer": result.aggregate_wer,
            "cer": result.aggregate_cer,
            "mean_rtf": result.mean_rtf,
            "clips": {c.clip: {"wer": c.wer, "s": c.substitutions, "i": c.insertions, "d": c.deletions}
                      for c in result.clips},
        })

        status = "OK" if result.aggregate_wer < 0.10 else "WARN" if result.aggregate_wer < 0.20 else "FAIL"
        print(f"  [{status}] WER={result.aggregate_wer:.2%}  CER={result.aggregate_cer:.2%}  RTF={result.mean_rtf:.3f}")
        print()

    # Summary table
    print(f"+{'=' * 74}+")
    print(f"|  SWEEP RESULTS                                                           |")
    print(f"+{'=' * 74}+")
    print()
    print(f"  {'Name':<20} {'WER':>8} {'CER':>8} {'RTF':>8}  {'Changed Param'}")
    print(f"  {'-' * 20} {'-' * 8} {'-' * 8} {'-' * 8}  {'-' * 20}")

    baseline_wer = all_results[0]["wer"] if all_results else 0
    for r in all_results:
        delta = r["wer"] - baseline_wer
        marker = "  <<<" if delta > 0.01 else "  >>>" if delta < -0.01 else ""
        print(f"  {r['name']:<20} {r['wer']:>7.2%} {r['cer']:>7.2%} {r['mean_rtf']:>8.3f}{marker}")

    # Find best
    best = min(all_results, key=lambda r: r["wer"])
    print()
    print(f"  BEST: {best['name']} (WER={best['wer']:.2%})")
    if best["name"] != "baseline":
        improvement = baseline_wer - best["wer"]
        print(f"  Improvement over baseline: {improvement:.2%} absolute ({improvement/baseline_wer*100:.1f}% relative)")
    print()

    # Save sweep results
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    sweep_path = RESULTS_DIR / "sweep_results.json"
    sweep_path.write_text(json.dumps(all_results, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"  Saved: {sweep_path}")


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="STT parameter sweep")
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, default=CORPUS_DIR)
    parser.add_argument("--model", default="parakeet", choices=["parakeet", "moonshine", "canary"])
    args = parser.parse_args()
    run_sweep(args.model_dir, args.corpus, args.model)
