"""STT Autoresearch Benchmark Runner.

Usage:
    python tools/autoresearch/benchmark.py --model parakeet --mode full
    python tools/autoresearch/benchmark.py --model parakeet --mode chunked --save baseline
    python tools/autoresearch/benchmark.py --vad-threshold 0.4 --vad-min-silence 0.5
    python tools/autoresearch/benchmark.py --compare baseline experiment-1
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Allow running as: python tools/autoresearch/benchmark.py
# or as: python -m tools.autoresearch.benchmark
_AUTORESEARCH_DIR = Path(__file__).resolve().parent
if str(_AUTORESEARCH_DIR) not in sys.path:
    sys.path.insert(0, str(_AUTORESEARCH_DIR))

from config import (
    CHUNK_DURATION_S,
    CORPUS_DIR,
    MODEL_CONFIGS,
    RESULTS_DIR,
    VAD_MAX_SPEECH_DURATION,
    VAD_MIN_SILENCE_DURATION,
    VAD_MIN_SPEECH_DURATION,
    VAD_THRESHOLD,
    load_corpus,
)
from evaluator import ClipResult, evaluate, evaluate_corpus, format_markdown, save_results
from stt_runner import run_stt

# ── State file for named results ─────────────────────────────────────────────
STATE_FILE = _AUTORESEARCH_DIR / "STATE.json"

# Default model directories (mirrors Flutter getApplicationSupportDirectory)
_APP_SUPPORT = Path.home() / "AppData" / "Roaming" / "com.example.maityMobile"

DEFAULT_MODEL_DIRS: dict[str, Path] = {
    "parakeet": _APP_SUPPORT / "parakeet-tdt-0.6b-v3",
    "moonshine": _APP_SUPPORT / "moonshine-base-es",
    "canary": _APP_SUPPORT / "canary-180m-flash",
}

BOX_W = 46


# ── State persistence ────────────────────────────────────────────────────────


def _load_state() -> dict:
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    return {"saved_results": {}}


def _save_state(state: dict) -> None:
    STATE_FILE.write_text(
        json.dumps(state, indent=2, ensure_ascii=False), encoding="utf-8"
    )


# ── CLI argument parsing ─────────────────────────────────────────────────────


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="STT Autoresearch Benchmark Runner",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Examples:\n"
        "  python benchmark.py --model parakeet --mode full\n"
        "  python benchmark.py --model parakeet --mode chunked --save baseline\n"
        "  python benchmark.py --vad-threshold 0.4 --vad-min-silence 0.5\n"
        "  python benchmark.py --compare baseline experiment-1\n",
    )

    # Corpus / model
    p.add_argument("--corpus", type=Path, default=CORPUS_DIR, help="Corpus directory")
    p.add_argument(
        "--model",
        choices=list(MODEL_CONFIGS.keys()),
        default="parakeet",
        help="Model name (default: parakeet)",
    )
    p.add_argument(
        "--model-dir",
        type=Path,
        default=None,
        help="Path to model files directory (default: auto-detect from app support)",
    )
    p.add_argument(
        "--mode",
        choices=["full", "chunked"],
        default="full",
        help="Processing mode (default: full)",
    )

    # Save / compare
    p.add_argument("--save", metavar="NAME", help="Save results with this name")
    p.add_argument(
        "--compare",
        nargs=2,
        metavar=("A", "B"),
        help="Compare two saved results",
    )

    # Chunked mode
    p.add_argument(
        "--chunk-duration",
        type=float,
        default=CHUNK_DURATION_S,
        help=f"Chunk duration in seconds (default: {CHUNK_DURATION_S})",
    )

    # VAD overrides
    vad = p.add_argument_group("VAD overrides")
    vad.add_argument(
        "--vad-threshold",
        type=float,
        default=None,
        help=f"VAD threshold (default: {VAD_THRESHOLD})",
    )
    vad.add_argument(
        "--vad-min-speech",
        type=float,
        default=None,
        help=f"Min speech duration in seconds (default: {VAD_MIN_SPEECH_DURATION})",
    )
    vad.add_argument(
        "--vad-min-silence",
        type=float,
        default=None,
        help="Min silence duration in seconds (default: auto per model)",
    )
    vad.add_argument(
        "--vad-max-speech",
        type=float,
        default=None,
        help=f"Max speech duration in seconds (default: {VAD_MAX_SPEECH_DURATION})",
    )

    # Padding overrides
    pad = p.add_argument_group("Padding overrides (samples at 16kHz)")
    pad.add_argument("--pre-pad", type=int, help="Pre-pad silence samples")
    pad.add_argument("--post-pad", type=int, help="Post-pad silence samples")

    return p


# ── Model directory resolution ───────────────────────────────────────────────


def _resolve_model_dir(model: str, model_dir_override: Path | None) -> Path:
    """Resolve the model directory, checking that it exists."""
    if model_dir_override:
        model_dir = model_dir_override
    elif model in DEFAULT_MODEL_DIRS:
        model_dir = DEFAULT_MODEL_DIRS[model]
    else:
        model_dir = _APP_SUPPORT / model

    if not model_dir.exists():
        print(f"ERROR: Model directory not found: {model_dir}")
        print()
        print("To fix this, either:")
        print(f"  1. Download the {model} model via the Maity app (Settings > Local STT)")
        print(f"  2. Specify the path manually: --model-dir /path/to/{model}/")
        print()
        print("Expected files:")
        for key, filename in MODEL_CONFIGS[model]["files"].items():
            print(f"  - {filename}")
        print("  - silero_vad.onnx")
        sys.exit(1)

    return model_dir


# ── Output formatting ────────────────────────────────────────────────────────


def _print_header(
    model: str, mode: str, n_clips: int,
    vad_threshold: float, vad_min_speech: float, vad_min_silence: float,
) -> None:
    print()
    print(f"+{'=' * BOX_W}+")
    print(f"|  STT Autoresearch Benchmark{' ' * (BOX_W - 28)}|")
    print(f"+{'=' * BOX_W}+")
    print(f"  Model:      {model}")
    print(f"  Mode:       {mode}")
    print(f"  Corpus:     {n_clips} clip{'s' if n_clips != 1 else ''}")
    print(
        f"  VAD config: threshold={vad_threshold}, "
        f"minSpeech={vad_min_speech}s, "
        f"minSilence={vad_min_silence}s"
    )
    print()


def _print_clip_result(
    clip_name: str, duration_s: float, word_count: int, cr: ClipResult,
) -> None:
    dur_min = duration_s / 60
    print(
        f"--- {clip_name} "
        f"({dur_min:.1f} min, {word_count} words) ---"
    )
    status = "OK" if cr.wer < 0.10 else "WARN" if cr.wer < 0.25 else "FAIL"
    print(
        f"  [{status}] WER={cr.wer:.1%}  CER={cr.cer:.1%}  "
        f"({cr.decode_time_ms:.0f}ms, RTF={cr.rtf:.3f})"
    )
    print()


def _print_aggregate(agg_wer: float, agg_cer: float, mean_rtf: float) -> None:
    print(f"{'=' * BOX_W}")
    print(
        f"  AGGREGATE: WER={agg_wer:.1%}  CER={agg_cer:.1%}  RTF={mean_rtf:.3f}"
    )
    print(f"{'=' * BOX_W}")
    print()


# ── Compare two saved results ────────────────────────────────────────────────


def _load_saved_result(name: str) -> dict:
    """Load a previously saved JSON result by name."""
    state = _load_state()
    saved = state.get("saved_results", {})

    # Check STATE.json first
    if name in saved:
        json_path = Path(saved[name]["json_path"])
        if json_path.exists():
            return json.loads(json_path.read_text(encoding="utf-8"))

    # Fall back to direct file lookup
    json_path = RESULTS_DIR / f"{name}.json"
    if json_path.exists():
        return json.loads(json_path.read_text(encoding="utf-8"))

    # Search for files matching the name prefix
    matches = sorted(RESULTS_DIR.glob(f"{name}*.json"))
    if matches:
        return json.loads(matches[-1].read_text(encoding="utf-8"))

    print(f"ERROR: No saved result found for '{name}'")
    print(f"  Looked in: {RESULTS_DIR}")
    available = sorted(RESULTS_DIR.glob("*.json"))
    if available:
        print("  Available results:")
        for p in available:
            print(f"    - {p.stem}")
    sys.exit(1)


def _compare_results(name_a: str, name_b: str) -> None:
    """Load and compare two saved results, then print a side-by-side table."""
    data_a = _load_saved_result(name_a)
    data_b = _load_saved_result(name_b)

    print()
    title = f"Comparison: {name_a} vs {name_b}"
    pad = max(0, BOX_W - len(title) - 2)
    print(f"+{'=' * BOX_W}+")
    print(f"|  {title}{' ' * pad}|")
    print(f"+{'=' * BOX_W}+")
    print()

    print(f"  {'Metric':<20} {name_a:>12} {name_b:>12} {'Delta':>12}")
    print(f"  {'-' * 20} {'-' * 12} {'-' * 12} {'-' * 12}")

    for key, label, is_pct in [
        ("aggregate_wer", "WER", True),
        ("aggregate_cer", "CER", True),
        ("mean_decode_ms", "Decode (ms)", False),
        ("mean_rtf", "RTF", False),
    ]:
        va = data_a.get(key, 0)
        vb = data_b.get(key, 0)
        delta = vb - va
        sign = "+" if delta > 0 else ""

        if is_pct:
            print(f"  {label:<20} {va:>11.1%} {vb:>11.1%} {sign}{delta:>10.1%}")
        elif key == "mean_rtf":
            print(f"  {label:<20} {va:>12.3f} {vb:>12.3f} {sign}{delta:>11.3f}")
        else:
            print(f"  {label:<20} {va:>12.1f} {vb:>12.1f} {sign}{delta:>11.1f}")

    print()
    print(
        f"  Clips: {data_a.get('total_clips', '?')} vs "
        f"{data_b.get('total_clips', '?')}"
    )
    print(
        f"  Models: {data_a.get('model_name', '?')} ({data_a.get('mode', '?')}) vs "
        f"{data_b.get('model_name', '?')} ({data_b.get('mode', '?')})"
    )
    print()


# ── Main ─────────────────────────────────────────────────────────────────────


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    # --compare mode: load two saved results, print comparison, exit
    if args.compare:
        _compare_results(args.compare[0], args.compare[1])
        return

    # Resolve model directory
    model_dir = _resolve_model_dir(args.model, args.model_dir)

    # Load corpus
    corpus = load_corpus(args.corpus)
    if not corpus:
        print(f"ERROR: No .wav/.txt pairs found in {args.corpus}")
        print()
        print("Expected: .wav files with matching .txt ground truth files.")
        print("Run setup_corpus.py first, or specify --corpus /path/to/dir")
        sys.exit(1)

    # Resolve VAD params (None = use per-model defaults from config)
    vad_threshold = (
        args.vad_threshold if args.vad_threshold is not None else VAD_THRESHOLD
    )
    vad_min_speech = (
        args.vad_min_speech if args.vad_min_speech is not None else VAD_MIN_SPEECH_DURATION
    )
    vad_min_silence = args.vad_min_silence  # None = auto per model in run_stt
    vad_max_speech = (
        args.vad_max_speech if args.vad_max_speech is not None else VAD_MAX_SPEECH_DURATION
    )

    # Effective min_silence for display
    display_min_silence = (
        vad_min_silence
        if vad_min_silence is not None
        else MODEL_CONFIGS[args.model]["vad"]["min_silence_duration"]
    )

    # Print header
    _print_header(
        args.model, args.mode, len(corpus),
        vad_threshold, vad_min_speech, display_min_silence,
    )

    # Build config snapshot for saving
    run_config: dict = {
        "model": args.model,
        "mode": args.mode,
        "model_dir": str(model_dir),
        "corpus_dir": str(args.corpus),
        "chunk_duration_s": args.chunk_duration,
        "vad": {
            "threshold": vad_threshold,
            "min_speech": vad_min_speech,
            "min_silence": display_min_silence,
            "max_speech": vad_max_speech,
        },
    }
    if args.pre_pad is not None:
        run_config["pre_pad_samples"] = args.pre_pad
    if args.post_pad is not None:
        run_config["post_pad_samples"] = args.post_pad

    # Process each clip
    clip_results: list[ClipResult] = []

    for wav_path, ground_truth in corpus:
        clip_name = wav_path.stem
        word_count = len(ground_truth.split())

        stt_result = run_stt(
            audio_path=wav_path,
            model_dir=model_dir,
            model_type=args.model,
            mode=args.mode,
            vad_threshold=vad_threshold,
            min_speech_duration=vad_min_speech,
            min_silence_duration=vad_min_silence,
            max_speech_duration=vad_max_speech,
            chunk_duration_s=args.chunk_duration,
        )

        cr = evaluate(
            ground_truth=ground_truth,
            hypothesis=stt_result.full_text,
            clip_name=clip_name,
            decode_time_ms=stt_result.decode_time_ms,
            audio_duration_s=stt_result.audio_duration_s,
        )
        clip_results.append(cr)

        _print_clip_result(clip_name, stt_result.audio_duration_s, word_count, cr)

    # Aggregate
    eval_result = evaluate_corpus(
        clip_results, model_name=args.model, mode=args.mode, config=run_config,
    )

    _print_aggregate(
        eval_result.aggregate_wer, eval_result.aggregate_cer, eval_result.mean_rtf,
    )

    # Print full markdown summary
    print(format_markdown(eval_result))

    # Save if requested
    if args.save:
        json_path = save_results(eval_result)
        print(f"Results saved to: {json_path}")
        print(f"Markdown report:  {json_path.with_suffix('.md')}")

        # Update STATE.json
        state = _load_state()
        state.setdefault("saved_results", {})[args.save] = {
            "json_path": str(json_path),
            "model": args.model,
            "mode": args.mode,
            "aggregate_wer": eval_result.aggregate_wer,
            "aggregate_cer": eval_result.aggregate_cer,
            "total_clips": eval_result.total_clips,
        }
        _save_state(state)
        print(f"Registered as '{args.save}' in STATE.json")


if __name__ == "__main__":
    main()
