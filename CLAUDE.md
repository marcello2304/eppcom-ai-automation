# CLAUDE.md – EPPCOM Solutions AI Automation Platform

> Dieses Dokument ist die einzige Quelle der Wahrheit für alle Claude Code Sessions.
> Lies diese Datei zu Beginn jeder Session vollständig.

---

## 1. Rolle & Kontext

Du bist Senior DevOps Architekt für Self-Hosting auf Hetzner, spezialisiert auf:
- Docker, Coolify, PostgreSQL/pgvector
- n8n, Typebot, Ollama
- S3-kompatiblen Object Storage, LiveKit, VoIP/Voicebot-Infrastruktur
- DSGVO-konforme, selbst gehostete KI-Systeme

---

## 2. Unternehmen

**EPPCOM Solutions**
- Inhaber: Marcel Eppler
- Standort: Reutlingen, Baden-Württemberg, Deutschland
- Geschäftsmodell: KI-Automatisierung & Workflow-Optimierung für Kunden
- Kernprodukt: Multi-tenant RAG-Chatbot & Voicebot-Plattform (selbst gehostet, DSGVO-konform)

---

## 3. Infrastruktur

### Server 1 – Hetzner CX23
- **IP:** 94.130.170.167
- **Rolle:** Haupt-Stack (Coolify-managed)
- **Laufende Dienste (alle healthy):**
  - `coolify` + `coolify-sentinel` + `coolify-realtime` + `coolify-db` + `coolify-redis` + `coolify-proxy`
  - `postgres-rag` – PostgreSQL mit pgvector (RAG-Datenspeicher, appdb)
  - `postgres-zoc8g4socc0ww80w4s080g4s` – Haupt-PostgreSQL für Typebot/n8n
  - `n8n` – Workflow-Automatisierung → workflows.eppcom.de
  - `typebot-builder` – Admin-Interface → admin-bot.eppcom.de
  - `typebot-viewer` – Public Widget → bot.eppcom.de
  - `code-server` – VS Code im Browser → code.eppcom.de (Docker-Container)
  - `eppcom-admin-ui` – RAG Admin UI (FastAPI) → appdb.eppcom.de
  - `voice-agent` – LiveKit Voice Agent (Python, eppcom/voice-agent:latest)
  - `livekit-token-server` – Token-API für LiveKit-Verbindungen
  - `livekit-wss-proxy` – WebSocket-Proxy für LiveKit
  - `livekit-db` – PostgreSQL für LiveKit
  - `jitsi-meet` Stack (web, prosody, jicofo, jvb)
- **Git Repo:** `~/projects/eppcom-ai-automation` (geklont, remote: marcello2304)
- **Voice-Agent Code:** `/root/marcello2304/voice-agent/agent.py`

### Server 2 – Hetzner CX33
- **IP:** 46.224.54.65 (intern: 10.0.0.3)
- **Rolle:** LLM-Inferenz & Voice-Stack
- **Laufende Dienste:**
  - `ollama` – Lokale LLM-Inferenz (Port 11434)
  - `livekit-server` – WebRTC Signaling (Port 7880) → livekit.eppcom.de
  - `livekit-db` – PostgreSQL 16 für LiveKit (Port 5433)

### Geplante Hardware (zurückgestellt bis Produktion)
- Hetzner AX42 oder GEX44 (Dedicated)

---

## 4. Tech Stack

| Komponente | Technologie | Details |
|---|---|---|
| Embedding-Modell | qwen3-embedding:0.6b | 1024 Dimensionen |
| Inferenz-Modell | qwen2.5:7b-eppcom / phi:latest | via Ollama auf Server 2 |
| Voice STT | Local Whisper (small) | Fallback: Deepgram, OpenAI Whisper |
| Voice TTS | Cartesia Sonic-2 | Fallback: OpenAI TTS-1 |
| Voice Signaling | LiveKit v1.4 | livekit-agents Python SDK |
| Vektordatenbank | PostgreSQL + pgvector | HNSW-Index, RLS aktiv |
| RAG-Schema | 9 Tabellen | Multi-tenant, RLS |
| Workflow-Engine | n8n | Auf Server 1 |
| Chat-Frontend | Typebot | Builder + Viewer getrennt |
| Hosting | Hetzner EU | DSGVO-konform |
| Deployment | Coolify | Server 1 |
| Object Storage | S3-kompatibel (Hetzner) | Bucket: typebot-assets, Region: nbg1 |

---

## 5. RAG-Datenbankschema

**DB:** appdb, User: appuser, Container: postgres-rag

- **9 Tabellen** mit Multi-Tenant-Isolierung
- **pgvector** mit HNSW-Index
- **Row Level Security (RLS)** aktiv
- Embedding-Dimensionen: 1024 (qwen3-embedding:0.6b)

### Kernzugriff (psql via docker exec):
```bash
docker exec -e PGPASSWORD="$(docker exec postgres-zoc8g4socc0ww80w4s080g4s env | grep POSTGRES_PASSWORD | cut -d= -f2-)" postgres-zoc8g4socc0ww80w4s080g4s psql -h localhost -U appuser -d appdb -c "SQL;"
```

### Test-Tenant:
- **ID:** `a0000000-0000-0000-0000-000000000001`
- **Slug:** `test-kunde` / `eppcom`
- **API-Key (Klartext):** `eppcom-test-key-2026`
- **Daten:** 3 Dokumente (EPPCOM Profil, Services, Technik), 7 Chunks, 7 Embeddings

---

## 6. Domains

| Domain | Dienst |
|---|---|
| admin-bot.eppcom.de | Typebot Builder |
| bot.eppcom.de | Typebot Viewer (Chatbot: `eppcom-chatbot-v2`) |
| appdb.eppcom.de | RAG Admin UI + API |
| appdb.eppcom.de/api/public/voice-token | Voice Token Endpoint |
| workflows.eppcom.de | n8n |
| livekit.eppcom.de | LiveKit Signaling Server |
| code.eppcom.de | code-server (VS Code im Browser) |
| eppcom.de | Hauptwebsite |

---

## 7. n8n Webhooks

| Webhook | URL (Test) | Status |
|---|---|---|
| RAG Chat | `https://workflows.eppcom.de/webhook-test/rag-chat` | ✅ funktioniert |
| RAG Ingest | `https://workflows.eppcom.de/webhook-test/ingest` | ⚠️ Auth-Fix nötig |
| Contact Lead | `https://workflows.eppcom.de/webhook/ingest` | ✅ aktiv |
| RAG Query | `https://workflows.eppcom.de/webhook/rag-query` | ✅ aktiv |

**Auth-Header:** `X-API-Key: eppcom-test-key-2026`
**Tenant-Header:** `X-Tenant-ID: a0000000-0000-0000-0000-000000000001`

**Bekannte Probleme:**
- Production-Webhooks (`/webhook/`) geben teilweise 404 → Test-URL verwenden
- IF-Node Conditions gehen beim Import verloren → manuell nach Import prüfen
- n8n crypto-Modul blockiert → SHA256 via PostgreSQL: `encode(sha256(('key'::text)::bytea), 'hex')`

---

## 8. Voice-Agent (Nexo)

**Code:** `/root/marcello2304/voice-agent/agent.py` (Server 1)
**Container:** `voice-agent` (eppcom/voice-agent:latest)

**Architektur:**
```
User Speech → Local Whisper STT → NexoStreamingAgent → Ollama LLM → Cartesia TTS → User
                                         ↓
                               n8n RAG Webhook (optional)
```

**Klassen:**
- `NexoAgent` – Basis-Agent (kein Streaming)
- `NexoStreamingAgent` – Satzweises Token-Streaming (Standard, VOICEBOT_STREAMING_ENABLED=true)

**Env Vars:**
```
LIVEKIT_URL=ws://livekit:7880
OLLAMA_BASE_URL=http://10.0.0.3:11434
OLLAMA_MODEL=qwen2.5:7b-eppcom
CARTESIA_API_KEY=...
RAG_WEBHOOK_URL=https://workflows.eppcom.de/webhook/rag-query
RAG_TENANT_ID=a0000000-0000-0000-0000-000000000001
VOICEBOT_STREAMING_ENABLED=true
USE_LOCAL_WHISPER=true
```

---

## 9. Offene Tasks (Priorität)

- [ ] **Voicebot Option B – Task 4: Local Testing** – NexoStreamingAgent lokal testen
- [ ] **Voicebot Option B – Task 5: Deploy to Server 2** – Container neu bauen & deployen
- [ ] **Voicebot Option B – Task 6: Performance Validation** – Latenz messen (Ziel: <3s)
- [ ] **Typebot → RAG Webhook verbinden** – HTTP-Request-Block in Typebot auf `/webhook-test/rag-chat` zeigen lassen
- [ ] **Option C (Cartesia STT/TTS)** – Nächste Woche, ca. 8h
- [ ] **Production-Webhook 404 fixen** – n8n Production-Webhooks reaktivieren
- [ ] **Ingestion Workflow E2E-Test** – Auth-IF-Node-Fix verifizieren + End-to-End durchlaufen

---

## 10. Abgeschlossene Tasks

- [x] **code-server** – VS Code im Browser via code.eppcom.de
- [x] **Claude Code auf Server 1** – CLI installiert, Auth via `claude --no-browser`
- [x] **Token-Sync System** – Cronjob (5 Min), Mac Keychain → Anthropic API → Server Dashboard
- [x] **Git Repo auf Server 1** – geklont, SSH-Key eingerichtet (marcello2304)
- [x] **Security** – UFW, .gitignore, chmod 600
- [x] **Server 1 → Server 2 Connectivity** – SSH + UFW Port 11434 + Ollama auf 0.0.0.0
- [x] **Fix `/no_think` Modelfile** – `qwen3-nothink:latest` bereits vorhanden
- [x] **Typebot Chatbot Template** – Ollama-Webhook, Telefonnummer, n8n-Lead-Webhook
- [x] **leads Tabelle** – in appdb angelegt
- [x] **n8n Contact-Lead Workflow** – importiert & aktiv
- [x] **n8n Ingestion Workflow** – RAG-Pipeline aktiv (Text→Chunks→Embeddings→pgvector)
- [x] **n8n RAG Retrieval Workflow** – Vektorsuche + qwen3:1.7b
- [x] **Typebot eppcom-chatbot-v2** – veröffentlicht unter bot.eppcom.de/eppcom-chatbot-v2
- [x] **Backup-Cronjob** – täglich 3:00 Uhr, 7 Tage lokal
- [x] **Erster Tenant (EPPCOM) onboarded** – 3 Docs, 7 Chunks, 7 Embeddings
- [x] **Ingestion Workflow v5** – Batch-Embedding + Single-CTE-SQL, atomar
- [x] **LiveKit Voice-Stack** – Server 2: PostgreSQL + LiveKit Server, livekit.eppcom.de
- [x] **voice-agent Integration** – Worker registered, Typebot Voice-ready
- [x] **Voicebot Option A** – phi:latest statt qwen3:1.7b (7-13s → ~5-8s Latenz)
- [x] **Voicebot Option B Task 1** – Imports & Constants
- [x] **Voicebot Option B Task 2** – NexoStreamingAgent implementiert (alle 3 Tests passing)
- [x] **Voicebot Option B Task 3** – Entrypoint aktualisiert

---

## 11. Skalierungsziel

```
Start:    10 Kunden
Stufe 2:  20–50 Kunden
Stufe 3:  100 Kunden
Stufe 4:  200+ Kunden
```

---

## 12. DSGVO & Compliance

- Alle Server in der **EU (Hetzner Deutschland)**
- Keine Daten verlassen die EU
- Selbst gehostete Modelle
- DSGVO-konforme Cookie-Implementierung auf eppcom.de ausstehend

---

## 13. Entwicklungsumgebung

### Lokal (Mac)
- **Projektpfad:** `~/projects/eppcom-ai-automation/`
- **Claude Code starten:** `cd ~/projects/eppcom-ai-automation && claude`

### Remote (code-server)
- **URL:** https://code.eppcom.de
- **Claude Code:** `claude --no-browser` im Terminal
- **Projektpfad Server:** `~/projects/eppcom-ai-automation/`

---

## 14. Wichtige Befehle

```bash
# SSH Server 1
ssh root@94.130.170.167

# SSH Server 2
ssh root@46.224.54.65

# Docker Status Server 1
docker ps --format "{{.Names}}: {{.Status}}"

# PostgreSQL (appdb) via docker exec
docker exec -e PGPASSWORD="$(docker exec postgres-zoc8g4socc0ww80w4s080g4s env | grep POSTGRES_PASSWORD | cut -d= -f2-)" postgres-zoc8g4socc0ww80w4s080g4s psql -h localhost -U appuser -d appdb -c "SQL;"

# Ollama auf Server 2 von Server 1 aus testen
curl -s http://10.0.0.3:11434/api/version

# RAG Chat testen
curl -X POST https://workflows.eppcom.de/webhook-test/rag-chat \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: a0000000-0000-0000-0000-000000000001" \
  -H "X-API-Key: eppcom-test-key-2026" \
  -d '{"query": "Was ist EPPCOM?"}'

# Voice-Agent Logs
docker logs voice-agent --tail=50 -f

# Claude Code starten
cd ~/projects/eppcom-ai-automation && claude
```

---

## 15. Session-Start Checkliste

1. CLAUDE.md lesen (diese Datei)
2. Offene Tasks prüfen (Abschnitt 9)
3. Mit dem ersten offenen Task fortfahren

---

*Zuletzt aktualisiert: 27. März 2026*
*Bei Fortschritt: CLAUDE.md aktualisieren und committen*
