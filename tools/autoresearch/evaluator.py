"""Evaluation module: computes WER/CER and produces reports."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from jiwer import cer as compute_cer
from jiwer import process_words, wer as compute_wer

try:
    from .config import RESULTS_DIR, normalize_text
except ImportError:
    from config import RESULTS_DIR, normalize_text


@dataclass
class ClipResult:
    clip: str
    ground_truth: str
    hypothesis: str
    wer: float
    cer: float
    substitutions: int
    insertions: int
    deletions: int
    hits: int
    decode_time_ms: float
    audio_duration_s: float
    rtf: float  # real-time factor: decode_time / audio_duration


@dataclass
class EvalResult:
    model_name: str
    mode: str  # "full" or "chunked"
    clips: list[ClipResult] = field(default_factory=list)
    aggregate_wer: float = 0.0
    aggregate_cer: float = 0.0
    mean_decode_ms: float = 0.0
    mean_rtf: float = 0.0
    total_clips: int = 0
    config: dict = field(default_factory=dict)


def evaluate(
    ground_truth: str,
    hypothesis: str,
    clip_name: str = "",
    decode_time_ms: float = 0.0,
    audio_duration_s: float = 0.0,
) -> ClipResult:
    """Evaluate a single clip against its ground truth."""
    ref = normalize_text(ground_truth)
    hyp = normalize_text(hypothesis)

    # Handle empty cases
    if not ref:
        clip_wer = 0.0 if not hyp else 1.0
        clip_cer = 0.0 if not hyp else 1.0
        return ClipResult(
            clip=clip_name,
            ground_truth=ref,
            hypothesis=hyp,
            wer=clip_wer,
            cer=clip_cer,
            substitutions=0,
            insertions=len(hyp.split()) if hyp else 0,
            deletions=0,
            hits=0,
            decode_time_ms=decode_time_ms,
            audio_duration_s=audio_duration_s,
            rtf=decode_time_ms / (audio_duration_s * 1000) if audio_duration_s > 0 else 0.0,
        )

    word_output = process_words(ref, hyp)

    clip_wer = compute_wer(ref, hyp)
    clip_cer = compute_cer(ref, hyp)

    rtf = (decode_time_ms / 1000) / audio_duration_s if audio_duration_s > 0 else 0.0

    return ClipResult(
        clip=clip_name,
        ground_truth=ref,
        hypothesis=hyp,
        wer=clip_wer,
        cer=clip_cer,
        substitutions=word_output.substitutions,
        insertions=word_output.insertions,
        deletions=word_output.deletions,
        hits=word_output.hits,
        decode_time_ms=decode_time_ms,
        audio_duration_s=audio_duration_s,
        rtf=rtf,
    )


def evaluate_corpus(
    results: list[ClipResult],
    model_name: str,
    mode: str = "full",
    config: dict | None = None,
) -> EvalResult:
    """Aggregate per-clip results into a corpus-level evaluation."""
    if not results:
        return EvalResult(model_name=model_name, mode=mode, config=config or {})

    # Compute aggregate WER/CER over the full corpus (not mean of per-clip)
    all_refs = [r.ground_truth for r in results]
    all_hyps = [r.hypothesis for r in results]

    agg_wer = compute_wer(all_refs, all_hyps)
    agg_cer = compute_cer(all_refs, all_hyps)

    mean_decode = sum(r.decode_time_ms for r in results) / len(results)
    mean_rtf = sum(r.rtf for r in results) / len(results)

    return EvalResult(
        model_name=model_name,
        mode=mode,
        clips=results,
        aggregate_wer=agg_wer,
        aggregate_cer=agg_cer,
        mean_decode_ms=mean_decode,
        mean_rtf=mean_rtf,
        total_clips=len(results),
        config=config or {},
    )


def format_markdown(result: EvalResult) -> str:
    """Format an EvalResult as a Markdown report."""
    lines: list[str] = []

    lines.append(f"# STT Evaluation: {result.model_name} ({result.mode})")
    lines.append(f"")
    lines.append(f"Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}")
    lines.append(f"")

    # Aggregate metrics
    lines.append("## Aggregate Metrics")
    lines.append("")
    lines.append("| Metric | Value |")
    lines.append("|--------|-------|")
    lines.append(f"| WER | {result.aggregate_wer:.2%} |")
    lines.append(f"| CER | {result.aggregate_cer:.2%} |")
    lines.append(f"| Mean Decode (ms) | {result.mean_decode_ms:.1f} |")
    lines.append(f"| Mean RTF | {result.mean_rtf:.3f} |")
    lines.append(f"| Total Clips | {result.total_clips} |")
    lines.append("")

    if not result.clips:
        return "\n".join(lines)

    # Error type breakdown
    total_s = sum(c.substitutions for c in result.clips)
    total_i = sum(c.insertions for c in result.clips)
    total_d = sum(c.deletions for c in result.clips)
    total_h = sum(c.hits for c in result.clips)
    total_ops = total_s + total_i + total_d + total_h
    lines.append("## Error Type Breakdown (S/I/D)")
    lines.append("")
    lines.append("| Type | Count | % of Total |")
    lines.append("|------|-------|------------|")
    if total_ops > 0:
        lines.append(f"| Substitutions | {total_s} | {total_s / total_ops:.1%} |")
        lines.append(f"| Insertions | {total_i} | {total_i / total_ops:.1%} |")
        lines.append(f"| Deletions | {total_d} | {total_d / total_ops:.1%} |")
        lines.append(f"| Hits | {total_h} | {total_h / total_ops:.1%} |")
    lines.append("")

    # Per-clip detail table
    lines.append("## Per-Clip Results")
    lines.append("")
    lines.append("| Clip | WER | CER | S | I | D | Decode (ms) | RTF |")
    lines.append("|------|-----|-----|---|---|---|-------------|-----|")
    for c in result.clips:
        lines.append(
            f"| {c.clip} | {c.wer:.2%} | {c.cer:.2%} "
            f"| {c.substitutions} | {c.insertions} | {c.deletions} "
            f"| {c.decode_time_ms:.1f} | {c.rtf:.3f} |"
        )
    lines.append("")

    # Worst clips (top 5 by WER)
    worst = sorted(result.clips, key=lambda c: c.wer, reverse=True)[:5]
    lines.append("## Worst Clips (by WER)")
    lines.append("")
    for c in worst:
        lines.append(f"### {c.clip} (WER: {c.wer:.2%})")
        lines.append(f"- **Reference**: {c.ground_truth}")
        lines.append(f"- **Hypothesis**: {c.hypothesis}")
        lines.append(f"- S={c.substitutions} I={c.insertions} D={c.deletions}")
        lines.append("")

    # Config used
    if result.config:
        lines.append("## Configuration")
        lines.append("")
        lines.append("```json")
        lines.append(json.dumps(result.config, indent=2))
        lines.append("```")
        lines.append("")

    return "\n".join(lines)


def save_results(result: EvalResult, output_dir: Path | None = None) -> Path:
    """Save evaluation results as JSON + Markdown.

    Returns the path to the JSON file.
    """
    output_dir = output_dir or RESULTS_DIR
    output_dir.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    base_name = f"{result.model_name}_{result.mode}_{timestamp}"

    # JSON
    json_path = output_dir / f"{base_name}.json"
    json_data = {
        "model_name": result.model_name,
        "mode": result.mode,
        "aggregate_wer": result.aggregate_wer,
        "aggregate_cer": result.aggregate_cer,
        "mean_decode_ms": result.mean_decode_ms,
        "mean_rtf": result.mean_rtf,
        "total_clips": result.total_clips,
        "config": result.config,
        "clips": [
            {
                "clip": c.clip,
                "ground_truth": c.ground_truth,
                "hypothesis": c.hypothesis,
                "wer": c.wer,
                "cer": c.cer,
                "substitutions": c.substitutions,
                "insertions": c.insertions,
                "deletions": c.deletions,
                "hits": c.hits,
                "decode_time_ms": c.decode_time_ms,
                "audio_duration_s": c.audio_duration_s,
                "rtf": c.rtf,
            }
            for c in result.clips
        ],
    }
    json_path.write_text(json.dumps(json_data, indent=2, ensure_ascii=False), encoding="utf-8")

    # Markdown
    md_path = output_dir / f"{base_name}.md"
    md_path.write_text(format_markdown(result), encoding="utf-8")

    return json_path


def compare_results(a: EvalResult, b: EvalResult) -> str:
    """Produce a Markdown comparison table between two evaluation runs."""
    lines: list[str] = []
    lines.append(f"# Comparison: {a.model_name} ({a.mode}) vs {b.model_name} ({b.mode})")
    lines.append("")
    lines.append("| Metric | A | B | Delta |")
    lines.append("|--------|---|---|-------|")

    def _row(label: str, va: float, vb: float, fmt: str = ".2%") -> str:
        delta = vb - va
        sign = "+" if delta > 0 else ""
        return f"| {label} | {va:{fmt}} | {vb:{fmt}} | {sign}{delta:{fmt}} |"

    lines.append(_row("WER", a.aggregate_wer, b.aggregate_wer))
    lines.append(_row("CER", a.aggregate_cer, b.aggregate_cer))
    lines.append(_row("Mean Decode (ms)", a.mean_decode_ms, b.mean_decode_ms, ".1f"))
    lines.append(_row("Mean RTF", a.mean_rtf, b.mean_rtf, ".3f"))
    lines.append(f"| Total Clips | {a.total_clips} | {b.total_clips} | |")
    lines.append("")

    # Per-clip comparison for clips present in both
    a_clips = {c.clip: c for c in a.clips}
    b_clips = {c.clip: c for c in b.clips}
    shared = sorted(set(a_clips) & set(b_clips))

    if shared:
        lines.append("## Per-Clip WER Comparison")
        lines.append("")
        lines.append("| Clip | WER (A) | WER (B) | Delta |")
        lines.append("|------|---------|---------|-------|")
        for name in shared:
            ca, cb = a_clips[name], b_clips[name]
            d = cb.wer - ca.wer
            sign = "+" if d > 0 else ""
            lines.append(f"| {name} | {ca.wer:.2%} | {cb.wer:.2%} | {sign}{d:.2%} |")
        lines.append("")

    return "\n".join(lines)
