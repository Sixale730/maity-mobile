"""Configuration for the STT autoresearch evaluation framework."""

from __future__ import annotations

import re
import unicodedata
from pathlib import Path

# ── Paths ──────────────────────────────────────────────────────────────────────
AUTORESEARCH_DIR = Path(__file__).parent
CORPUS_DIR = AUTORESEARCH_DIR / "corpus"
RESULTS_DIR = AUTORESEARCH_DIR / "results"

# ── Audio ──────────────────────────────────────────────────────────────────────
SAMPLE_RATE = 16000
CHUNK_DURATION_S = 5.0

# ── VAD defaults (mirrors lib/services/local_stt/local_stt_engine.dart) ───────
VAD_THRESHOLD = 0.5
VAD_MIN_SPEECH_DURATION = 0.8   # seconds – filters noise/clicks < 0.8s
VAD_MIN_SILENCE_DURATION = 1.0  # seconds (Canary overrides to 0.3)
VAD_MAX_SPEECH_DURATION = 30.0  # seconds
VAD_WINDOW_SIZE = 512

# ── Padding (mirrors _padWithSilence in local_stt_engine.dart) ─────────────────
PRE_PAD_SAMPLES = 6400          # 0.4s at 16 kHz, all models
POST_PAD_SAMPLES_DEFAULT = 4800  # 0.3s for Parakeet / Moonshine
POST_PAD_SAMPLES_CANARY = 8000   # 0.5s for Canary

# ── Model configurations ──────────────────────────────────────────────────────
# Each entry maps to a sherpa_onnx OfflineRecognizerConfig.
# "files" lists the expected filenames inside the model directory.

MODEL_CONFIGS: dict[str, dict] = {
    "parakeet": {
        "type": "transducer",
        "model_type": "nemo_transducer",
        "decoding_method": "greedy_search",
        "files": {
            "encoder": "encoder.int8.onnx",
            "decoder": "decoder.int8.onnx",
            "joiner": "joiner.int8.onnx",
            "tokens": "tokens.txt",
        },
        "vad": {
            "threshold": VAD_THRESHOLD,
            "min_speech_duration": VAD_MIN_SPEECH_DURATION,
            "min_silence_duration": VAD_MIN_SILENCE_DURATION,
            "max_speech_duration": VAD_MAX_SPEECH_DURATION,
            "window_size": VAD_WINDOW_SIZE,
        },
        "post_pad_samples": POST_PAD_SAMPLES_DEFAULT,
    },
    "moonshine": {
        "type": "moonshine",
        "decoding_method": "greedy_search",
        "files": {
            "encoder": "encoder_model.ort",
            "merged_decoder": "decoder_model_merged.ort",
            "tokens": "tokens.txt",
        },
        "vad": {
            "threshold": VAD_THRESHOLD,
            "min_speech_duration": VAD_MIN_SPEECH_DURATION,
            "min_silence_duration": VAD_MIN_SILENCE_DURATION,
            "max_speech_duration": VAD_MAX_SPEECH_DURATION,
            "window_size": VAD_WINDOW_SIZE,
        },
        "post_pad_samples": POST_PAD_SAMPLES_DEFAULT,
    },
    "canary": {
        "type": "canary",
        "src_lang": "es",
        "tgt_lang": "es",
        "use_pnc": True,
        "files": {
            "encoder": "encoder.int8.onnx",
            "decoder": "decoder.int8.onnx",
            "tokens": "tokens.txt",
        },
        "vad": {
            "threshold": VAD_THRESHOLD,
            "min_speech_duration": VAD_MIN_SPEECH_DURATION,
            "min_silence_duration": 0.3,  # Canary uses faster silence detection
            "max_speech_duration": VAD_MAX_SPEECH_DURATION,
            "window_size": VAD_WINDOW_SIZE,
        },
        "post_pad_samples": POST_PAD_SAMPLES_CANARY,
    },
}

# Characters to keep during normalization (Spanish accented + ñ + ü)
_KEEP_CHARS = set("áéíóúñü")


def normalize_text(text: str) -> str:
    """Normalize text for WER/CER comparison.

    - Lowercase
    - Remove punctuation (keeps accented Spanish chars)
    - Collapse whitespace
    - Strip
    """
    text = text.lower()
    # Keep letters, digits, whitespace, and Spanish accented characters
    text = re.sub(
        r"[^\w\s]",
        lambda m: m.group() if m.group() in _KEEP_CHARS else "",
        text,
    )
    # \w already keeps accented chars via Unicode, but also keeps _
    text = text.replace("_", " ")
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def load_corpus(corpus_dir: Path | None = None) -> list[tuple[Path, str]]:
    """Find .wav files with matching .txt ground-truth transcripts.

    Returns a sorted list of (wav_path, ground_truth_text) tuples.
    Only includes pairs where both .wav and .txt exist.
    """
    corpus_dir = corpus_dir or CORPUS_DIR
    pairs: list[tuple[Path, str]] = []

    for wav_path in sorted(corpus_dir.rglob("*.wav")):
        txt_path = wav_path.with_suffix(".txt")
        if txt_path.exists():
            ground_truth = txt_path.read_text(encoding="utf-8").strip()
            if ground_truth:
                pairs.append((wav_path, ground_truth))

    return pairs
