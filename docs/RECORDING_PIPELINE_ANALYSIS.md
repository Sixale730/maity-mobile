# Recording Pipeline: Deep Analysis Report

**Date**: March 4, 2026
**Scope**: End-to-end (Flutter + Backend + Supabase)
**Team**: 4 specialized agents (architecture, reliability, performance, backend)
**Branch analyzed**: `refactor/capture-decomposition`

---

## Executive Summary

The recording pipeline is architecturally sound after the God Class refactor, with good multi-layer persistence and correct recent bug fixes. However, the analysis uncovered **3 critical security/data-integrity issues**, **6 high-severity issues**, and **10 medium-severity issues** that need attention.

**Top 5 most impactful findings:**

1. **CRITICAL**: All backend recording endpoints have optional authentication + IDOR vulnerability
2. **HIGH**: Finalize blocks the stop-recording UI for 26-86+ seconds (user perceives app as frozen)
3. **CRITICAL**: Status "abandoned" rejected by DB CHECK constraint — orphan cleanup is broken
4. **CRITICAL**: Finalize endpoint is not idempotent — retries create duplicate memories
5. **HIGH**: Audio buffer grows unbounded during BLE recordings (~115 MB / 60 min)

---

## 1. Refactor Assessment (God Class → 5 Services)

**Overall Rating: 3.8/5** — Substantial improvement with areas still needing work.

| Service | Responsibility | Lines | Rating |
|---------|---------------|-------|--------|
| `RecordingStateMachine` | FSM + session metadata | 209 | 5/5 |
| `AudioTransportService` | Audio I/O (mic, BLE, system) | 1048 | 3/5 (still bloated) |
| `TranscriptionPipeline` | Socket, segments, VAD, health | 881 | 4/5 |
| `PersistenceManager` | Draft, recovery, finalize | 727 | 4/5 |
| `AppLifecycleManager` | Background/foreground, notifications | 428 | 4/5 |
| `CaptureProvider` (coordinator) | Mediation between services | 1061 | 3/5 (still large) |

### What Improved
- Explicit FSM with validated state transitions
- Atomic recovery writes (temp file + rename)
- Mutex-protected finalization preventing race conditions
- Clean lifecycle isolation (background/foreground handling)
- Persistence logic isolated and independently testable
- CaptureLogService provides structured observability with circuit breaker

### What Needs Work
- `AudioTransportService` at 1048 lines is a mini-God-Class (phone mic + BLE + system audio + speaker verification + voice commands + photo streaming + metrics)
- Reconnection state duplicated between `AppLifecycleManager` and `TranscriptionPipeline`
- No dependency injection — all services hard-constructed, untestable in isolation
- `CaptureProvider` still at 1061 lines with 18 `notifyListeners()` call sites
- Callback wiring overhead in constructor (6 callbacks + 2 service inits)

---

## 2. All Findings by Severity

### CRITICAL (3 issues)

#### C1. Authentication Optional on ALL Recording Endpoints + IDOR
- **Files**: `api/routers/omi.py` — all endpoints use `optional_auth_user_id`
- **Problem**: Every recording endpoint (draft, segments, finalize, store, delete, starred, status, reprocess) uses optional auth. The `user_id` in the request body is trusted blindly without verification against the JWT.
- **Impact**: Any unauthenticated actor can create/modify/delete conversations for ANY user by providing their `user_id` (UUID) in the request body. Complete bypass of authorization.
- **Fix**: (1) Change `optional_auth_user_id` → `get_auth_user_id` on all mutation endpoints. (2) Derive `user_id` from JWT's `sub` (auth_id) server-side instead of trusting client-provided value.

#### C2. Status "abandoned" Not in DB CHECK Constraint
- **Files**: `api/routers/omi.py:812,1074,1082`, `lib/services/omi_supabase_service.dart:423`
- **Problem**: `markDraftAbandoned()` and `cleanup_orphan_drafts` send `status='abandoned'`, but the DB CHECK constraint `omi_conversations_valid_status` only allows: `recording`, `in_progress`, `processing`, `completed`, `failed`. PostgreSQL rejects the UPDATE.
- **Impact**: Orphan draft cleanup is COMPLETELY BROKEN. Drafts with `status='recording'` accumulate indefinitely. This explains the 10 orphan drafts found in the Feb 2026 DB audit.
- **Fix**: Change `markDraftAbandoned` to use `status='failed'` + `deleted=true` (consistent with manual cleanup already done in Feb 2026). Update backend `cleanup_orphan_drafts` endpoint similarly.

#### C3. Finalize Endpoint Not Idempotent — Duplicates Memories
- **Files**: `api/services/supabase_client.py:245-350`, `api/routers/omi.py:283-414`
- **Problem**: `finalize_conversation()` does not check the current status before processing. Re-finalizing an already-completed conversation overwrites structured data (title, overview, action_items) with potentially different results (OpenAI `temperature=0.7`) and creates DUPLICATE memories.
- **Impact**: Network timeout → client retry → duplicate memories, wasted OpenAI tokens, non-deterministic data.
- **Fix**: Check status at start of finalize: if already `completed`, return existing data. Or use conditional update: `.eq("status", "recording")`.

---

### HIGH (6 issues)

#### H1. Finalize Blocks Stop-Recording UI for 26-86+ Seconds
- **Files**: `lib/providers/capture_provider.dart:294-307,354-367,437-450,869-889,924-955`
- **Problem**: ALL 5 stop-recording code paths `await _finalizeLocalConversation()` BEFORE calling `updateRecordingState(RecordingState.stop)`. The finalize chain includes: flush segments (2-10s) + local OpenAI processing (2-8s) + backend finalize HTTP call (22-68s, 120s timeout). The UI stays in recording state during the entire duration.
- **Impact**: User presses stop → app appears frozen for 26-86+ seconds. Mic continues running. User may force-close, losing the finalize and falling back to recovery. With retry (3 attempts + backoff), theoretical max is ~270 seconds.
- **Fix**: (1) Transition to `RecordingState.processing` immediately. (2) Stop mic FIRST. (3) Run finalize fire-and-forget. (4) Show processing UI while finalize runs in background. (5) Transition to `stop` on completion.

#### H2. Audio Buffer Unbounded During BLE Recordings
- **Files**: `lib/services/recording/audio_transport_service.dart:315`
- **Problem**: `_audioBuffer` (WavBytesUtil) stores ALL audio frames for the entire BLE recording session for later speaker verification. No size limit. Growth rate: ~1.9 MB/min at 16kHz PCM16 mono.
- **Impact**: 30 min = ~57 MB, 60 min = ~115 MB. Risk of OOM crash on low-memory devices. OOM kill would lose the recording if recovery hasn't saved recently.
- **Fix**: Implement a rolling window buffer (keep last 5 minutes = ~9.6 MB max). Speaker verification only needs the longest segment per speaker, typically within the last few minutes.

#### H3. Backend Finalize is a God Function (22-68s, Timeout Risk)
- **Files**: `api/routers/omi.py:237-430`
- **Problem**: The finalize endpoint performs 7+ separate DB operations (finalize_conversation, chunked processing, embedding update, N+1 segment embedding updates, discard check, communication analysis, memory extraction) as independent requests with no transaction wrapper. Estimated 22-68s for a 50-segment conversation.
- **Impact**: Exceeds Vercel's serverless timeout (10s Hobby, 60s Pro). Partial failure leaves inconsistent state (conversation marked `completed` but missing embeddings/memories/feedback). N+1 segment embedding updates alone take ~10s for 100 segments.
- **Fix**: Decompose into staged pipeline with status progression: `recording → finalizing_transcript → generating_embeddings → analyzing → completed`. Each stage is idempotent and independently retryable. Flutter client only needs to know the conversation was accepted.

#### H4. Recovery Post-Crash Loses Up to 30s of Transcription
- **Files**: `lib/services/recording/persistence_manager.dart:549-566`
- **Problem**: When recovering from a crash, the recovery path calls `finalizeConversation()` directly on the existing draft without first re-uploading the gap segments. The recovery file has ALL segments (saved every 5s), but the backend only has segments saved up to the last incremental save (every 30s).
- **Scenario**: Recording 5 min. Segments saved to Supabase at t=4:30. Crash at t=4:55. Recovery file has segments 0-95, Supabase has segments 0-85. Recovered conversation has only 85 segments — last 25 seconds lost permanently.
- **Fix**: Re-append recovery file segments to the draft before calling finalize. The backend's `ON CONFLICT DO NOTHING` makes this safe for duplicate segments.

#### H5. Reprocess Creates Duplicate Memories
- **Files**: `api/routers/omi.py:919-954`
- **Problem**: The reprocess endpoint extracts and inserts new memories without deleting existing ones for the same `conversation_id`.
- **Impact**: Each reprocess adds 2-5 new memories. Users see duplicate insights. Search results have redundant entries.
- **Fix**: Soft-delete existing memories before re-extraction: `supabase...update({"deleted": True}).eq("conversation_id", conversation_id).execute()`.

#### H6. N+1 Queries in Segment Embedding Updates
- **Files**: `api/routers/omi.py:324-337`
- **Problem**: Each segment embedding is updated with an individual UPDATE query in a loop. 100 segments = 100 DB round-trips.
- **Impact**: ~10s latency during finalize for segment embeddings alone. Major contributor to the God Function timeout problem (H3).
- **Fix**: Use a batch RPC function `batch_update_segment_embeddings(segment_ids[], embeddings[])`.

---

### MEDIUM (10 issues)

| # | Issue | File(s) | Impact | Fix |
|---|-------|---------|--------|-----|
| M1 | `AudioTransportService` still bloated (1048 lines) — phone mic + BLE + system audio + speaker verification + voice commands + photos + metrics | `audio_transport_service.dart` | Maintenance burden, buffer bug lives here | Extract `BleTransportService` |
| M2 | Reconnection state duplicated between `AppLifecycleManager` and `TranscriptionPipeline` — resume reconnection sets wrong flag, causing parasitic keep-alive timer | `app_lifecycle_manager.dart:305`, `transcription_pipeline.dart:366` | Potential double reconnection on slow networks | Route through `_pipeline.reconnectAfterResume()` (already exists, correctly sets flag) |
| M3 | `_conversation` field never assigned — `assignSpeakerToConversation` is partially dead code (lines 598-623 unreachable) but still fires unnecessary `notifyListeners()` + person creation HTTP | `capture_provider.dart:201,582-631` | Unnecessary rebuilds + wasted HTTP calls | Wire up correctly or remove dead path |
| M4 | Shared mutable `segments` list — `trimSavedSegments()` mutates while async `scheduleIncrementalSave()` references it | `persistence_manager.dart:639`, `capture_provider.dart:807-819` | Potential `RangeError` in sublist after trim | Copy segments before async save, or use immutable list |
| M5 | CORS `allow_origins=["*"]` with `allow_credentials=True` | `api/index.py:34-40` | Any website can make authenticated API calls | Restrict to known app domains |
| M6 | Memory extraction truncates to 4000 chars — long conversations lose 80%+ of content for memory extraction | `api/services/memory_extractor.py:63-65` | Incomplete memory extraction | Use chunked extraction like `chunked_processor.py` |
| M7 | Conversation embedding update missing `user_id` filter | `api/routers/omi.py:313-315` | Unauthorized embedding modification (compounds C1) | Add `.eq("user_id", request.user_id)` |
| M8 | Supabase client is synchronous in async context — `async def` functions use sync supabase-py, blocking event loop | `api/services/supabase_client.py` | DB calls block event loop under load | Use supabase-py v2 async or `run_in_executor` |
| M9 | `append_segments` returns attempted count, not actual inserted count | `api/services/supabase_client.py:242` | Misleading segment count in API response | Return actual count from DB |
| M10 | Communication analyzer returns minimal feedback on timeout instead of None | `api/services/communication_analyzer.py:177-182` | "Conversacion muy breve" feedback stored for long conversations that timed out | Return None on timeout |

---

### LOW (9 issues)

| # | Issue | Notes |
|---|-------|-------|
| L1 | FSM `RecordingState.error` is dead code — defined in transition table but never transitioned to | All error paths go directly to `stop` |
| L2 | Dead recording timer in `AppLifecycleManager` (lines 400-420) — zero callers | Safe to delete immediately |
| L3 | Voice command watch timer can accumulate — no cancel of previous timer | Store reference, cancel before creating new |
| L4 | Recovery threshold mismatch — `RecoverySession` uses 5 words, `PersistenceManager` uses 20 words | Harmonize thresholds |
| L5 | `TranscriptRecoveryService.saveSegments()` uses non-atomic writes (legacy, not called in current code) | Delete or add atomic writes |
| L6 | No rate limiting on any endpoint | Add rate limiting middleware |
| L7 | No input length validation on text fields (Pydantic models) | Add `max_length` constraints |
| L8 | `datetime.utcnow()` deprecated in Python 3.12+ | Use `datetime.now(timezone.utc)` |
| L9 | `parse_json_from_llm` doesn't handle nested code blocks | Edge case, rare |

---

## 3. Performance Assessment

### Recent Fixes: FULLY RESOLVED
- **fe293d0** (frame drops 76-409): 800ms segment notification throttle works correctly. Max ~1.25 rebuilds/sec.
- **003f790** (FlutterJNI spam): Stop mic BEFORE recovery save in detach handler. Correct order.
- **de47995** (infinite spinner): Try-catch around WebSocket init + state reset on failure.

### Timers During Recording: Reasonable
7-8 timers active during typical recording. None at sub-second frequency. No redundancy found.

### Memory: Bounded (except BLE audio buffer)
- Segments capped at 200 in memory (trimming works correctly)
- VAD pre-roll buffer bounded (~6-15 KB)
- System audio buffer bounded at 160KB
- **Exception**: BLE `_audioBuffer` grows unbounded (H2)

### Hot Path Performance: Good
- <0.5ms per segment synchronous processing
- 800ms throttle prevents widget rebuilds
- 8-hop callback chain is purely synchronous function pointer calls — negligible overhead
- Recovery JSON encoding offloaded to background isolate (except during app pause/detach)

---

## 4. Reliability Assessment

### Multi-Layer Persistence: Strong
```
Memory (real-time) → Recovery File (5s) → Supabase (30s) → Finalize
```
- Atomic recovery writes (temp + rename)
- Mutex-protected finalization
- Monolithic fallback when incremental fails
- 3-minute background auto-finalize timer
- Orphan draft cleanup on app startup

### Key Gaps
- Recovery post-crash loses up to 30s (H4)
- Orphan cleanup broken (C2)
- Finalize non-idempotent (C3)
- Shared mutable segments list (M4)
- Reconnection state flag mismatch (M2)

### Risk Matrix

| Issue | Scenario | Impact | Likelihood | Severity |
|-------|----------|--------|------------|----------|
| C1 | Unauthenticated actor sends requests with victim's user_id | Full data manipulation | HIGH (trivially exploitable) | CRITICAL |
| C2 | Monolithic fallback calls markDraftAbandoned | Orphan drafts accumulate forever | HIGH (every monolithic fallback) | CRITICAL |
| C3 | Client retries finalize after timeout | Duplicate memories, inconsistent data | MEDIUM | CRITICAL |
| H1 | User stops recording, waits 26-86s | Perceived freeze, force-close risk | HIGH (every stop) | HIGH |
| H2 | 60-min BLE recording | ~115 MB memory growth, OOM risk | MEDIUM (long recordings) | HIGH |
| H4 | App crash, user recovers | Last 30s of transcript lost silently | LOW-MEDIUM | HIGH |
| M2 | Resume from background on slow network | Double reconnection, cascading loop | LOW-MEDIUM | MEDIUM |
| M4 | High-frequency segments + trim | RangeError in sublist | LOW | MEDIUM |

---

## 5. Security Assessment

| Check | Status | Details |
|-------|--------|---------|
| Authentication on endpoints | FAIL | All recording endpoints use optional auth |
| Authorization (user owns resource) | FAIL | user_id trusted from request body (IDOR) |
| Input sanitization | PARTIAL | Pydantic validates types, no length limits |
| SQL injection prevention | PASS | Supabase client uses parameterized queries |
| Rate limiting | FAIL | None |
| CORS | WEAK | allow_origins=* with allow_credentials=True |

---

## 6. Recommended Action Plan

### Phase 1: Critical Fixes (immediate, 1-2 days)
1. **C2**: Change `markDraftAbandoned` → `status='failed'` + `deleted=true` (1 line Flutter + 1 line backend)
2. **C1**: Enforce auth on mutation endpoints + derive user_id from JWT server-side
3. **C3**: Add idempotency guard: `if status == 'completed': return existing_data`
4. **L2**: Delete dead recording timer from AppLifecycleManager (trivial, zero risk)

### Phase 2: High Fixes (next week)
5. **H1**: Decouple finalize from stop-recording UI — add `RecordingState.processing`, stop mic first, fire-and-forget finalize
6. **H4**: Re-append recovery segments to draft before calling finalize
7. **H2**: Implement rolling window on BLE audio buffer (cap 5 min)
8. **H5**: Soft-delete existing memories before reprocess extraction
9. **H6**: Batch RPC for segment embedding updates

### Phase 3: Architecture Refactoring (next sprint)
10. **H3**: Decompose backend finalize into staged pipeline with status progression
11. **M1**: Extract `BleTransportService` from `AudioTransportService`
12. **M2**: Route resume reconnection through `_pipeline.reconnectAfterResume()` (already exists)
13. **M3**: Clean up dead speaker assignment code (`_conversation` never assigned)
14. **M4**: Copy segments before async save operations

### Phase 4: Hardening (ongoing)
15. **M5**: Restrict CORS origins
16. **M6**: Chunked memory extraction for long transcripts
17. **M7**: Add user_id filter to embedding update
18. **L6**: Add rate limiting
19. **L7**: Add input length validation
20. Add dependency injection for testability (at least PersistenceManager)
21. Selector-based UI rebuilds to reduce unnecessary widget tree work

---

## 7. Backend Finalize Decomposition (Proposed Architecture for H3)

```
Current: recording ──────────────────────────────────> completed (22-68s, single HTTP call)

Proposed: recording → finalizing_transcript → generating_embeddings → analyzing → completed
             │              │                        │                   │
         Client calls    ~1s (DB only)            ~3s (OpenAI)      ~15-30s (OpenAI)
         finalize,       Rebuild transcript,      Conv + segment     Discard check,
         gets quick      set finished_at          embeddings         comm analysis,
         200 response                             (batch)            memory extraction
```

**Flutter impact**: Client calls finalize, gets quick acknowledgment (<1s). Backend processes async. Client polls or receives webhook when complete. Eliminates the 26-86s UI block entirely.

**DB CHECK constraint update needed**: Add `finalizing_transcript`, `generating_embeddings`, `analyzing` to the valid status list. Or use a simpler two-stage: `recording → processing → completed`.
