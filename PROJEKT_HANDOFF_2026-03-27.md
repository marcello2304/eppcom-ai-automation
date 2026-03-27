# EPPCOM Solutions – Projekt-Handoff für LLM-Session
**Erstellt: 27. März 2026**
**Zweck: Vollständiger Kontext für eine neue LLM-Session (Claude, GPT-4, Gemini etc.)**

---

## Wer bin ich?

**Marcel Eppler**, Inhaber von **EPPCOM Solutions** in Reutlingen.
Ich baue eine selbst gehostete, DSGVO-konforme KI-Automatisierungsplattform auf Hetzner-Servern in Deutschland.

---

## Was wurde gebaut? (Aktueller Stand 27.03.2026)

### ✅ Vollständig in Betrieb

| Komponente | Status | URL / Endpoint |
|---|---|---|
| **Coolify** (Deployment-Plattform) | ✅ healthy | intern |
| **PostgreSQL + pgvector** (RAG-DB) | ✅ healthy | postgres-rag Container |
| **n8n** (Workflows) | ✅ aktiv | workflows.eppcom.de |
| **Typebot** (Chat-UI) | ✅ live | bot.eppcom.de/eppcom-chatbot-v2 |
| **RAG Admin UI** (FastAPI) | ✅ running | appdb.eppcom.de |
| **code-server** (VS Code Browser) | ✅ running | code.eppcom.de |
| **LiveKit Server** (WebRTC) | ✅ running | livekit.eppcom.de |
| **Voice Agent "Nexo"** | ✅ running | Docker: voice-agent |
| **Ollama** (LLM) | ✅ running | Server 2, Port 11434 |
| **RAG-Daten (Tenant EPPCOM)** | ✅ vorhanden | 3 Docs, 7 Chunks, 7 Embeddings |

### ⚠️ Teilweise/In Arbeit

| Komponente | Status | Problem |
|---|---|---|
| **Typebot ↔ RAG** | ⚠️ NICHT verbunden | HTTP-Request-Block fehlt noch |
| **n8n Ingestion E2E** | ⚠️ Auth-Fix nötig | IF-Node-Condition nach Import leer |
| **Production Webhooks** | ⚠️ 404 | Test-Webhooks (`/webhook-test/`) funktionieren |
| **Voicebot Option B** | ⚠️ Task 4-6 offen | Streaming implementiert, noch nicht deployed |

---

## Infrastruktur

### Server 1 – Haupt-Stack (94.130.170.167, Hetzner CX23)

**Alle Docker-Container:**
```
coolify + coolify-sentinel + coolify-realtime + coolify-db + coolify-redis + coolify-proxy
postgres-rag            – PostgreSQL 16 + pgvector (appdb)
postgres-zoc8g4socc...  – PostgreSQL für Typebot/n8n
n8n                     – Workflows
typebot-builder         – admin-bot.eppcom.de
typebot-viewer          – bot.eppcom.de
code-server             – code.eppcom.de
eppcom-admin-ui         – appdb.eppcom.de (FastAPI RAG Admin)
voice-agent             – LiveKit Voice Agent (Python)
livekit-token-server    – Token-API
livekit-wss-proxy       – WebSocket-Proxy
livekit-db              – PostgreSQL für LiveKit
jitsi-meet-web/prosody/jicofo/jvb  – Jitsi Stack
```

**Git Repo auf Server 1:** `~/projects/eppcom-ai-automation`
**Voice-Agent Code:** `/root/marcello2304/voice-agent/agent.py`

### Server 2 – LLM & Voice (46.224.54.65 extern / 10.0.0.3 intern)
```
ollama          – Port 11434 (0.0.0.0)
livekit-server  – Port 7880 → livekit.eppcom.de
livekit-db      – Port 5433
```

---

## Datenbank-Details (appdb)

**Verbindung via docker exec:**
```bash
docker exec -e PGPASSWORD="$(docker exec postgres-zoc8g4socc0ww80w4s080g4s env | grep POSTGRES_PASSWORD | cut -d= -f2-)" postgres-zoc8g4socc0ww80w4s080g4s psql -h localhost -U appuser -d appdb -c "SQL;"
```

**Tabellen:** tenants, api_keys, sources, documents, chunks, embeddings (+ 3 weitere)

**Schema-Besonderheiten:**
- `documents.content_text` (NICHT `content`)
- `documents.word_count` (NICHT `char_count`)
- `api_keys.name` (NICHT `label`)
- `embeddings.document_id` – REQUIRED (FK zu documents)
- RLS aktiv – `appuser` als Owner umgeht RLS

**Auth-Query:**
```sql
SELECT t.id, t.slug, t.name
FROM api_keys ak JOIN tenants t ON t.id = ak.tenant_id
WHERE ak.key_hash = encode(sha256(('eppcom-test-key-2026'::text)::bytea), 'hex')
  AND ak.is_active = true AND t.is_active = true;
```

**Test-Tenant:**
- ID: `a0000000-0000-0000-0000-000000000001`
- Slug: `test-kunde` / `eppcom`
- API-Key: `eppcom-test-key-2026`

---

## n8n Webhooks (Referenz)

```bash
# RAG Chat testen (FUNKTIONIERT via Test-Webhook)
curl -X POST https://workflows.eppcom.de/webhook-test/rag-chat \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: a0000000-0000-0000-0000-000000000001" \
  -H "X-API-Key: eppcom-test-key-2026" \
  -d '{"query": "Was ist EPPCOM?"}'

# Ingestion testen
curl -X POST https://workflows.eppcom.de/webhook-test/ingest \
  -H "Content-Type: application/json" \
  -H "X-API-Key: eppcom-test-key-2026" \
  -d '{"source_name":"Test","doc_title":"Test","doc_type":"text","chunks":["chunk 1","chunk 2"]}'
```

**Bekannte n8n-Probleme:**
1. **Production `/webhook/` → 404** → immer `/webhook-test/` verwenden
2. **IF-Node Conditions nach Import leer** → manuell setzen: `{{ $json.tenant_id }}` → String → "is not empty"
3. **SHA256 im n8n-Code nicht verfügbar** → immer via PostgreSQL: `encode(sha256(('key'::text)::bytea), 'hex')`
4. **HTTP Request Node JSON** → `={{ JSON.stringify({...}) }}`

---

## Voice Agent "Nexo" – Detailinfo

**Datei:** `/root/marcello2304/voice-agent/agent.py`

**Pipeline:**
```
User Speech
  → Local Whisper STT (small, self-hosted, gratis)
    → NexoStreamingAgent.llm_node()
      → RAG Context fetch (n8n webhook, optional, 8s timeout)
        → Ollama LLM (qwen2.5:7b-eppcom via OpenAI-kompatibles API)
          → Satzweise Ausgabe (Regex: (?<=[.!?])\s+(?=[A-Z]))
            → Cartesia Sonic-2 TTS (<100ms)
              → User hört Antwort
```

**Zwei Agent-Klassen:**
- `NexoAgent` – Basis, kein Streaming
- `NexoStreamingAgent` – Token-Streaming mit Satz-Buffering (Standard)

**Env Var `VOICEBOT_STREAMING_ENABLED=true`** → wählt NexoStreamingAgent

**Fallback-Ketten:**
- STT: Local Whisper → Deepgram → OpenAI Whisper
- TTS: Cartesia Sonic-2 → OpenAI TTS-1
- LLM: Immer Ollama (kein Fallback)

---

## Offene Tasks (Priorität)

### 1. Voicebot Option B – Deployment (DRINGEND)
**Was:** NexoStreamingAgent auf Server 2 deployen und testen
**Status:** Tasks 1-3 done (Code implementiert, Tests passing), Task 4-6 offen

```
Task 4: Local Testing – NexoStreamingAgent lokal ausführen, Satz-Buffering verifizieren
Task 5: Deploy – Docker Image neu bauen, auf Server 1 deployen
Task 6: Performance Validation – Latenz messen, Ziel: <3s End-to-End
```

**Code-Ort:** `/root/marcello2304/voice-agent/agent.py`
**Deploy-Befehl (Server 1):**
```bash
cd /root/marcello2304/voice-agent
docker build -t eppcom/voice-agent:latest .
docker stop voice-agent && docker rm voice-agent
# Dann mit gleichen Env-Vars neu starten
```

### 2. Typebot → RAG Webhook verbinden
**Was:** Im Typebot-Flow `eppcom-chatbot-v2` einen HTTP-Request-Block einbauen
**Ziel:** Bei freier Texteingabe des Users → n8n RAG Chat Webhook aufrufen
**Webhook-URL:** `https://workflows.eppcom.de/webhook-test/rag-chat`
**Body:** `{"query": "{{user_input}}"}`
**Headers:** `X-Tenant-ID`, `X-API-Key`
**Flow:** user_input → HTTP Request → Antwort aus `answer`-Feld → Typebot zeigt Antwort

### 3. n8n Ingestion Workflow – E2E-Test
**Was:** IF-Node "Auth OK?" Condition verifizieren und End-to-End-Test durchlaufen
**Problem:** Nach Import ist die Condition leer → manuell setzen
**Test:**
```bash
# Terminal 1: In n8n "Listen for test event" aktivieren
# Terminal 2:
curl -s -X POST https://workflows.eppcom.de/webhook-test/ingest \
  -H "Content-Type: application/json" \
  -H "X-API-Key: eppcom-test-key-2026" \
  -d '{"source_name":"FAQ","doc_title":"EPPCOM FAQ","doc_type":"text","chunks":["Test chunk"]}'
```

### 4. Option C (Cartesia STT/TTS) – Nächste Woche
**Was:** Cartesia als primären STT-Anbieter (statt Whisper) konfigurieren
**Ziel:** Noch niedrigere Latenz (~1-2s), höhere Genauigkeit bei Deutsch
**Aufwand:** ~8h

---

## FastAPI RAG Admin UI (appdb.eppcom.de)

**Briefing-Datei:** `Work/ragui/CLAUDE_CODE_BRIEFING.md`
**Status:** eppcom-admin-ui Container läuft (Up), aber App-Status unklar

**Was es können soll:**
- Login per API-Key
- Dashboard: Tenant-Stats, Docs/Chunks/Embeddings
- Datei-Upload (PDF, DOCX, TXT, CSV, HTML) → Text-Extraktion → Chunking → n8n Webhook
- Dokument-Verwaltung (Liste + Löschen)
- S3-Upload (Hetzner nbg1.your-objectstorage.com, Bucket: typebot-assets)

**S3-Hinweis für boto3:** Endpoint OHNE `https://`, nur `nbg1.your-objectstorage.com`

---

## Bekannte Workarounds & Fallstricke

| Problem | Workaround |
|---|---|
| psql direkt nicht verfügbar | `docker exec -e PGPASSWORD="..." postgres-container psql ...` |
| nano nicht installiert (Server 1) | `cat > /path << 'SCRIPT' ... SCRIPT` |
| Production-Webhooks 404 | `/webhook-test/` statt `/webhook/` nutzen |
| n8n IF-Node nach Import leer | Condition manuell setzen |
| SHA256 in n8n Code-Node | Via PostgreSQL: `encode(sha256(...)::bytea), 'hex')` |
| `read -sp` verschluckt Sonderzeichen | Passwort aus Container-Env lesen |
| psql RETURNING extra Zeile | `\| head -1` pipen |
| RLS blockiert Queries | Als `appuser` arbeiten (Owner, umgeht RLS) |

---

## Repo-Struktur (lokal: ~/projects/eppcom-ai-automation/)

```
CLAUDE.md                    ← Haupt-Kontext (immer lesen!)
PROJEKT_HANDOFF_2026-03-27.md ← Diese Datei
VOICEBOT_RAG_OPTIMIERUNG.md  ← Voicebot Upgrade Roadmap (5 Phasen)
Work/
  ragui/
    CLAUDE_CODE_BRIEFING.md  ← FastAPI RAG Admin UI Spec
    EPPCOM_SESSION_HANDOFF.md ← Session-Handoff (älterer Stand)
scripts/
  backup.sh                  ← Backup-Script (täglich 3:00 Uhr)
  fix-all.sh                 ← Allgemeines Fix-Script
  onboard-tenant.sh          ← Tenant-Onboarding
tools/
  token-sync/                ← Mac Keychain → Server Dashboard Sync
docs/
  superpowers/
    plans/                   ← Implementierungspläne
    specs/                   ← Technische Spezifikationen
  specialized/
rag-knowledge/               ← Wissensbasis für RAG
  n8n-workflows/             ← n8n Workflow JSON-Exports
  Recherche-bis1203.md       ← Frühzeitige Recherche
```

---

## Wie fange ich an?

1. **SSH auf Server 1:** `ssh root@94.130.170.167`
2. **Docker-Status prüfen:** `docker ps --format "{{.Names}}: {{.Status}}"`
3. **Nächsten Task angehen:** Voicebot Option B – Task 4 (Local Testing)
4. **Für Claude Code:** `cd ~/projects/eppcom-ai-automation && claude`

---

*Dieser Handoff ersetzt keine detaillierten Specs – für spezifische Implementierungen immer die entsprechenden Briefing-Dateien lesen.*
