"""Canary 180M Flash sweep: VAD params + chunk duration (Layer 1 + Layer 2).

Canary is an encoder-decoder model (not transducer like Parakeet), so:
- Uses srcLang/tgtLang='es' for Spanish
- minSilenceDuration defaults to 0.3s (faster segmentation)
- May produce "(EMPTY)" on force-flushed segments
- Chunk duration matters more because encoder-decoder needs clean boundaries
"""
from __future__ import annotations
import json, sys, time
from pathlib import Path

_DIR = Path(__file__).resolve().parent
if str(_DIR) not in sys.path:
    sys.path.insert(0, str(_DIR))

from config import CORPUS_DIR, RESULTS_DIR, SAMPLE_RATE, load_corpus
from evaluator import evaluate, evaluate_corpus, ClipResult
from stt_runner import load_wav, _create_recognizer, _create_vad, _process_full, _process_chunked

EXPERIMENTS = [
    # === Baseline (Canary defaults from Dart) ===
    {"name": "canary-baseline",       "threshold": 0.5, "min_speech": 0.8, "min_silence": 0.3, "max_speech": 30.0, "mode": "full"},

    # === Layer 1: VAD params (full mode) ===
    # min_speech (the big winner from Parakeet)
    {"name": "ms-0.3",                "threshold": 0.5, "min_speech": 0.3, "min_silence": 0.3, "max_speech": 30.0, "mode": "full"},
    {"name": "ms-0.5",                "threshold": 0.5, "min_speech": 0.5, "min_silence": 0.3, "max_speech": 30.0, "mode": "full"},
    # threshold
    {"name": "t-0.3",                 "threshold": 0.3, "min_speech": 0.8, "min_silence": 0.3, "max_speech": 30.0, "mode": "full"},
    {"name": "t-0.4",                 "threshold": 0.4, "min_speech": 0.8, "min_silence": 0.3, "max_speech": 30.0, "mode": "full"},
    # min_silence (Canary default is already 0.3, try higher)
    {"name": "sil-0.5",               "threshold": 0.5, "min_speech": 0.8, "min_silence": 0.5, "max_speech": 30.0, "mode": "full"},
    {"name": "sil-1.0",               "threshold": 0.5, "min_speech": 0.8, "min_silence": 1.0, "max_speech": 30.0, "mode": "full"},
    {"name": "sil-1.5",               "threshold": 0.5, "min_speech": 0.8, "min_silence": 1.5, "max_speech": 30.0, "mode": "full"},
    # Best combo from Parakeet applied to Canary
    {"name": "best-parakeet-params",  "threshold": 0.5, "min_speech": 0.3, "min_silence": 1.0, "max_speech": 30.0, "mode": "full"},

    # === Layer 2: Chunk duration (chunked mode) ===
    {"name": "chunk-3s",              "threshold": 0.5, "min_speech": 0.8, "min_silence": 0.3, "max_speech": 30.0, "mode": "chunked", "chunk_s": 3.0},
    {"name": "chunk-5s",              "threshold": 0.5, "min_speech": 0.8, "min_silence": 0.3, "max_speech": 30.0, "mode": "chunked", "chunk_s": 5.0},
    {"name": "chunk-8s",              "threshold": 0.5, "min_speech": 0.8, "min_silence": 0.3, "max_speech": 30.0, "mode": "chunked", "chunk_s": 8.0},
    {"name": "chunk-10s",             "threshold": 0.5, "min_speech": 0.8, "min_silence": 0.3, "max_speech": 30.0, "mode": "chunked", "chunk_s": 10.0},
    {"name": "chunk-15s",             "threshold": 0.5, "min_speech": 0.8, "min_silence": 0.3, "max_speech": 30.0, "mode": "chunked", "chunk_s": 15.0},

    # === Layer 2 + best VAD: chunk + min_speech=0.3 ===
    {"name": "chunk-5s+ms03",         "threshold": 0.5, "min_speech": 0.3, "min_silence": 0.3, "max_speech": 30.0, "mode": "chunked", "chunk_s": 5.0},
    {"name": "chunk-8s+ms03",         "threshold": 0.5, "min_speech": 0.3, "min_silence": 0.3, "max_speech": 30.0, "mode": "chunked", "chunk_s": 8.0},
    {"name": "chunk-10s+ms03",        "threshold": 0.5, "min_speech": 0.3, "min_silence": 0.3, "max_speech": 30.0, "mode": "chunked", "chunk_s": 10.0},
    {"name": "chunk-10s+ms03+sil10",  "threshold": 0.5, "min_speech": 0.3, "min_silence": 1.0, "max_speech": 30.0, "mode": "chunked", "chunk_s": 10.0},
]

def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, default=CORPUS_DIR)
    args = parser.parse_args()

    model_type = "canary"
    corpus = load_corpus(args.corpus)
    if not corpus:
        print(f"ERROR: No corpus in {args.corpus}")
        sys.exit(1)

    print(f"+{'='*54}+")
    print(f"|  Canary 180M Flash — Full Sweep (VAD + Chunks)       |")
    print(f"+{'='*54}+")
    print(f"  Model:       {model_type}")
    print(f"  Corpus:      {len(corpus)} clips")
    print(f"  Experiments: {len(EXPERIMENTS)}")
    print()

    recognizer = _create_recognizer(args.model_dir, model_type)
    print("[sweep] Recognizer loaded.")

    audio_data = []
    for wav_path, gt in corpus:
        samples = load_wav(wav_path)
        audio_data.append((wav_path, gt, samples))
    print(f"  Audio loaded: {len(audio_data)} clips\n")

    all_results = []
    for i, exp in enumerate(EXPERIMENTS, 1):
        name = exp["name"]
        mode = exp.get("mode", "full")
        chunk_s = exp.get("chunk_s", 5.0)
        print(f"[{i}/{len(EXPERIMENTS)}] {name} ({mode})")
        print(f"  t={exp['threshold']}, ms={exp['min_speech']}s, "
              f"sil={exp['min_silence']}s, max={exp['max_speech']}s"
              + (f", chunk={chunk_s}s" if mode == "chunked" else ""))

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
            if mode == "chunked":
                segments = _process_chunked(
                    samples, vad, recognizer, model_type,
                    exp["max_speech"], chunk_s
                )
            else:
                segments = _process_full(
                    samples, vad, recognizer, model_type, exp["max_speech"]
                )
            decode_ms = (time.perf_counter() - t0) * 1000
            duration_s = len(samples) / SAMPLE_RATE
            full_text = " ".join(seg.text for seg in segments)
            cr = evaluate(gt, full_text, wav_path.stem, decode_ms, duration_s)
            clip_results.append(cr)

        result = evaluate_corpus(clip_results, model_type, mode, exp)
        all_results.append({
            "name": name, "params": exp,
            "wer": result.aggregate_wer, "cer": result.aggregate_cer,
            "mean_rtf": result.mean_rtf,
        })
        status = "OK" if result.aggregate_wer < 0.10 else "WARN" if result.aggregate_wer < 0.25 else "FAIL"
        print(f"  [{status}] WER={result.aggregate_wer:.2%}  CER={result.aggregate_cer:.2%}  RTF={result.mean_rtf:.3f}\n")

    # Summary
    baseline_wer = all_results[0]["wer"]
    print(f"+{'='*78}+")
    print(f"|  CANARY SWEEP RESULTS                                                        |")
    print(f"+{'='*78}+\n")

    # Split into sections
    for section, label in [("full", "Layer 1: VAD (full mode)"), ("chunked", "Layer 2: Chunks")]:
        section_results = [r for r in all_results if r["params"].get("mode", "full") == section]
        if not section_results:
            continue
        print(f"  --- {label} ---")
        print(f"  {'Name':<26} {'WER':>8} {'CER':>8} {'RTF':>8}  {'Delta':>8}")
        print(f"  {'-'*26} {'-'*8} {'-'*8} {'-'*8}  {'-'*8}")
        for r in section_results:
            delta = r["wer"] - baseline_wer
            marker = " >>>" if delta < -0.01 else (" <<<" if delta > 0.01 else "")
            print(f"  {r['name']:<26} {r['wer']:>7.2%} {r['cer']:>7.2%} {r['mean_rtf']:>8.3f} {delta:>+8.2%}{marker}")
        print()

    best = min(all_results, key=lambda r: r["wer"])
    print(f"  BEST: {best['name']} (WER={best['wer']:.2%})")
    imp = baseline_wer - best["wer"]
    print(f"  Improvement: {imp:.2%} absolute ({imp/baseline_wer*100:.1f}% relative)")

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    out = RESULTS_DIR / "sweep_canary_results.json"
    out.write_text(json.dumps(all_results, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"\n  Saved: {out}")

if __name__ == "__main__":
    main()
