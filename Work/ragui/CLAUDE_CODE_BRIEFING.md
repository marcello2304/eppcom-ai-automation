# EPPCOM Document Ingestion App – Claude Code Briefing

## Auftrag

Baue eine **FastAPI Web-App** mit Upload-UI für Dokument-Ingestion in ein RAG-System.
Die App extrahiert Text aus Dateien, chunked ihn und sendet die Chunks an einen bestehenden n8n Workflow, der Embeddings generiert und in PostgreSQL speichert.

**Sprache:** Backend-Code auf Englisch, UI auf Deutsch.

---

## Architektur

```
┌─────────────────────────┐     ┌──────────────────────────────┐
│  FastAPI App (neu)       │     │  n8n Ingestion Workflow      │
│  Port 8080               │     │  (existiert bereits)         │
│                          │     │                              │
│  - Web-UI (Upload)       │────▶│  POST /webhook/ingest        │
│  - Auth (API-Key)        │     │  - Ollama Embedding          │
│  - Text-Extraktion       │     │  - DB Insert (chunks +       │
│  - Chunking              │     │    embeddings)               │
│  - S3 Upload (Original)  │     │  - Status Update             │
│  - Datei-Verwaltung      │     └──────────────────────────────┘
└─────────────────────────┘
         │
         ▼
┌─────────────────────────┐
│  PostgreSQL (appdb)      │
│  - Direkt-Queries für    │
│    Tenant-Auth, Datei-   │
│    liste, Stats          │
└─────────────────────────┘
```

---

## Infrastruktur

### Server 1 – App + DB (94.130.170.167)
- PostgreSQL 16 + pgvector läuft im Docker-Container `postgres-zoc8g4socc0ww80w4s080g4s`
- DB-Host aus einem Docker-Container heraus: `postgres` (Docker-Service-Name)
- DB-Port: 5432
- DB-Name: `appdb`
- DB-User: `appuser`
- DB-Passwort: aus Environment Variable `POSTGRES_PASSWORD` (im Docker Compose Stack gesetzt, NICHT hardcoden!)
- n8n: https://workflows.eppcom.de
- Coolify-Netzwerk: Die App muss im selben Docker-Netzwerk wie PostgreSQL laufen

### Server 2 – Ollama LLM (10.0.0.3 intern / 46.224.54.65 extern)
- Ollama API: http://10.0.0.3:11434 (private IP, von Server 1 erreichbar)
- Embedding-Modell: qwen3-embedding:0.6b (1024 Dimensionen)
- Chat-Modell: qwen3-nothink

### S3 Object Storage (Hetzner)
- Endpoint: nbg1.your-objectstorage.com (OHNE https:// Prefix für boto3!)
- Region: nbg1
- Bucket: typebot-assets
- Access Key: aus Environment Variable `S3_ACCESS_KEY`
- Secret Key: aus Environment Variable `S3_SECRET_KEY`
- Upload-Pfad: `tenants/{tenant_slug}/documents/{filename}`

---

## Datenbank-Schema (exakt!)

### tenants
```sql
id          | uuid           | NOT NULL | DEFAULT uuid_generate_v4()
slug        | varchar(50)    | NOT NULL |
name        | varchar(255)   | NOT NULL |
email       | varchar(255)   |          |
plan        | varchar(50)    |          | DEFAULT 'starter'
s3_prefix   | varchar(255)   |          |
settings    | jsonb          |          | DEFAULT '{}'
is_active   | boolean        |          | DEFAULT true
created_at  | timestamptz    |          | DEFAULT now()
updated_at  | timestamptz    |          | DEFAULT now()
```

### api_keys
```sql
id          | uuid           | NOT NULL | DEFAULT uuid_generate_v4()
tenant_id   | uuid           | NOT NULL | FK → tenants(id)
key_hash    | varchar(64)    | NOT NULL | -- SHA256 hex hash
name        | varchar(100)   |          |
is_active   | boolean        |          | DEFAULT true
created_at  | timestamptz    |          | DEFAULT now()
```
**Auth-Query:**
```sql
SELECT t.id, t.slug, t.name
FROM api_keys ak JOIN tenants t ON t.id = ak.tenant_id
WHERE ak.key_hash = encode(sha256(('<klartext_key>'::text)::bytea), 'hex')
  AND ak.is_active = true AND t.is_active = true;
```

### sources
```sql
id          | uuid           | NOT NULL | DEFAULT uuid_generate_v4()
tenant_id   | uuid           | NOT NULL | FK → tenants(id)
source_type | varchar(50)    |          | -- 'pdf', 'docx', 'txt', 'csv', 'html', 'manual'
name        | varchar(500)   |          |
s3_path     | varchar(1000)  |          |
status      | varchar(50)    |          | -- 'pending', 'processing', 'completed', 'failed'
metadata    | jsonb          |          | DEFAULT '{}'
created_at  | timestamptz    |          | DEFAULT now()
updated_at  | timestamptz    |          | DEFAULT now()
```

### documents
```sql
id           | uuid           | NOT NULL | DEFAULT uuid_generate_v4()
tenant_id    | uuid           | NOT NULL | FK → tenants(id)
source_id    | uuid           | NOT NULL | FK → sources(id)
title        | varchar(500)   |          |
content_text | text           |          |
doc_type     | varchar(50)    |          |
language     | varchar(10)    |          | DEFAULT 'de'
version      | integer        |          | DEFAULT 1
word_count   | integer        |          |
metadata     | jsonb          |          | DEFAULT '{}'
is_active    | boolean        |          | DEFAULT true
created_at   | timestamptz    |          | DEFAULT now()
updated_at   | timestamptz    |          | DEFAULT now()
```

### chunks
```sql
id           | uuid           | NOT NULL | DEFAULT uuid_generate_v4()
tenant_id    | uuid           | NOT NULL | FK → tenants(id)
document_id  | uuid           | NOT NULL | FK → documents(id)
chunk_index  | integer        | NOT NULL |
content      | text           | NOT NULL |
token_count  | integer        |          |
char_count   | integer        |          |
metadata     | jsonb          |          | DEFAULT '{}'
created_at   | timestamptz    |          | DEFAULT now()
```

### embeddings
```sql
id            | uuid           | NOT NULL | DEFAULT uuid_generate_v4()
tenant_id     | uuid           | NOT NULL | FK → tenants(id)
chunk_id      | uuid           | NOT NULL | FK → chunks(id)
document_id   | uuid           | NOT NULL | FK → documents(id)
embedding     | vector(1024)   | NOT NULL |
model_name    | varchar(100)   | NOT NULL |
model_version | varchar(50)    |          |
created_at    | timestamptz    |          | DEFAULT now()
```

---

## n8n Ingestion Webhook – API-Spezifikation

**URL:** `https://workflows.eppcom.de/webhook/ingest`
(Falls Production-Webhook nicht geht, Fallback: `webhook-test/ingest`)

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
  "content_text": "Gesamter extrahierter Text (optional, für Volltextsuche)",
  "word_count": 4500,
  "s3_path": "tenants/test-kunde/documents/Handbuch_v2.pdf",
  "chunks": [
    "Erster Text-Chunk mit max 2000 Zeichen...",
    "Zweiter Text-Chunk mit Overlap...",
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

## App-Anforderungen

### Seiten / Routes

1. **GET /** – Login-Seite (API-Key eingeben)
2. **GET /dashboard** – Übersicht: Tenant-Name, Stats (Docs, Chunks, Embeddings)
3. **POST /upload** – Datei-Upload (Drag & Drop + Button)
4. **GET /documents** – Liste aller Dokumente des Tenants mit Status
5. **DELETE /documents/{source_id}** – Dokument + Chunks + Embeddings löschen (CASCADE)

### Auth-Flow
- User gibt API-Key auf Login-Seite ein
- App prüft Key gegen DB (SHA256-Hash Vergleich)
- Session-Cookie oder JWT für weitere Requests
- Kein Benutzername/Passwort – nur API-Key

### Upload-Flow
1. User wählt Datei(en) aus (max 20 MB pro Datei)
2. App validiert Dateityp (pdf, docx, txt, csv, html)
3. Text-Extraktion je nach Typ:
   - **PDF:** pypdf oder pdfplumber
   - **DOCX:** python-docx
   - **TXT:** direkt lesen (UTF-8)
   - **CSV:** pandas → als Tabellen-Text formatieren
   - **HTML:** beautifulsoup4 → nur Text extrahieren
4. Chunking: 2000 Zeichen pro Chunk, 200 Zeichen Overlap
5. Original-Datei → S3 Upload unter `tenants/{slug}/documents/{filename}`
6. POST chunks an n8n Webhook
7. Status anzeigen (processing → completed/failed)

### Chunking-Algorithmus
```python
def chunk_text(text: str, chunk_size: int = 2000, overlap: int = 200) -> list[str]:
    chunks = []
    start = 0
    while start < len(text):
        end = start + chunk_size
        # Am nächsten Satzende oder Absatz brechen
        if end < len(text):
            # Suche letzten Punkt, Fragezeichen oder Zeilenumbruch vor end
            for sep in ['\n\n', '\n', '. ', '? ', '! ']:
                last_sep = text[start:end].rfind(sep)
                if last_sep > chunk_size * 0.5:
                    end = start + last_sep + len(sep)
                    break
        chunk = text[start:end].strip()
        if chunk:
            chunks.append(chunk)
        start = end - overlap
    return chunks
```

### UI-Design
- Dunkles Theme (passend zu n8n/Coolify Ästhetik)
- Deutsch als UI-Sprache
- Responsive (Desktop + Mobile)
- Drag & Drop Upload-Zone
- Datei-Tabelle mit Spalten: Name, Typ, Status, Chunks, Datum, Aktionen
- Toast-Notifications für Erfolg/Fehler

---

## Tech-Stack

```
FastAPI==0.115.*
uvicorn[standard]==0.30.*
jinja2==3.1.*         # Server-side Templates
python-multipart      # File Upload
asyncpg==0.29.*       # Async PostgreSQL
httpx==0.27.*         # HTTP Client für n8n Webhook
boto3==1.35.*         # S3 Upload
pypdf==4.*            # PDF Text-Extraktion
python-docx==1.*      # DOCX Text-Extraktion
beautifulsoup4==4.12.* # HTML Text-Extraktion
pandas==2.*           # CSV Verarbeitung
python-jose[cryptography]==3.3.* # JWT Sessions
itsdangerous          # Session-Cookies
```

---

## Docker Deployment

Die App wird auf **Server 1 (94.130.170.167)** deployed und muss im selben Docker-Netzwerk wie PostgreSQL laufen.

### Dockerfile
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
```

### Environment Variables (beim Container-Start setzen)
```
DATABASE_HOST=postgres          # Docker-Service-Name
DATABASE_PORT=5432
DATABASE_NAME=appdb
DATABASE_USER=appuser
DATABASE_PASSWORD=${POSTGRES_PASSWORD}
S3_ENDPOINT=nbg1.your-objectstorage.com
S3_ACCESS_KEY=${S3_ACCESS_KEY}
S3_SECRET_KEY=${S3_SECRET_KEY}
S3_BUCKET=typebot-assets
S3_REGION=nbg1
N8N_WEBHOOK_URL=https://workflows.eppcom.de/webhook/ingest
SECRET_KEY=<random-string-for-sessions>
```

### Deploy-Befehl (auf Server 1)
```bash
# Coolify-Netzwerk finden
NETWORK=$(docker network ls --format '{{.Name}}' | grep coolify | head -1)

docker build -t eppcom-ingestion:latest .

docker run -d --name eppcom-ingestion \
  --restart unless-stopped \
  --network $NETWORK \
  -p 8080:8080 \
  -e DATABASE_HOST=postgres \
  -e DATABASE_PORT=5432 \
  -e DATABASE_NAME=appdb \
  -e DATABASE_USER=appuser \
  -e DATABASE_PASSWORD="<aus coolify>" \
  -e S3_ENDPOINT=nbg1.your-objectstorage.com \
  -e S3_ACCESS_KEY="<aus coolify>" \
  -e S3_SECRET_KEY="<aus coolify>" \
  -e S3_BUCKET=typebot-assets \
  -e S3_REGION=nbg1 \
  -e N8N_WEBHOOK_URL=https://workflows.eppcom.de/webhook/ingest \
  -e SECRET_KEY="$(openssl rand -hex 32)" \
  eppcom-ingestion:latest
```

---

## Wichtige Hinweise

1. **S3 Endpoint für boto3:** Muss OHNE `https://` Prefix sein, nur `nbg1.your-objectstorage.com`. boto3 braucht `endpoint_url=f"https://{S3_ENDPOINT}"`.
2. **PostgreSQL:** Verbindung über Docker-Service-Name `postgres`, NICHT über localhost oder IP.
3. **RLS-Policy:** Die DB hat Row Level Security. Für direkte Queries `SET app.current_tenant = '<tenant_id>';` vor jedem Query ausführen, ODER als `appuser` ohne RLS arbeiten (appuser ist Owner und umgeht RLS).
4. **n8n Webhook:** Production-URL (`/webhook/ingest`) hat aktuell ein bekanntes Problem mit 404. Fallback auf Test-URL (`/webhook-test/ingest`) implementieren, falls Production 404 liefert.
5. **Dateigröße:** Max 20 MB pro Upload.
6. **Encoding:** Alle Texte als UTF-8 verarbeiten.

---

## Test-Daten

Es existiert bereits ein Tenant:
- **ID:** `a0000000-0000-0000-0000-000000000001`
- **Slug:** `test-kunde`
- **Name:** Test-Kunde
- **API-Key (Klartext):** `eppcom-test-key-2026`

---

## Projektstruktur (Vorschlag)

```
eppcom-ingestion/
├── main.py                 # FastAPI App + Routes
├── config.py               # Settings via Environment
├── auth.py                 # API-Key Auth + Sessions
├── database.py             # asyncpg Connection Pool
├── s3.py                   # boto3 S3 Client
├── extractor.py            # Text-Extraktion (PDF, DOCX, TXT, CSV, HTML)
├── chunker.py              # Text-Chunking Algorithmus
├── ingestion.py            # n8n Webhook Client
├── templates/
│   ├── base.html           # Layout mit Dark Theme
│   ├── login.html          # API-Key Login
│   ├── dashboard.html      # Übersicht + Upload
│   └── documents.html      # Dokument-Liste
├── static/
│   ├── style.css           # Dark Theme CSS
│   └── app.js              # Upload-Logic, Drag & Drop
├── requirements.txt
├── Dockerfile
└── docker-compose.yml      # Optional für lokale Entwicklung
```
