"""Sweep Phase 2: Combinations of winning parameters from Phase 1.

Phase 1 winners (individual):
  - min_speech=0.3  -> WER 6.89% (-18.9%)
  - silence=1.5     -> WER 7.41% (-12.7%)
  - threshold=0.3   -> WER 7.54% (-11.2%)
  - silence=2.0     -> WER 7.50% (-11.7%)
  - max_speech=60   -> WER 7.89% (-0.61%)

Now test combinations.
"""
from __future__ import annotations
import json, sys, time
from pathlib import Path

_DIR = Path(__file__).resolve().parent
if str(_DIR) not in sys.path:
    sys.path.insert(0, str(_DIR))

from config import CORPUS_DIR, RESULTS_DIR, SAMPLE_RATE, load_corpus
from evaluator import evaluate, evaluate_corpus, ClipResult
from stt_runner import load_wav, _create_recognizer, _create_vad, _process_full

EXPERIMENTS = [
    # Baseline
    {"name": "baseline",             "threshold": 0.5, "min_speech": 0.8, "min_silence": 1.0, "max_speech": 30.0},
    # Best individual
    {"name": "best-individual",      "threshold": 0.5, "min_speech": 0.3, "min_silence": 1.0, "max_speech": 30.0},
    # Combos of top 2
    {"name": "combo-A",              "threshold": 0.3, "min_speech": 0.3, "min_silence": 1.5, "max_speech": 30.0},
    {"name": "combo-B",              "threshold": 0.3, "min_speech": 0.3, "min_silence": 1.0, "max_speech": 45.0},
    {"name": "combo-C",              "threshold": 0.5, "min_speech": 0.3, "min_silence": 1.5, "max_speech": 30.0},
    # Combos of top 3
    {"name": "combo-D-full",         "threshold": 0.3, "min_speech": 0.3, "min_silence": 1.5, "max_speech": 45.0},
    {"name": "combo-E-full",         "threshold": 0.3, "min_speech": 0.3, "min_silence": 1.5, "max_speech": 60.0},
    {"name": "combo-F-full",         "threshold": 0.3, "min_speech": 0.3, "min_silence": 2.0, "max_speech": 30.0},
    # Fine-tune around best min_speech
    {"name": "combo-G-ms04",         "threshold": 0.3, "min_speech": 0.4, "min_silence": 1.5, "max_speech": 30.0},
    {"name": "combo-H-ms05",         "threshold": 0.3, "min_speech": 0.5, "min_silence": 1.5, "max_speech": 30.0},
    # Fine-tune threshold around 0.3
    {"name": "combo-I-t035",         "threshold": 0.35, "min_speech": 0.3, "min_silence": 1.5, "max_speech": 30.0},
    {"name": "combo-J-t025",         "threshold": 0.25, "min_speech": 0.3, "min_silence": 1.5, "max_speech": 30.0},
]

def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, default=CORPUS_DIR)
    parser.add_argument("--model", default="parakeet")
    args = parser.parse_args()

    corpus = load_corpus(args.corpus)
    if not corpus:
        print(f"ERROR: No corpus in {args.corpus}")
        sys.exit(1)

    print(f"+{'='*54}+")
    print(f"|  Phase 2: Combination Sweep                          |")
    print(f"+{'='*54}+")
    print(f"  Model:       {args.model}")
    print(f"  Corpus:      {len(corpus)} clips")
    print(f"  Experiments: {len(EXPERIMENTS)}")
    print()

    recognizer = _create_recognizer(args.model_dir, args.model)
    print("[sweep] Recognizer loaded.")

    audio_data = []
    for wav_path, gt in corpus:
        samples = load_wav(wav_path)
        audio_data.append((wav_path, gt, samples))
    print(f"  Audio loaded: {len(audio_data)} clips")
    print()

    all_results = []
    for i, exp in enumerate(EXPERIMENTS, 1):
        name = exp["name"]
        print(f"[{i}/{len(EXPERIMENTS)}] {name}")
        print(f"  t={exp['threshold']}, ms={exp['min_speech']}s, "
              f"sil={exp['min_silence']}s, max={exp['max_speech']}s")

        clip_results = []
        for wav_path, gt, samples in audio_data:
            vad = _create_vad(
                args.model_dir,
                threshold=exp["threshold"],
                min_speech_duration=exp["min_speech"],
                min_silence_duration=exp["min_silence"],
                max_speech_duration=exp["max_speech"],
            )
            t0 = time.perf_counter()
            segments = _process_full(samples, vad, recognizer, args.model, exp["max_speech"])
            decode_ms = (time.perf_counter() - t0) * 1000
            duration_s = len(samples) / SAMPLE_RATE
            full_text = " ".join(seg.text for seg in segments)
            cr = evaluate(gt, full_text, wav_path.stem, decode_ms, duration_s)
            clip_results.append(cr)

        result = evaluate_corpus(clip_results, args.model, "full", exp)
        all_results.append({
            "name": name, "params": exp,
            "wer": result.aggregate_wer, "cer": result.aggregate_cer,
            "mean_rtf": result.mean_rtf,
        })
        status = "OK" if result.aggregate_wer < 0.10 else "WARN" if result.aggregate_wer < 0.20 else "FAIL"
        print(f"  [{status}] WER={result.aggregate_wer:.2%}  CER={result.aggregate_cer:.2%}  RTF={result.mean_rtf:.3f}")
        print()

    # Summary
    baseline_wer = all_results[0]["wer"]
    print(f"+{'='*74}+")
    print(f"|  COMBINATION SWEEP RESULTS                                               |")
    print(f"+{'='*74}+")
    print()
    print(f"  {'Name':<22} {'WER':>8} {'CER':>8} {'RTF':>8}  {'Delta':>8}")
    print(f"  {'-'*22} {'-'*8} {'-'*8} {'-'*8}  {'-'*8}")
    for r in all_results:
        delta = r["wer"] - baseline_wer
        marker = "  <<<" if delta > 0.01 else "  >>>" if delta < -0.01 else ""
        print(f"  {r['name']:<22} {r['wer']:>7.2%} {r['cer']:>7.2%} {r['mean_rtf']:>8.3f} {delta:>+8.2%}{marker}")
    best = min(all_results, key=lambda r: r["wer"])
    print()
    print(f"  BEST: {best['name']} (WER={best['wer']:.2%})")
    imp = baseline_wer - best["wer"]
    print(f"  Improvement: {imp:.2%} absolute ({imp/baseline_wer*100:.1f}% relative)")

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    out = RESULTS_DIR / "sweep_combos_results.json"
    out.write_text(json.dumps(all_results, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"\n  Saved: {out}")

if __name__ == "__main__":
    main()
