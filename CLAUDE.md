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
  - `postgres-rag` – PostgreSQL mit pgvector (RAG-Datenspeicher)
  - `n8n` – Workflow-Automatisierung
  - `typebot-builder` – Admin-Interface → admin-bot.eppcom.de
  - `typebot-viewer` – Public Widget → bot.eppcom.de
  - `code-server` v4.111.0 – VS Code im Browser → code.eppcom.de (Port 8888, systemd)
  - `eppcom-token-api` – FastAPI Token-Usage API (Port 3333, systemd)
  - `Claude Code` v2.1.74 – CLI installiert (Auth via `claude --no-browser`)
- **Git Repo:** `~/projects/eppcom-ai-automation` (geklont, remote: marcello2304)

### Server 2 – Hetzner CX33
- **IP:** 46.224.54.65
- **Rolle:** LLM-Inferenz
- **Laufende Dienste:**
  - `ollama` – Lokale LLM-Inferenz (Port 11434)
- **Geplant:** LiveKit Voicebot-Stack

### Geplante Hardware (zurückgestellt bis Produktion)
- Hetzner AX42 oder GEX44 (Dedicated)

---

## 4. Tech Stack

| Komponente | Technologie | Details |
|---|---|---|
| Embedding-Modell | qwen3-embedding:0.6b | 1024 Dimensionen |
| Inferenz-Modell | qwen3:1.7b | via Ollama auf Server 2 |
| Vektordatenbank | PostgreSQL + pgvector | HNSW-Index, RLS aktiv |
| RAG-Schema | 9 Tabellen | Multi-tenant, RLS |
| Workflow-Engine | n8n | Auf Server 1 |
| Chat-Frontend | Typebot | Builder + Viewer getrennt |
| Widget | React | Voiceflow-Style, custom |
| Hosting | Hetzner EU | DSGVO-konform |
| Deployment | Coolify | Server 1 |
| Object Storage | S3-kompatibel (Hetzner) | Für Uploads, Audio, Assets |

---

## 5. RAG-Datenbankschema

- **9 Tabellen** mit Multi-Tenant-Isolierung
- **pgvector** mit HNSW-Index
- **Row Level Security (RLS)** aktiv
- Embedding-Dimensionen: 1024 (qwen3-embedding:0.6b)

---

## 6. Domains

| Domain | Dienst |
|---|---|
| admin-bot.eppcom.de | Typebot Builder |
| bot.eppcom.de | Typebot Viewer |
| code.eppcom.de | code-server (VS Code im Browser) |
| code.eppcom.de/api/token-usage/dashboard | Token-Usage Dashboard |
| eppcom.de | Hauptwebsite |

---

## 7. Offene Tasks (Priorität nach Reihenfolge)

- [ ] **Typebot Template importieren** – `Work/VoiceflowChatbot/voiceflow-chatbot-template.json` in admin-bot.eppcom.de importieren & testen
- [ ] **Backup-Cronjob einrichten** – PostgreSQL + Dateien automatisch sichern
- [ ] **Ersten Kunden-Tenant onboarden** – Erster produktiver Mandant

---

## 8. Abgeschlossene Tasks

- [x] **code-server eingerichtet** – VS Code im Browser via code.eppcom.de (HTTPS, Passwort)
- [x] **Claude Code auf Server 1** – CLI installiert, Auth via `claude --no-browser`
- [x] **Token-Sync System** – Cronjob (5 Min), Mac Keychain → Anthropic API → Server Dashboard
- [x] **Git Repo auf Server 1** – geklont, SSH-Key eingerichtet (marcello2304)
- [x] **Traefik-Routing** – code-server + Token-API via dynamische Configs
- [x] **Security** – UFW, .gitignore, chmod 600, sensible Daten geschützt
- [x] **Server 1 → Server 2 Connectivity** – SSH-Key + UFW Port 11434 + Ollama auf 0.0.0.0 konfiguriert
- [x] **Fix `/no_think` Modelfile** – `qwen3-nothink:latest` bereits vorhanden auf Server 2
- [x] **Typebot Chatbot Template** – Ollama-Webhook, Telefonnummer-Feld, n8n-Lead-Webhook integriert
- [x] **leads Tabelle** – in app_db angelegt (email unique, status, notizen)
- [x] **Claude Code Auto-Permissions** – alle Tools auto-approved, Modell Opus 4.6 gesetzt
- [x] **n8n Contact-Lead Workflow** – importiert & aktiviert, Webhook: `https://workflows.eppcom.de/webhook/ingest`, Credentials: postgres-rag (app_db) + EPPCOM SMTP (IONOS)
- [x] **n8n Ingestion Workflow** – RAG-Pipeline aktiv, Webhook: `https://workflows.eppcom.de/webhook/rag-ingest`, Text→Chunks→Ollama Embeddings→pgvector
- [x] **n8n RAG Retrieval Workflow** – Vektorsuche + LLM-Antwort, Webhook: `https://workflows.eppcom.de/webhook/rag-query`, Query→Embedding→pgvector→qwen3:1.7b

## 9. Noch nicht implementiert (Backlog)

- n8n Workflows (Ingestion & Retrieval)
- Backup-Cronjobs
- Voicebot-Stack auf Server 2 (nur Dokumentation vorhanden)
- LiveKit-Integration

---

## 10. Skalierungsziel

```
Start:    10 Kunden
Stufe 2:  20–50 Kunden
Stufe 3:  100 Kunden
Stufe 4:  200+ Kunden
```

- Jeder Kunde hat **getrennte RAG-Daten** (Multi-Tenant, RLS)
- Daten müssen sichtbar, sortiert und nachvollziehbar sein
- Pro Kunde separat verwaltbar

---

## 11. DSGVO & Compliance

- Alle Server in der **EU (Hetzner Deutschland)**
- Keine Daten verlassen die EU
- Selbst gehostete Modelle (kein OpenAI, kein externer API-Aufruf für Kundendaten)
- DSGVO-konforme Cookie-Implementierung auf eppcom.de ausstehend

---

## 12. SEO / Website (eppcom.de)

Durchgeführtes Audit mit folgenden offenen Maßnahmen:
- Performance-Optimierungen
- Google Business Profile einrichten
- Schema.org LocalBusiness Markup implementieren
- DSGVO-Cookie-Compliance umsetzen
- Security-Header optimieren

---

## 13. Entwicklungsumgebung

### Lokal (Mac)
- **Mac:** Marcel's MacBook Air
- **IDE:** Visual Studio Code
- **Projektpfad:** `~/projects/eppcom-ai-automation/`
- **Claude Code starten:** `cd ~/projects/eppcom-ai-automation && claude`
- **Settings:** `.claude/settings.local.json`

### Remote (code-server)
- **URL:** https://code.eppcom.de (Passwort-geschützt)
- **Zugang:** Mac, iPad, iPhone – jeder Browser
- **Claude Code:** `claude --no-browser` im Terminal
- **Git-Sync:** Änderungen per `git commit + push/pull` synchronisieren
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

# Ollama Status Server 2
curl -s http://localhost:11434/api/version

# Ollama Modelle prüfen
curl -s http://localhost:11434/api/tags | python3 -c "import sys,json; [print(f' {m[\"name\"]}') for m in json.loads(sys.stdin.read()).get('models',[])]"

# Claude Code starten
cd ~/projects/eppcom-ai-automation && claude
```

---

## 15. Session-Start Checkliste

Zu Beginn jeder Claude Code Session:
1. CLAUDE.md lesen (diese Datei)
2. Offene Tasks prüfen (Abschnitt 7)
3. Mit dem ersten offenen Task fortfahren

---

*Zuletzt aktualisiert: 13. März 2026*
*Bei Fortschritt: CLAUDE.md aktualisieren und committen*
