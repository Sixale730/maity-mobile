"""Run sherpa_onnx offline speech recognition on audio files.

Mirrors the behaviour of the Dart LocalSttEngine + LocalSttWorker in the
Maity mobile app, providing both full-file and chunked processing modes
with Silero VAD and configurable model backends.
"""

from __future__ import annotations

import time
import wave
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import sherpa_onnx

from config import (
    CHUNK_DURATION_S,
    MODEL_CONFIGS,
    POST_PAD_SAMPLES_CANARY,
    POST_PAD_SAMPLES_DEFAULT,
    PRE_PAD_SAMPLES,
    SAMPLE_RATE,
    VAD_MAX_SPEECH_DURATION,
    VAD_MIN_SILENCE_DURATION,
    VAD_MIN_SPEECH_DURATION,
    VAD_THRESHOLD,
    VAD_WINDOW_SIZE,
)

# ── Data classes ─────────────────────────────────────────────────────────────


@dataclass
class SttSegment:
    text: str
    start_time: float
    end_time: float


@dataclass
class SttResult:
    segments: list[SttSegment] = field(default_factory=list)
    full_text: str = ""
    decode_time_ms: float = 0.0
    audio_duration_s: float = 0.0


# ── Silence padding (mirrors Dart _padWithSilence) ──────────────────────────


def pad_with_silence(samples: np.ndarray, model_type: str) -> np.ndarray:
    """Pad audio with silence at both ends for clean encoder boundaries.

    Pre-pad (0.4s): gives FastConformer a clear silence-to-speech onset.
    Post-pad (0.3s parakeet/moonshine, 0.5s canary): end-of-utterance signal.
    """
    pre_pad = PRE_PAD_SAMPLES  # 6400 = 0.4s
    post_pad = POST_PAD_SAMPLES_CANARY if model_type == "canary" else POST_PAD_SAMPLES_DEFAULT
    padded = np.zeros(pre_pad + len(samples) + post_pad, dtype=np.float32)
    padded[pre_pad : pre_pad + len(samples)] = samples
    return padded


# ── Repetition truncation (mirrors Dart _truncateRepetitions) ────────────────


def truncate_repetitions(text: str) -> str:
    """Detect and truncate decoder repetition loops.

    Checks for repeated N-gram patterns (1-5 words) at the tail.
    If 3+ consecutive repetitions found, truncates to first occurrence.
    """
    if not text:
        return text
    words = text.split(" ")
    if len(words) < 6:
        return text

    for pat_len in range(1, 6):
        if len(words) < pat_len * 3:
            continue

        pattern = " ".join(words[len(words) - pat_len :])
        repeats = 0
        pos = len(words) - pat_len

        while pos >= pat_len:
            chunk = " ".join(words[pos - pat_len : pos])
            if chunk == pattern:
                repeats += 1
                pos -= pat_len
            else:
                break

        # 3+ consecutive repetitions = hallucination, keep first occurrence
        if repeats >= 3:
            truncated = " ".join(words[: pos + pat_len])
            print(f'[stt_runner] Truncated {repeats} repetitions of "{pattern}"')
            return truncated

    return text


# ── Audio loading ────────────────────────────────────────────────────────────


def load_wav(audio_path: Path) -> np.ndarray:
    """Read a WAV file and return float32 samples normalized to [-1, 1]."""
    with wave.open(str(audio_path), "rb") as wf:
        assert wf.getnchannels() == 1, (
            f"Expected mono audio, got {wf.getnchannels()} channels"
        )
        assert wf.getsampwidth() == 2, (
            f"Expected 16-bit PCM, got {wf.getsampwidth() * 8}-bit"
        )
        sr = wf.getframerate()
        if sr != SAMPLE_RATE:
            print(
                f"[stt_runner] WARNING: WAV sample rate is {sr}, expected {SAMPLE_RATE}"
            )
        pcm16 = np.frombuffer(wf.readframes(wf.getnframes()), dtype=np.int16)
    return pcm16.astype(np.float32) / 32768.0


# ── Model creation ───────────────────────────────────────────────────────────


def _validate_model_files(model_dir: Path, model_type: str) -> None:
    """Check that all required model files exist."""
    cfg = MODEL_CONFIGS[model_type]
    for key, filename in cfg["files"].items():
        fpath = model_dir / filename
        if not fpath.exists():
            raise FileNotFoundError(
                f"Missing {key} file for {model_type}: {fpath}"
            )
    vad_path = model_dir / "silero_vad.onnx"
    if not vad_path.exists():
        raise FileNotFoundError(f"Missing VAD model: {vad_path}")


def _create_recognizer(
    model_dir: Path, model_type: str
) -> sherpa_onnx.OfflineRecognizer:
    """Create a sherpa_onnx OfflineRecognizer using Python factory methods."""
    md = str(model_dir)
    cfg = MODEL_CONFIGS[model_type]

    if model_type == "parakeet":
        return sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=f"{md}/{cfg['files']['encoder']}",
            decoder=f"{md}/{cfg['files']['decoder']}",
            joiner=f"{md}/{cfg['files']['joiner']}",
            tokens=f"{md}/{cfg['files']['tokens']}",
            model_type=cfg["model_type"],
            num_threads=2,
            decoding_method=cfg["decoding_method"],
            debug=False,
            provider="cpu",
        )
    elif model_type == "moonshine":
        return sherpa_onnx.OfflineRecognizer.from_moonshine_v2(
            encoder=f"{md}/{cfg['files']['encoder']}",
            decoder=f"{md}/{cfg['files']['merged_decoder']}",
            tokens=f"{md}/{cfg['files']['tokens']}",
            num_threads=2,
            decoding_method=cfg["decoding_method"],
            debug=False,
            provider="cpu",
        )
    elif model_type == "canary":
        return sherpa_onnx.OfflineRecognizer.from_nemo_canary(
            encoder=f"{md}/{cfg['files']['encoder']}",
            decoder=f"{md}/{cfg['files']['decoder']}",
            tokens=f"{md}/{cfg['files']['tokens']}",
            src_lang=cfg["src_lang"],
            tgt_lang=cfg["tgt_lang"],
            num_threads=2,
            debug=False,
            provider="cpu",
        )
    else:
        raise ValueError(f"Unknown model type: {model_type}")


def _create_vad(
    model_dir: Path,
    *,
    threshold: float = VAD_THRESHOLD,
    min_speech_duration: float = VAD_MIN_SPEECH_DURATION,
    min_silence_duration: float = VAD_MIN_SILENCE_DURATION,
    max_speech_duration: float = VAD_MAX_SPEECH_DURATION,
    window_size: int = VAD_WINDOW_SIZE,
) -> sherpa_onnx.VoiceActivityDetector:
    """Create a Silero VAD instance."""
    vad_config = sherpa_onnx.VadModelConfig(
        silero_vad=sherpa_onnx.SileroVadModelConfig(
            model=str(model_dir / "silero_vad.onnx"),
            min_speech_duration=min_speech_duration,
            min_silence_duration=min_silence_duration,
            threshold=threshold,
            window_size=window_size,
            max_speech_duration=max_speech_duration,
        ),
        sample_rate=SAMPLE_RATE,
        num_threads=1,
        provider="cpu",
        debug=False,
    )
    return sherpa_onnx.VoiceActivityDetector(
        config=vad_config, buffer_size_in_seconds=120
    )


# ── Segment draining (mirrors Dart _drainSegments) ──────────────────────────


def _drain_segments(
    vad: sherpa_onnx.VoiceActivityDetector,
    recognizer: sherpa_onnx.OfflineRecognizer,
    model_type: str,
    offset_seconds: float = 0.0,
) -> list[SttSegment]:
    """Drain all queued speech segments from VAD and decode each one."""
    results: list[SttSegment] = []
    seg_count = 0

    while not vad.empty():
        segment = vad.front
        seg_count += 1

        start_sample = segment.start
        samples = np.array(segment.samples, dtype=np.float32)
        start_time = start_sample / SAMPLE_RATE + offset_seconds
        end_time = (start_sample + len(samples)) / SAMPLE_RATE + offset_seconds
        duration_ms = int((end_time - start_time - offset_seconds) * 1000)

        # Pad with silence for clean encoder boundaries
        padded = pad_with_silence(samples, model_type)

        # Decode
        stream = recognizer.create_stream()
        stream.accept_waveform(SAMPLE_RATE, padded.tolist())
        recognizer.decode_stream(stream)

        text = stream.result.text.strip()

        # Truncate repetition loops
        text = truncate_repetitions(text)

        if text:
            results.append(SttSegment(text=text, start_time=start_time, end_time=end_time))

        vad.pop()

    return results


# ── Processing modes ─────────────────────────────────────────────────────────


def _process_full(
    samples: np.ndarray,
    vad: sherpa_onnx.VoiceActivityDetector,
    recognizer: sherpa_onnx.OfflineRecognizer,
    model_type: str,
    max_speech_duration: float,
) -> list[SttSegment]:
    """Full-file mode: feed entire audio to VAD, decode all segments."""
    print(f"[stt_runner] Full-file mode: {len(samples)} samples ({len(samples) / SAMPLE_RATE:.1f}s)")

    # Feed audio in window_size chunks (required by Silero VAD)
    window_size = VAD_WINDOW_SIZE
    samples_since_last_drain = 0
    max_samples = int(max_speech_duration * SAMPLE_RATE)
    all_segments: list[SttSegment] = []

    for i in range(0, len(samples), window_size):
        chunk = samples[i : i + window_size]
        if len(chunk) < window_size:
            # Pad final chunk with zeros
            padded_chunk = np.zeros(window_size, dtype=np.float32)
            padded_chunk[: len(chunk)] = chunk
            chunk = padded_chunk

        vad.accept_waveform(chunk.tolist())

        # Force-flush for transducer models (mirrors Dart logic)
        if vad.is_speech_detected():
            samples_since_last_drain += len(chunk)

        if samples_since_last_drain >= max_samples and model_type != "canary":
            print(
                f"[stt_runner] Force-flushing VAD after "
                f"{samples_since_last_drain / SAMPLE_RATE:.1f}s of speech"
            )
            vad.flush()
            samples_since_last_drain = 0

        # Drain any completed segments
        drained = _drain_segments(vad, recognizer, model_type)
        if drained:
            samples_since_last_drain = 0
            all_segments.extend(drained)

    # Final flush to catch trailing speech
    vad.flush()
    final = _drain_segments(vad, recognizer, model_type)
    all_segments.extend(final)

    return all_segments


def _process_chunked(
    samples: np.ndarray,
    vad: sherpa_onnx.VoiceActivityDetector,
    recognizer: sherpa_onnx.OfflineRecognizer,
    model_type: str,
    max_speech_duration: float,
    chunk_duration_s: float,
) -> list[SttSegment]:
    """Chunked mode: split audio into N-second chunks, process sequentially.

    Mirrors AudioChunkWriter (5s chunks) + LocalSttWorker.handleProcessChunk.
    VAD state carries across chunks (no reset between chunks).
    """
    chunk_samples = int(chunk_duration_s * SAMPLE_RATE)
    total_chunks = (len(samples) + chunk_samples - 1) // chunk_samples
    print(
        f"[stt_runner] Chunked mode: {total_chunks} chunks of {chunk_duration_s}s "
        f"({len(samples)} samples, {len(samples) / SAMPLE_RATE:.1f}s total)"
    )

    window_size = VAD_WINDOW_SIZE
    samples_since_last_drain = 0
    max_samples = int(max_speech_duration * SAMPLE_RATE)
    all_segments: list[SttSegment] = []

    for chunk_idx in range(total_chunks):
        start = chunk_idx * chunk_samples
        end = min(start + chunk_samples, len(samples))
        chunk = samples[start:end]
        offset_s = start / SAMPLE_RATE

        # Feed chunk through VAD in window_size steps
        for i in range(0, len(chunk), window_size):
            window = chunk[i : i + window_size]
            if len(window) < window_size:
                padded_window = np.zeros(window_size, dtype=np.float32)
                padded_window[: len(window)] = window
                window = padded_window

            vad.accept_waveform(window.tolist())

            # Force-flush for transducer models
            if vad.is_speech_detected():
                samples_since_last_drain += len(window)

            if samples_since_last_drain >= max_samples and model_type != "canary":
                print(
                    f"[stt_runner] Force-flushing VAD after "
                    f"{samples_since_last_drain / SAMPLE_RATE:.1f}s of speech"
                )
                vad.flush()
                samples_since_last_drain = 0

            # Drain any completed segments
            drained = _drain_segments(vad, recognizer, model_type, offset_seconds=0.0)
            if drained:
                samples_since_last_drain = 0
                all_segments.extend(drained)

        print(
            f"[stt_runner] Chunk {chunk_idx + 1}/{total_chunks} processed "
            f"({len(all_segments)} segments so far)"
        )

    # Final flush to catch trailing speech
    vad.flush()
    final = _drain_segments(vad, recognizer, model_type)
    all_segments.extend(final)

    return all_segments


# ── Public API ───────────────────────────────────────────────────────────────


def run_stt(
    audio_path: Path,
    model_dir: Path,
    model_type: str = "parakeet",
    mode: str = "full",
    vad_threshold: float = VAD_THRESHOLD,
    min_speech_duration: float = VAD_MIN_SPEECH_DURATION,
    min_silence_duration: float | None = None,
    max_speech_duration: float = VAD_MAX_SPEECH_DURATION,
    chunk_duration_s: float = CHUNK_DURATION_S,
) -> SttResult:
    """Run STT on an audio file with configurable parameters.

    Args:
        audio_path: Path to a 16 kHz mono 16-bit PCM WAV file.
        model_dir: Directory containing model files and silero_vad.onnx.
        model_type: One of "parakeet", "moonshine", "canary".
        mode: "full" (whole file) or "chunked" (5s chunks like the app).
        vad_threshold: Silero VAD speech probability threshold.
        min_speech_duration: Minimum speech duration to keep (seconds).
        min_silence_duration: Silence gap to split segments. None = auto per model.
        max_speech_duration: Max speech before force-flush (seconds).
        chunk_duration_s: Chunk size for chunked mode (seconds).

    Returns:
        SttResult with decoded segments, full text, and timing info.
    """
    if model_type not in MODEL_CONFIGS:
        raise ValueError(
            f"Unknown model_type '{model_type}'. "
            f"Must be one of: {', '.join(MODEL_CONFIGS)}"
        )

    # Auto-select min_silence_duration per model (mirrors Dart logic)
    if min_silence_duration is None:
        min_silence_duration = MODEL_CONFIGS[model_type]["vad"]["min_silence_duration"]

    # Validate model files
    _validate_model_files(model_dir, model_type)

    # Load audio
    print(f"[stt_runner] Loading audio: {audio_path}")
    samples = load_wav(audio_path)
    audio_duration_s = len(samples) / SAMPLE_RATE
    print(f"[stt_runner] Audio: {audio_duration_s:.1f}s, {len(samples)} samples")

    # Create recognizer and VAD
    print(f"[stt_runner] Loading model: {model_type} from {model_dir}")
    t0 = time.perf_counter()
    recognizer = _create_recognizer(model_dir, model_type)
    vad = _create_vad(
        model_dir,
        threshold=vad_threshold,
        min_speech_duration=min_speech_duration,
        min_silence_duration=min_silence_duration,
        max_speech_duration=max_speech_duration,
    )
    load_ms = (time.perf_counter() - t0) * 1000
    print(f"[stt_runner] Model loaded in {load_ms:.0f}ms")

    # Process
    t1 = time.perf_counter()
    if mode == "chunked":
        segments = _process_chunked(
            samples, vad, recognizer, model_type, max_speech_duration, chunk_duration_s
        )
    else:
        segments = _process_full(
            samples, vad, recognizer, model_type, max_speech_duration
        )
    decode_time_ms = (time.perf_counter() - t1) * 1000

    full_text = " ".join(seg.text for seg in segments)
    print(
        f"[stt_runner] Done: {len(segments)} segments, "
        f"{decode_time_ms:.0f}ms decode, "
        f"{audio_duration_s:.1f}s audio"
    )

    return SttResult(
        segments=segments,
        full_text=full_text,
        decode_time_ms=decode_time_ms,
        audio_duration_s=audio_duration_s,
    )
