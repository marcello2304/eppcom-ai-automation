# Voicebot Option B: Token-Streaming Implementation Design

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable real-time token streaming for voice agent LLM responses, reducing perceived latency by allowing TTS to begin synthesis while tokens are still being generated.

**Architecture:** Modify Ollama API integration to use streaming endpoints (`"stream": True`), implement sentence-level buffering (buffer tokens until sentence-end `.`), and send complete sentences directly to TTS while simultaneously buffering the next sentence. RAG context is injected before streaming begins. Interruption handling clears buffered sentences and cancels pending TTS tasks.

**Tech Stack:** livekit-agents v1.4, Ollama (OpenAI-compatible streaming API), Cartesia TTS (direct audio synthesis), Silero VAD (interruption detection), httpx (async HTTP streaming).

---

## Current State

**Voice Agent Status:**
- Location: `/root/marcello2304/voice-agent/`
- LLM: Ollama phi:latest (3B params, ~2s inference)
- TTS: Cartesia AI Sonic-2 (German voice)
- STT: Deepgram nova-2 or OpenAI Whisper fallback
- VAD: Silero (300ms silence threshold)
- Current Flow: STT → (non-streaming) get_llm_response() → Full response awaited → TTS → Room output
- Problem: Full LLM response must complete before TTS begins (adds 2-3s perceived latency)

**Option B Target:** Streaming LLM responses sentence-by-sentence to TTS in parallel.

---

## Design Sections

### 1. LLM Streaming Function

**New Function: `stream_llm_response(user_message, rag_context=None)`**

Replaces `get_llm_response()`. Returns async generator yielding complete sentences.

**Key Changes:**
- Enable Ollama streaming: `"stream": True` in request JSON
- Parse Server-Sent Events (SSE) format: `data: {"choices":[{"delta":{"content":"token"}}]}`
- Buffer tokens until sentence-end marker (`.`)
- Yield complete sentence when detected
- Inject RAG context before streaming (same as before)

**Pseudocode:**
```python
async def stream_llm_response(user_message: str, rag_context: Optional[str] = None):
    system_prompt = SYSTEM_PROMPT
    if rag_context:
        system_prompt += f"\n\nKontext:\n{rag_context}"

    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.post(
            f"{OLLAMA_BASE_URL}/v1/chat/completions",
            json={
                "model": OLLAMA_MODEL,
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_message},
                ],
                "stream": True,  # ← ENABLE STREAMING
                "temperature": 0.7,
                "max_tokens": 150,
            },
        )

        buffer = ""
        async for line in response.aiter_lines():
            if not line:
                continue
            if line.startswith("data: "):
                chunk = json.loads(line[6:])
                token = chunk["choices"][0]["delta"].get("content", "")
                buffer += token

                if "." in buffer:
                    sentence, buffer = buffer.split(".", 1)
                    yield sentence.strip() + "."

        if buffer.strip():
            yield buffer.strip()
```

**Handling:**
- Timeout: 10s (increased from 5s to allow full response streaming)
- Error: Yield fallback message ("Entschuldigung, ich konnte die Anfrage nicht verarbeiten.")
- Empty chunks: Skip silently

---

### 2. TTS Integration — Direct Sentence Streaming

**New Function: `send_to_tts_direct(sentence, room, tts_instance)`**

Sends synthesized audio directly to LiveKit room immediately upon sentence completion.

**Flow:**
1. Sentence from `stream_llm_response()` arrives
2. Pass to Cartesia TTS synchronously (non-blocking)
3. Cartesia returns audio stream (PCM 24kHz)
4. Publish audio track to room
5. Room delivers to participant in real-time

**Key Properties:**
- Non-blocking: TTS synthesis runs in background
- Parallel: While Sentence N plays, Sentence N+1 buffers
- Cancellable: If interruption detected, pending tracks cancelled

**Pseudocode:**
```python
async def send_to_tts_direct(sentence: str, room: rtc.Room):
    try:
        tts = _get_tts()
        audio_stream = await tts.synthesize(sentence)

        track = rtc.LocalAudioTrack.create_audio_track(
            source=audio_stream,
            sample_rate=24000,
        )
        await room.local_participant.publish_track(track)
        logger.info(f"Audio track published: {len(sentence)} chars")
    except Exception as e:
        logger.error(f"TTS failed: {e}")
```

---

### 3. Agent Entrypoint — Custom Message Callback

**Modify: `entrypoint(ctx: JobContext)`**

Current `AgentSession` uses default LLM completion. We override with custom callback.

**New Callback: `on_user_message_callback(user_message, ctx)`**

```python
async def on_user_message_callback(user_message: str, ctx: JobContext):
    """Custom streaming callback for LLM + TTS."""
    try:
        # Fetch RAG context (non-blocking)
        rag_context = await fetch_rag_context(user_message)

        # Stream sentences
        async for sentence in stream_llm_response(user_message, rag_context):
            logger.info(f"Streaming sentence: {sentence[:60]}...")

            # Send directly to TTS (non-blocking)
            await send_to_tts_direct(sentence, ctx.room)

    except Exception as e:
        logger.error(f"Streaming callback failed: {e}")
```

**Integration in entrypoint:**
```python
async def entrypoint(ctx: JobContext):
    await ctx.connect()
    logger.info(f"Connected to room: {ctx.room.name}")

    session = AgentSession(
        stt=_get_stt(),
        llm=_get_llm(),  # Keep for compatibility
        tts=_get_tts(),
        vad=silero.VAD.load(),
        turn_detection=silero.VAD.load(
            min_speaking_duration=0.1,
            min_silence_duration=VAD_SILENCE_DURATION_MS / 1000.0,
        ),
    )

    # Override LLM callback with streaming version
    session.on_message = on_user_message_callback

    await session.start(room=ctx.room, agent=NexoAgent())
    logger.info("Agent started (streaming enabled)")

    await asyncio.Event().wait()
```

---

### 4. Interruption Handling

**Requirement:** When user speaks during TTS playback, buffered sentences must be cleared and pending TTS tasks cancelled.

**Detection:** Silero VAD (`turn_detection`) detects new user speech.

**Handling:**
```python
pending_tts_tasks = []

async def clear_buffer_on_interruption():
    """Clear buffered sentences when user interrupts."""
    global pending_tts_tasks

    # Cancel all pending TTS tasks
    for task in pending_tts_tasks:
        if not task.done():
            task.cancel()

    pending_tts_tasks.clear()
    logger.info("Interruption: Buffer cleared, TTS cancelled")

# Register with VAD or session interrupt handler
session.on_interruption = clear_buffer_on_interruption
```

**Implementation Note:** Depends on livekit-agents API for interrupt callbacks. If not available, use task cancellation token passed to `send_to_tts_direct()`.

---

### 5. RAG Integration

**No changes to RAG fetching:**
- `fetch_rag_context(query)` remains unchanged
- Context injected into system prompt before streaming begins
- Streaming happens with full RAG context available

**Flow:**
```
User: "Was sind eure Services?"
  ↓
RAG fetch: rag_context = "Services: Chatbot, Voicebot, RAG..."
  ↓
System prompt: SYSTEM_PROMPT + "\n\nKontext:\n{rag_context}"
  ↓
Stream LLM with enriched system prompt
```

---

### 6. Error Handling & Fallbacks

**Streaming Failures:**
1. **Ollama streaming timeout (>10s):** Yield fallback message, stop streaming
2. **TTS synthesis failure:** Log error, continue (don't block next sentence)
3. **Network interruption:** Graceful degradation (partial response)

**Graceful Degradation:**
- If streaming fails, fall back to non-streaming `get_llm_response()` (keep old function available)
- Log incident for debugging

---

### 7. Testing Strategy

**Unit Tests:**
- Test `stream_llm_response()` with mock Ollama streaming API
- Verify sentence boundary detection (`.`)
- Verify RAG context injection
- Verify buffer clearing on interruption

**Integration Tests:**
- Test full flow: STT → RAG → Streaming LLM → TTS → Room audio
- Simulate interruption mid-sentence
- Simulate network failures
- Measure latency: time from sentence completion to TTS playback

**Manual Testing:**
- Call voice bot and listen for natural sentence-by-sentence streaming
- Interrupt during response, verify no stray audio
- Long responses (>3 sentences) maintain timing
- German pronunciation natural with sentence context

---

### 8. Deployment

**Files Modified:**
- `/root/marcello2304/voice-agent/agent.py` (main implementation)

**Files Created:**
- None (changes contained in agent.py)

**Environment Variables:**
- No new env vars required (uses existing OLLAMA_BASE_URL, CARTESIA_API_KEY, etc.)

**Docker Rebuild:**
```bash
docker build -t voice-agent:option-b .
docker run -e LIVEKIT_URL=ws://livekit:7880 ... voice-agent:option-b
```

**Rollback Plan:**
- Keep old `get_llm_response()` function as fallback
- Can disable streaming by setting ENV var or commenting callback override
- Previous Docker image available on Server 2

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    Voice Agent (Option B)                   │
└─────────────────────────────────────────────────────────────┘

   User speaks
        ↓
   STT (Deepgram)
        ↓
   User message text
        ↓
   RAG Fetch (n8n webhook, ~100-200ms)
        ↓
   stream_llm_response()    ← NEW: Streaming generator
   ├─ Inject RAG context
   ├─ POST to Ollama with "stream": True
   ├─ Parse SSE chunks
   ├─ Buffer tokens until "."
   └─ Yield sentence
        ↓
   send_to_tts_direct()     ← NEW: Direct TTS
   ├─ Cartesia synthesis (non-blocking)
   ├─ Publish audio track to room
   └─ Continue while next sentence buffers
        ↓
   Room → Participant audio playback

   ┌─ VAD detects user interruption
   │
   → clear_buffer_on_interruption()
     ├─ Cancel pending TTS tasks
     ├─ Clear buffered sentences
     └─ Return to listening
```

---

## Success Criteria

1. **Latency Improvement:** Perceived latency < 1s from sentence completion to TTS start (was ~2-3s with Option A)
2. **Naturalness:** Multi-sentence responses stream smoothly without artifacts
3. **Interruption:** User can interrupt cleanly without orphaned audio
4. **Reliability:** No crashes or hung tasks during streaming
5. **RAG Integration:** Full RAG context available in streamed responses
6. **Fallback:** Non-streaming mode still available if needed

---

## Open Questions for Implementation

1. Does livekit-agents v1.4 provide native interrupt callback, or do we need to poll VAD directly?
2. Should we buffer entire responses in memory, or stream directly to disk for very long responses?
3. Cartesia TTS latency for synthesis — is it truly non-blocking, or should we pre-synthesize while LLM generates next sentence?

---

*Design created: 2026-03-20*
*Status: Awaiting implementation*
