# STT Autoresearch Protocol

Systematic optimization of on-device speech-to-text accuracy for Maity, applying
Karpathy's autoresearch loop: **EDIT one parameter, RUN the benchmark, MEASURE WER,
KEEP improvements / DISCARD regressions.** Repeat.

## 1. Protocol

```
┌─────────────────────────────────────────────────────────┐
│  1. EDIT   — change exactly ONE parameter in config     │
│  2. RUN    — python benchmark.py  (fixed corpus)        │
│  3. MEASURE — WER / CER / RTF computed by evaluator.py  │
│  4. DECIDE                                              │
│     ├─ IF improved  → git commit, update STATE.json     │
│     └─ IF regressed → git checkout, log in history      │
│  5. GOTO 1                                              │
└─────────────────────────────────────────────────────────┘
```

### Rules

- **One mutable parameter per iteration.** Never change two things at once.
- **Fixed corpus.** The wav+txt pairs in `corpus/` must not change during a run.
- **Fixed metric.** Word Error Rate (WER) via `jiwer` is the primary measure.
- **Git as experiment tracker.** Each successful experiment is a commit.
- **Results logged.** Every run writes JSON + Markdown to `results/` and updates
  `STATE.json`.

## 2. Metrics

| Metric | Source | Role |
|--------|--------|------|
| **WER** (Word Error Rate) | `jiwer.wer` | Primary — lower is better |
| **CER** (Character Error Rate) | `jiwer.cer` | Secondary — catches sub-word errors |
| **RTF** (Real-Time Factor) | `decode_ms / (audio_s * 1000)` | Performance gate — must be < 1.0 |
| **Mean Decode (ms)** | per-clip average | Latency indicator |
| **S / I / D** | `jiwer.process_words` | Error breakdown: Substitutions, Insertions, Deletions |

Text is normalized before comparison (`config.normalize_text`): lowercase, strip
punctuation (keep Spanish accented chars), collapse whitespace.

## 3. Parameter Space

Parameters are grouped into three layers, ordered from cheapest-to-change to most
expensive. Always exhaust Layer 1 before moving to Layer 2.

| # | Parameter | Config Key | Current Default | Range to Explore | Layer |
|---|-----------|------------|-----------------|-------------------|-------|
| 1 | VAD threshold | `VAD_THRESHOLD` | 0.5 | 0.3 -- 0.7 | 1 |
| 2 | VAD min speech duration | `VAD_MIN_SPEECH_DURATION` | 0.8 s | 0.3 -- 1.5 s | 1 |
| 3 | VAD min silence duration | `VAD_MIN_SILENCE_DURATION` | 1.0 s (canary: 0.3) | 0.2 -- 2.0 s | 1 |
| 4 | VAD max speech duration | `VAD_MAX_SPEECH_DURATION` | 30.0 s | 10 -- 60 s | 1 |
| 5 | Pre-pad silence | `PRE_PAD_SAMPLES` | 6400 (0.4 s) | 1600 -- 12800 (0.1 -- 0.8 s) | 2 |
| 6 | Post-pad silence | `POST_PAD_SAMPLES_DEFAULT` / `_CANARY` | 4800 / 8000 (0.3 / 0.5 s) | 1600 -- 16000 (0.1 -- 1.0 s) | 2 |
| 7 | Chunk duration | `CHUNK_DURATION_S` | 5.0 s | 3.0 -- 10.0 s | 2 |
| 8 | Chunk overlap | (not yet implemented) | 0 s | 0 -- 1.0 s | 2 |
| 9 | Model selection | `model_type` arg | per-user | parakeet / moonshine / canary | 3 |
| 10 | Decoding method | `decoding_method` | greedy_search | greedy_search / modified_beam_search | 3 |
| 11 | Num threads | hardcoded in `stt_runner.py` | 2 | 1 -- 4 | 3 |

## 4. Modification Strategy (Layers)

### Layer 1: VAD Parameters

Cheapest to change -- no model reload needed. Controls how Silero VAD segments
speech from silence. Has the biggest impact on segmentation quality:

- **threshold** too low = noise passed to decoder = insertion errors
- **threshold** too high = clipped speech = deletion errors
- **min_silence_duration** too short = over-segmentation = boundary artifacts
- **min_silence_duration** too long = under-segmentation = long segments that stress
  the decoder

### Layer 2: Chunking and Padding

Affects boundary effects and decoder onset/offset behavior:

- **Pre-pad silence** gives FastConformer a clean silence-to-speech onset. Too short
  and the encoder may clip the first word. Too long wastes compute.
- **Post-pad silence** provides the end-of-utterance signal. Canary needs more than
  Parakeet because it is encoder-decoder (not transducer).
- **Chunk duration** controls how much audio is written to disk per chunk. Smaller
  chunks = more boundary crossings. Larger = more latency before results.

### Layer 3: Model and Decode Configuration

Most expensive -- changes the decoder entirely. Only explore after Layers 1-2 are
locally optimal:

- **Model selection**: Parakeet (transducer, tolerates force-flush), Moonshine
  (small, Spanish-optimized), Canary (encoder-decoder, produces "(EMPTY)" on
  continuous speech without pauses).
- **Decoding method**: `greedy_search` vs `modified_beam_search` (beam search is
  slower but may reduce substitution errors).
- **Num threads**: More threads = faster decode but higher memory pressure. Diminishing
  returns past 2 on mobile.

## 5. Scoring Criteria

| WER Range | Rating | Action |
|-----------|--------|--------|
| < 10% | Excellent | Commit and move to next parameter |
| 10 -- 20% | Good | Commit; consider further tuning |
| 20 -- 30% | Needs work | Investigate error breakdown (S/I/D) |
| > 30% | Investigate | Check corpus quality, VAD segmentation, model compatibility |

**Performance gate:** RTF must be < 1.0 (faster than real-time). If a parameter
change pushes RTF above 1.0, discard it regardless of WER improvement.

## 6. How to Run

### Prerequisites

```bash
pip install sherpa-onnx jiwer numpy
```

Models must be downloaded to their expected directories (see `config.py`
`MODEL_CONFIGS` for required files per model). Silero VAD (`silero_vad.onnx`) must
be present in each model directory.

### Setup corpus

```bash
cd tools/autoresearch
python setup_corpus.py
```

Place wav+txt pairs in `corpus/`. Each `.wav` must have a matching `.txt` with the
ground-truth transcript. Audio format: 16 kHz, mono, 16-bit PCM.

### Run baseline

```bash
python benchmark.py --model parakeet --model-dir /path/to/parakeet-tdt-0.6b-v3 \
  --mode full --save baseline
```

### Run experiment with VAD override

```bash
python benchmark.py --model parakeet --model-dir /path/to/parakeet-tdt-0.6b-v3 \
  --mode chunked --vad-threshold 0.4 --vad-min-silence 0.5 --save experiment-1
```

### Compare two runs

```bash
python benchmark.py --compare baseline experiment-1
```

### Run on chunked mode (mirrors app behavior)

```bash
python benchmark.py --model parakeet --model-dir /path/to/parakeet-tdt-0.6b-v3 \
  --mode chunked --chunk-duration 5.0 --save chunked-baseline
```

## 7. Keep / Discard Protocol

After each experiment run:

```
new_wer = result from benchmark.py
best_wer = STATE.json -> models.{model}.best_wer

IF new_wer < best_wer:
    # KEEP — the change improved accuracy
    1. Update STATE.json:
       - models.{model}.best_wer = new_wer
       - models.{model}.runs += 1
       - bestWer = min across all models
       - Append to history[]
    2. git add tools/autoresearch/
    3. git commit -m "autoresearch: {param}={value} WER {old}% -> {new}%"
    4. Advance currentFocus to next parameter or layer

ELIF new_wer > best_wer + 0.02:
    # DISCARD — regression exceeds 2pp tolerance
    1. git checkout -- tools/autoresearch/results/
    2. Log attempt in STATE.json history with "kept": false
    3. Try a different value for the same parameter, or move on

ELSE:
    # NEUTRAL — within noise margin
    1. Log in history with "kept": false, "note": "within noise margin"
    2. Move to next parameter value
```

## 8. Constraints

1. **Never modify the corpus during an experiment run.** Adding or removing clips
   invalidates all prior comparisons.
2. **Never change multiple parameters simultaneously.** The loop cannot attribute
   improvement to a specific change if two things moved.
3. **Always record the full config snapshot with each result.** The `config` field
   in `evaluator.py`'s JSON output captures VAD params, padding, model type, etc.
4. **Revert if WER regresses by more than 2 percentage points on any single clip.**
   A global improvement that destroys one clip usually indicates overfitting to the
   corpus.
5. **RTF gate.** Discard any change that pushes mean RTF above 1.0 regardless of
   WER improvement.
6. **Reproducibility.** Same corpus + same config + same model files must produce
   the same WER within floating-point tolerance. If results vary across runs, the
   corpus or environment has a problem.

## 9. File Map

```
tools/autoresearch/
  PROGRAM.md          <- this file (protocol reference)
  STATE.json          <- experiment state tracker
  config.py           <- defaults, normalize_text, load_corpus
  stt_runner.py       <- sherpa_onnx runner (full + chunked modes)
  evaluator.py        <- WER/CER computation, reports
  benchmark.py        <- CLI entry point (run, compare, save)
  setup_corpus.py     <- copy test audio to corpus/
  corpus/             <- wav+txt pairs (gitignored)
  results/            <- JSON+MD reports per run (gitignored)
```
