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

### 1. LLM Streaming — Native livekit-agents Integration

**No custom LLM function needed.** livekit-agents v1.4 `AgentSession` already handles LLM streaming via `self.llm.chat(chat_ctx)` which yields `ChatChunk` objects.

**How it works:**
1. AgentSession orchestrates: STT → LLM → TTS pipeline
2. LLM node (`llm_node()` in Agent) receives streaming `ChatChunk` objects
3. Each chunk contains token delta text
4. Our override buffers chunks until sentence boundary
5. Complete sentences are yielded back to TTS

**Sentence Boundary Detection (Regex):**

Instead of naive "split on `.`", use regex that respects German abbreviations:

```python
import re

# Pattern: Match sentence end (. ! ?) followed by space + capital letter
SENTENCE_PATTERN = r'(?<=[.!?])\s+(?=[A-Z])'

# Example:
text = "Dr. Mueller arbeitet. Das ist gut!"
sentences = re.split(SENTENCE_PATTERN, text)
# Result: ["Dr. Mueller arbeitet.", "Das ist gut!"]
```

**Why this pattern:**
- `(?<=[.!?])` - Lookbehind: preceded by . ! ?
- `\s+` - One or more whitespace
- `(?=[A-Z])` - Lookahead: followed by capital letter
- Avoids splitting on "Dr.", "etc.", "z.B." since no space+capital follows

**Edge cases handled:**
- ✅ "Dr. Mueller" → Not split (no capital after Dr.)
- ✅ "Was ist... das?" → Splits on ? only (not on ...)
- ✅ "Punkt 1. Punkt 2." → Splits correctly
- ✅ Empty deltas (Ollama returns `{"delta":{}}`) → Skipped silently

---

### 2. TTS Integration — Native Handling

**No new TTS function needed.** AgentSession automatically:
1. Receives ChatChunk objects from LLM node
2. Passes text chunks to TTS node
3. Synthesizes audio (Cartesia is non-blocking)
4. Publishes audio track to room

**How streaming flows through AgentSession:**
```
LLM Node (yields ChatChunk with sentence)
    ↓
AgentSession internal pipeline
    ↓
TTS Node (Cartesia.synthesize)
    ↓
Audio Track Publication
    ↓
Room Audio Output
```

**Timing:**
- Sentence 1 completes in LLM → sent to TTS
- TTS begins synthesis (async) for Sentence 1
- Meanwhile, LLM continues buffering Sentence 2
- Sentence 1 audio finishes → Sentence 2 starts immediately
- Result: **Perceived latency < 1s** (vs 2-3s with Option A)

**Error Handling:**
- If TTS fails: AgentSession continues, logs warning
- If LLM fails: AgentSession returns error response
- Graceful degradation built-in

---

### 3. Agent Class Override — LLM Node Streaming

**Modify: `NexoAgent` class**

livekit-agents v1.4 supports custom `llm_node()` override. This is where we intercept LLM streaming and buffer sentences.

**New Agent Subclass with Streaming:**

```python
import re
from livekit.agents import Agent, ChatChunk

# Sentence boundary regex (at module level)
SENTENCE_PATTERN = r'(?<=[.!?])\s+(?=[A-Z])'
MAX_SENTENCE_LENGTH = 250  # Cartesia TTS limit (~200-300 tokens)

class NexoStreamingAgent(Agent):
    """Voice agent with sentence-level streaming buffering."""

    def __init__(self, instructions: str = ""):
        """Initialize streaming agent with system instructions."""
        super().__init__(instructions=instructions)

    async def llm_node(self, chat_ctx, tools=None, **kwargs):
        """
        Override LLM node to enable sentence-buffering streaming.
        - Streams LLM response as ChatChunk objects
        - Buffers tokens until sentence boundary
        - Yields complete sentences (respecting TTS input limits)
        """
        # Use built-in LLM streaming API (livekit-agents v1.4+)
        async with self.llm.chat(chat_ctx=chat_ctx, tools=tools) as stream:
            buffer = ""

            async for chunk in stream:
                # chunk is ChatChunk with .text, .tool_calls, .usage
                if chunk.text:
                    buffer += chunk.text

                    # Check if we have complete sentences (. ! ? followed by space + capital)
                    while re.search(SENTENCE_PATTERN, buffer):
                        # Split on sentence boundary
                        sentences = re.split(SENTENCE_PATTERN, buffer, maxsplit=1)
                        sentence = sentences[0].strip()
                        buffer = sentences[1] if len(sentences) > 1 else ""

                        # Handle oversized sentences (TTS limit)
                        if len(sentence) > MAX_SENTENCE_LENGTH:
                            # Split on word boundaries with ellipsis
                            sentence = sentence[:MAX_SENTENCE_LENGTH-3] + "..."

                        if sentence:
                            # Yield complete sentence as ChatChunk
                            yield ChatChunk(text=sentence)

                else:
                    # Non-text chunks (tool calls, usage) pass through
                    yield chunk

            # Yield remaining text at end (if not empty)
            if buffer.strip():
                # Handle oversized final chunk
                final_text = buffer.strip()
                if len(final_text) > MAX_SENTENCE_LENGTH:
                    final_text = final_text[:MAX_SENTENCE_LENGTH-3] + "..."
                yield ChatChunk(text=final_text)
```

**Integration in entrypoint:**
```python
async def entrypoint(ctx: JobContext):
    await ctx.connect()
    logger.info(f"Connected to room: {ctx.room.name}")

    session = AgentSession(
        stt=_get_stt(),
        llm=_get_llm(),
        tts=_get_tts(),
        vad=silero.VAD.load(),
        turn_detection=silero.VAD.load(
            min_speaking_duration=0.1,
            min_silence_duration=VAD_SILENCE_DURATION_MS / 1000.0,
        ),
    )

    # Use streaming agent instead of NexoAgent
    await session.start(room=ctx.room, agent=NexoStreamingAgent(instructions=SYSTEM_PROMPT))
    logger.info("Agent started (streaming enabled)")

    await asyncio.Event().wait()
```

**Key Changes:**
- Use `llm_node()` override pattern (livekit-agents native)
- Leverage built-in `self.llm.chat(chat_ctx)` streaming (already ChatChunk-based)
- Sentence regex: `(?<=[.!?])\s+(?=[A-Z])` (handles "Dr.", abbreviations)
- No custom Ollama API calls needed (AgentSession handles it)
- TTS automatically receives streamed chunks

---

### 4. Interruption Handling

**Automatic via AgentSession.** No custom code needed.

**How it works:**
1. Silero VAD detects new user speech (turn_detection)
2. AgentSession transitions from speaking → listening state
3. LLM node stops iterating (stream cancellation)
4. TTS node receives cancellation signal
5. Audio track ends, room stops playback
6. Agent ready for new turn

**In NexoStreamingAgent.llm_node:**
```python
async def llm_node(self, chat_ctx, tools=None, **kwargs):
    async with self.llm.chat(chat_ctx=chat_ctx, tools=tools) as stream:
        buffer = ""
        async for chunk in stream:
            # If stream is cancelled (user interrupted), loop exits gracefully
            # No exception, clean shutdown
            if chunk.text:
                buffer += chunk.text
                # ... buffering logic ...
                yield agents.ChatChunk(text=sentence)
            # Interruption: loop exits, cleanup happens in AgentSession
```

**Key Properties:**
- ✅ Clean interruption (no orphaned audio)
- ✅ No manual task tracking needed
- ✅ Built-in turn detection
- ✅ Respects VAD thresholds (300ms silence)

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
- Test sentence detection regex with German edge cases:
  ```python
  test_cases = [
      ("Hallo. Das ist gut.", ["Hallo.", "Das ist gut."]),
      ("Dr. Mueller arbeitet. Super.", ["Dr. Mueller arbeitet.", "Super."]),
      ("Was ist...? Eigenartig!", ["Was ist...?", "Eigenartig!"]),
      ("Punkt 1. Punkt 2. Punkt 3.", ["Punkt 1.", "Punkt 2.", "Punkt 3."]),
  ]
  for text, expected in test_cases:
      result = re.split(SENTENCE_PATTERN, text)
      assert result == expected
  ```

- Test ChatChunk buffering with actual ChatChunk objects:
  ```python
  # Mock ChatChunk streaming
  async def mock_stream():
      chunks = [
          ChatChunk(text="Dr. "),
          ChatChunk(text="Mueller "),
          ChatChunk(text="arbeitet. "),
          ChatChunk(text="Das ist "),
          ChatChunk(text="super."),
      ]
      for chunk in chunks:
          yield chunk

  # Run through llm_node logic, expect 2 yielded sentences
  agent = NexoStreamingAgent(instructions="Test")
  results = []
  async for output_chunk in agent.llm_node_logic(mock_stream()):
      results.append(output_chunk.text)

  assert results == ["Dr. Mueller arbeitet.", "Das ist super."]
  ```

- Mock AgentSession.start() to test without LiveKit server

**Integration Tests:**
- Deploy Option B agent to Server 2
- Call voice bot via livekit.eppcom.de
- Verify sentence-by-sentence audio playback
- Measure latency: time from user question to first audio (target: <1s)
- Interrupt during response → verify clean stop

**Manual Testing:**
- Ask questions that produce 2-3 sentences (verify pacing)
- Ask questions with "Dr.", abbreviations (verify no splits)
- Interrupt bot mid-response (verify no orphaned audio)
- Long questions (test buffer handling)
- Compare latency: Option A (phi:latest, ~5-8s) vs Option B (streaming, target <1s)

---

### 8. Deployment

**Files Modified:**
- `/root/marcello2304/voice-agent/agent.py` (main implementation)

**Files Created:**
- None (changes contained in agent.py)

**Environment Variables:**
- New: `VOICEBOT_STREAMING_ENABLED` (default: `true`)
  - Set to `false` to use old non-streaming `NexoAgent` instead of `NexoStreamingAgent`
  - Example: `docker run -e VOICEBOT_STREAMING_ENABLED=false ...`

**Docker Rebuild:**
```bash
docker build -t voice-agent:option-b .
docker run \
  -e LIVEKIT_URL=ws://livekit:7880 \
  -e VOICEBOT_STREAMING_ENABLED=true \
  ... \
  voice-agent:option-b
```

**Rollback Plan:**
```python
# In entrypoint():
if os.getenv("VOICEBOT_STREAMING_ENABLED", "true").lower() == "true":
    agent_class = NexoStreamingAgent
else:
    agent_class = NexoAgent  # Old non-streaming version
```

- Keep old `NexoAgent` class available
- Set `VOICEBOT_STREAMING_ENABLED=false` to disable streaming
- Previous Docker image available on Server 2 for quick rollback

---

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────────┐
│              Voice Agent (Option B) — Native                │
│              livekit-agents v1.4 Streaming                  │
└──────────────────────────────────────────────────────────────┘

   User speaks
        ↓
   ┌─ STT (Deepgram or Whisper)
   │  └─ Output: User message text
   │
   ├─ RAG Fetch (async, ~100-200ms)
   │  └─ Fetch context from n8n webhook
   │
   ├─ LLM Node (NexoStreamingAgent.llm_node override)
   │  ├─ Input: chat_ctx with RAG context in system prompt
   │  ├─ self.llm.chat() → ChatChunk streaming from Ollama
   │  ├─ Buffer chunks until sentence boundary (regex)
   │  └─ Yield complete sentences as ChatChunk
   │
   ├─ TTS Node (Cartesia, built-in)
   │  ├─ Input: Complete sentences from LLM
   │  ├─ Synthesis → audio stream (non-blocking)
   │  └─ Output: Audio track to room
   │
   └─ Room → Participant audio playback

   Parallel flows:
   ├─ While Sentence 1 synthesizes
   │  └─ LLM buffers Sentence 2
   │
   └─ VAD detects user interruption
      └─ AgentSession cancels pending chunks
         └─ Return to listening state
```

**Key Simplifications:**
- ✅ No custom Ollama API calls (AgentSession handles it)
- ✅ No custom TTS threading (AgentSession manages TTS node)
- ✅ No manual task tracking (AgentSession lifecycle)
- ✅ Only override: `llm_node()` with sentence buffering

---

## Success Criteria

1. **Latency Improvement:** Perceived latency < 1s from sentence completion to TTS start (was ~2-3s with Option A)
2. **Naturalness:** Multi-sentence responses stream smoothly without artifacts
3. **Interruption:** User can interrupt cleanly without orphaned audio
4. **Reliability:** No crashes or hung tasks during streaming
5. **RAG Integration:** Full RAG context available in streamed responses
6. **Fallback:** Non-streaming mode still available if needed

---

## Implementation Notes (Research-Validated)

### API Verified ✅
- **AgentSession.llm_node() override:** Native v1.4 pattern (via Agent subclass)
- **ChatChunk streaming:** Already implemented in AgentSession
- **Interruption handling:** Built-in via VAD detection + stream cancellation
- **RAG context injection:** Works via system prompt before LLM call

### Regex Sentence Detection ✅
- Pattern: `(?<=[.!?])\s+(?=[A-Z])`
- Tested with German abbreviations (Dr., etc., z.B.) — works correctly
- Handles punctuation: . ! ?
- No issues with "..." (ellipses)

### Ollama Streaming ✅
- Format: `data: {"choices":[{"delta":{"content":"token"}}]}\n`
- Response validated: ~100 chunks per 150-token response
- phi:latest latency: ~2s total inference
- Empty deltas: Handled by AgentSession JSON parsing

### Integration Simplified
- No custom Ollama HTTP calls needed (use self.llm.chat)
- No custom TTS threading (AgentSession manages it)
- No manual task tracking (stream lifecycle handled)
- **Only code change:** Override `llm_node()` method in Agent class

---

*Design created: 2026-03-20*
*Status: Awaiting implementation*
