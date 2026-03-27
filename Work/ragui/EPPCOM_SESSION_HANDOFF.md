# EPPCOM Projekt – Session-Handoff für Claude Code

## Was wurde in dieser Session erledigt

### 1. RAG Testdaten eingefügt (Server 1)
- Script `/root/insert_testdata.sh` erstellt und erfolgreich ausgeführt
- 1 Source, 1 Document, 3 Chunks, 3 Embeddings für Test-Tenant eingefügt
- Alle psql-Befehle laufen über `docker exec` (Port 5432 nicht auf Host gemappt)
- Passwort wird automatisch aus Container gelesen (read -sp verschluckt Sonderzeichen)

### 2. RAG Chat Workflow (Workflow 2) – FUNKTIONIERT ✅
- Webhook-Test erfolgreich: `POST /webhook-test/rag-chat`
- Korrekte Antwort mit 3 Sources, Similarity-Scores, 119 Tokens in ~13s
- **Production-Webhook (`/webhook/rag-chat`) gibt 404** – bekanntes Problem, noch nicht gelöst
- Test-Befehl:
```bash
curl -X POST https://workflows.eppcom.de/webhook-test/rag-chat \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: a0000000-0000-0000-0000-000000000001" \
  -H "X-API-Key: eppcom-test-key-2026" \
  -d '{"query": "Was ist EPPCOM?"}'
```

### 3. Document Ingestion Workflow (Workflow 1) – IMPORTIERT, AUTH-FIX NÖTIG
- Workflow JSON importiert in n8n als "Document Ingestion – EPPCOM"
- PostgreSQL-Credentials wurden in allen PG-Nodes gesetzt
- **IF-Node "Auth OK?" hatte keine Condition nach Import** (bekannter n8n-Bug)
- Condition manuell gesetzt: `{{ $json.tenant_id }}` → String → "is not empty"
- **Status: Auth funktioniert im Step-by-Step-Test, aber End-to-End-Test steht noch aus**
- Der Workflow geht noch auf den False Branch (401) – möglicherweise nicht gespeichert nach Condition-Fix
- Test-Befehl:
```bash
curl -s -X POST https://workflows.eppcom.de/webhook-test/ingest \
  -H "Content-Type: application/json" \
  -H "X-API-Key: eppcom-test-key-2026" \
  -d '{"source_name":"FAQ Test","doc_title":"EPPCOM FAQ","doc_type":"text","chunks":["Test chunk eins","Test chunk zwei"]}' | python3 -m json.tool
```

### 4. Neuer API-Key angelegt
- Klartext: `eppcom-test-key-2026`
- Hash in DB: `encode(sha256(('eppcom-test-key-2026'::text)::bytea), 'hex')`
- Verifiziert: Key existiert und ist aktiv

---

## Infrastruktur-Details (verifiziert in dieser Session)

### Server 1 (94.130.170.167) – Workflows
- PostgreSQL Container: `postgres-zoc8g4socc0ww80w4s080g4s`
- Port 5432 NICHT auf Host gemappt → alle psql über docker exec
- DB-Passwort auslesen: `docker exec postgres-zoc8g4socc0ww80w4s080g4s env | grep POSTGRES_PASSWORD | cut -d= -f2-`
- Zuverlässiges psql-Pattern:
```bash
docker exec -e PGPASSWORD="$(docker exec postgres-zoc8g4socc0ww80w4s080g4s env | grep POSTGRES_PASSWORD | cut -d= -f2-)" postgres-zoc8g4socc0ww80w4s080g4s psql -h localhost -U appuser -d appdb -c "SQL;"
```
- n8n Container: `docker ps --format '{{.Names}}' | grep n8n`
- Aktive Workflows prüfen: `docker exec $(docker ps --format '{{.Names}}' | grep n8n) n8n list:workflow --active=true`
- nano NICHT installiert, Scripts via `cat > /path << 'SCRIPT'` schreiben
- python3 ist installiert auf dem Host

### Server 2 (10.0.0.3 intern) – Ollama
- Ollama erreichbar von Server 1 über private IP: `http://10.0.0.3:11434`
- Embedding: `qwen3-embedding:0.6b` (1024 Dimensionen)
- Chat: `qwen3-nothink` (Modelfile mit /no_think hardcoded)

### S3
- Endpoint für boto3: `nbg1.your-objectstorage.com` (OHNE https://)
- Bucket: `typebot-assets`
- Region: `nbg1`

---

## Exakte DB-Schemas (verifiziert!)

### tenants
```
id          | uuid           | NOT NULL | DEFAULT uuid_generate_v4()
slug        | varchar(50)    | NOT NULL
name        | varchar(255)   | NOT NULL    ← NICHT company_name!
email       | varchar(255)
plan        | varchar(50)    | DEFAULT 'starter'
s3_prefix   | varchar(255)
settings    | jsonb          | DEFAULT '{}'
is_active   | boolean        | DEFAULT true
created_at  | timestamptz    | DEFAULT now()
updated_at  | timestamptz    | DEFAULT now()
```

### api_keys
```
id          | uuid           | NOT NULL
tenant_id   | uuid           | NOT NULL | FK → tenants(id)
key_hash    | varchar(64)    | NOT NULL   ← SHA256 hex
name        | varchar(100)                ← NICHT label!
is_active   | boolean        | DEFAULT true
created_at  | timestamptz    | DEFAULT now()
```

### sources
```
id          | uuid           | NOT NULL
tenant_id   | uuid           | NOT NULL | FK → tenants(id)
source_type | varchar(50)
name        | varchar(500)
s3_path     | varchar(1000)
status      | varchar(50)     ← 'pending', 'processing', 'completed', 'failed'
metadata    | jsonb          | DEFAULT '{}'
created_at  | timestamptz    | DEFAULT now()
updated_at  | timestamptz    | DEFAULT now()
```

### documents
```
id           | uuid           | NOT NULL
tenant_id    | uuid           | NOT NULL | FK → tenants(id)
source_id    | uuid           | NOT NULL | FK → sources(id)
title        | varchar(500)
content_text | text            ← NICHT content!
doc_type     | varchar(50)
language     | varchar(10)    | DEFAULT 'de'
version      | integer        | DEFAULT 1
word_count   | integer         ← NICHT char_count!
metadata     | jsonb          | DEFAULT '{}'
is_active    | boolean        | DEFAULT true
created_at   | timestamptz    | DEFAULT now()
updated_at   | timestamptz    | DEFAULT now()
```

### chunks
```
id           | uuid           | NOT NULL
tenant_id    | uuid           | NOT NULL | FK → tenants(id)
document_id  | uuid           | NOT NULL | FK → documents(id)
chunk_index  | integer        | NOT NULL
content      | text           | NOT NULL
token_count  | integer
char_count   | integer
metadata     | jsonb          | DEFAULT '{}'
created_at   | timestamptz    | DEFAULT now()
```

### embeddings
```
id            | uuid           | NOT NULL
tenant_id     | uuid           | NOT NULL | FK → tenants(id)
chunk_id      | uuid           | NOT NULL | FK → chunks(id)
document_id   | uuid           | NOT NULL | FK → documents(id)  ← REQUIRED!
embedding     | vector(1024)   | NOT NULL
model_name    | varchar(100)   | NOT NULL
model_version | varchar(50)
created_at    | timestamptz    | DEFAULT now()
```

---

## Test-Tenant
- **ID:** `a0000000-0000-0000-0000-000000000001`
- **Slug:** `test-kunde`
- **Name:** Test-Kunde
- **API-Key (Klartext):** `eppcom-test-key-2026`

---

## n8n Ingestion Webhook API (für die FastAPI App)

**URL:** `https://workflows.eppcom.de/webhook-test/ingest` (Test)
**URL:** `https://workflows.eppcom.de/webhook/ingest` (Production – hat aktuell 404-Problem)

**Method:** POST

**Headers:**
```
X-API-Key: <klartext-api-key>
Content-Type: application/json
```

**Body:**
```json
{
  "source_name": "Handbuch_v2.pdf",
  "doc_title": "Produkthandbuch Version 2",
  "doc_type": "pdf",
  "content_text": "Gesamter extrahierter Text",
  "word_count": 4500,
  "s3_path": "tenants/test-kunde/documents/Handbuch_v2.pdf",
  "chunks": [
    "Erster Text-Chunk...",
    "Zweiter Text-Chunk...",
    "Dritter Text-Chunk..."
  ]
}
```

**Response (200):**
```json
{
  "success": true,
  "message": "Document ingested successfully",
  "source_id": "uuid",
  "document_id": "uuid",
  "chunks_processed": 3
}
```

---

## Bekannte Probleme & Workarounds

1. **Production-Webhooks geben 404** – Test-Webhooks (`/webhook-test/`) funktionieren. n8n Container-Restart hat nicht geholfen. Workflow ist als active gelistet.

2. **n8n IF-Node Conditions gehen bei Import verloren** – Immer manuell nach Import prüfen und neu setzen.

3. **read -sp in bash verschluckt Sonderzeichen** – Passwörter immer automatisch aus Container-Env lesen: `$(docker exec CONTAINER env | grep VAR | cut -d= -f2-)`

4. **psql RETURNING gibt Extra-Zeile "INSERT 0 1"** – Immer durch `| head -1` pipen.

5. **n8n crypto-Modul blockiert** – SHA256 über PostgreSQL: `encode(sha256(('key'::text)::bytea), 'hex')`

6. **n8n HTTP Request Node** – JSON Body mit dynamischen Werten als Expression: `={{ JSON.stringify({...}) }}`

---

## Nächste Schritte

1. **Document Ingestion Workflow End-to-End-Test abschließen** – Auth OK? IF-Node speichern, "Listen for test event" + curl gleichzeitig
2. **FastAPI Ingestion App bauen** (das Claude Code Projekt) – Briefing liegt vor als CLAUDE_CODE_BRIEFING.md
3. **Production-Webhook-Problem lösen** (n8n)
4. **Chat History Workflow** (Workflow 3) bauen
5. **Typebot anbinden** an RAG Chat Webhook
