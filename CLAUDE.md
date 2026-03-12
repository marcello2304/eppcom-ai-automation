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
| eppcom.de | Hauptwebsite |

---

## 7. Offene Tasks (Priorität nach Reihenfolge)

- [ ] **Fix `/no_think` Modelfile** – qwen3:1.7b Modelfile-Issue in Ollama
- [ ] **Server 1 → Server 2 Connectivity-Test** – Verbindung zwischen beiden Servern verifizieren
- [ ] **n8n Ingestion Workflow** – Dokumente in pgvector einlesen
- [ ] **n8n RAG Retrieval Workflow** – Vektorsuche + LLM-Antwort über n8n
- [ ] **Backup-Cronjob einrichten** – PostgreSQL + Dateien automatisch sichern
- [ ] **Ersten Kunden-Tenant onboarden** – Erster produktiver Mandant

---

## 8. Noch nicht implementiert

- n8n Workflows (Ingestion & Retrieval)
- Backup-Cronjobs
- Voicebot-Stack auf Server 2 (nur Dokumentation vorhanden)
- LiveKit-Integration

---

## 9. Skalierungsziel

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

## 10. DSGVO & Compliance

- Alle Server in der **EU (Hetzner Deutschland)**
- Keine Daten verlassen die EU
- Selbst gehostete Modelle (kein OpenAI, kein externer API-Aufruf für Kundendaten)
- DSGVO-konforme Cookie-Implementierung auf eppcom.de ausstehend

---

## 11. SEO / Website (eppcom.de)

Durchgeführtes Audit mit folgenden offenen Maßnahmen:
- Performance-Optimierungen
- Google Business Profile einrichten
- Schema.org LocalBusiness Markup implementieren
- DSGVO-Cookie-Compliance umsetzen
- Security-Header optimieren

---

## 12. Lokale Entwicklungsumgebung

- **Mac:** Marcel's MacBook Air
- **IDE:** Visual Studio Code
- **Projektpfad:** `~/projects/eppcom-ai-automation/`
- **Claude Code starten:** `cd ~/projects/eppcom-ai-automation && claude`
- **Settings:** `.claude/settings.local.json`

---

## 13. Wichtige Befehle

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

## 14. Session-Start Checkliste

Zu Beginn jeder Claude Code Session:
1. CLAUDE.md lesen (diese Datei)
2. Offene Tasks prüfen (Abschnitt 7)
3. Mit dem ersten offenen Task fortfahren

---

*Zuletzt aktualisiert: März 2026*
*Bei Fortschritt: CLAUDE.md aktualisieren und committen*
