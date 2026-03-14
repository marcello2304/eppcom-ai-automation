#!/bin/bash
# EPPCOM Solutions – Tenant Onboarding Script
# Erstellt einen neuen Kunden-Tenant mit API-Key und optionalem Test-Dokument
#
# Nutzung:
#   ./onboard-tenant.sh --slug firmenname --name "Firmenname GmbH" --email kontakt@firma.de
#   ./onboard-tenant.sh --slug firmenname --name "Firmenname GmbH" --email kontakt@firma.de --plan pro
#   ./onboard-tenant.sh --slug firmenname --name "Firmenname GmbH" --email kontakt@firma.de --doc "Firmentext hier..."

set -euo pipefail

# --- Defaults ---
PLAN="starter"
DOC_TEXT=""
PG_CONTAINER="postgres-rag"
WEBHOOK_BASE="https://workflows.eppcom.de/webhook"

# --- Argumente parsen ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --slug)  SLUG="$2"; shift 2 ;;
        --name)  NAME="$2"; shift 2 ;;
        --email) EMAIL="$2"; shift 2 ;;
        --plan)  PLAN="$2"; shift 2 ;;
        --doc)   DOC_TEXT="$2"; shift 2 ;;
        *) echo "Unbekannt: $1"; exit 1 ;;
    esac
done

# --- Validierung ---
if [ -z "${SLUG:-}" ] || [ -z "${NAME:-}" ] || [ -z "${EMAIL:-}" ]; then
    echo "Nutzung: $0 --slug <slug> --name <name> --email <email> [--plan starter|pro|enterprise] [--doc <text>]"
    echo ""
    echo "Beispiel:"
    echo "  $0 --slug muster-gmbh --name \"Muster GmbH\" --email info@muster.de"
    exit 1
fi

echo "========================================"
echo "  EPPCOM Tenant Onboarding"
echo "========================================"
echo ""
echo "  Slug:  $SLUG"
echo "  Name:  $NAME"
echo "  Email: $EMAIL"
echo "  Plan:  $PLAN"
echo ""

# 1. Tenant anlegen
echo "[1/4] Tenant anlegen..."
TENANT_ID=$(docker exec "$PG_CONTAINER" psql -U postgres -d app_db -t -A -c "
INSERT INTO tenants (slug, name, email, plan)
VALUES ('${SLUG}', '${NAME}', '${EMAIL}', '${PLAN}')
ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name, email = EXCLUDED.email
RETURNING id;
")

if [ -z "$TENANT_ID" ]; then
    echo "  FEHLER: Tenant konnte nicht angelegt werden"
    exit 1
fi
echo "  Tenant ID: $TENANT_ID"

# 2. API-Key generieren
echo "[2/4] API-Key generieren..."
API_KEY=$(python3 -c "import secrets; print(f'eppcom_{secrets.token_urlsafe(32)}')")
KEY_HASH=$(python3 -c "import hashlib; print(hashlib.sha256('${API_KEY}'.encode()).hexdigest())")

docker exec "$PG_CONTAINER" psql -U postgres -d app_db -t -A -c "
INSERT INTO api_keys (tenant_id, key_hash, name)
VALUES ('${TENANT_ID}', '${KEY_HASH}', 'onboarding-key');
" > /dev/null

echo "  API-Key: $API_KEY"

# 3. Test-Dokument ingestieren (optional)
if [ -n "$DOC_TEXT" ]; then
    echo "[3/4] Test-Dokument ingestieren..."
    RESPONSE=$(curl -s -X POST "${WEBHOOK_BASE}/rag-ingest" \
        -H "Content-Type: application/json" \
        -d "{
            \"tenant_id\": \"${TENANT_ID}\",
            \"source_name\": \"Onboarding-Dokument\",
            \"source_type\": \"manual\",
            \"text\": $(python3 -c "import json; print(json.dumps('''${DOC_TEXT}'''))")
        }")
    STATUS=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('status','error'))" 2>/dev/null || echo "error")
    if [ "$STATUS" = "ok" ]; then
        echo "  Dokument erfolgreich ingestiert"
    else
        echo "  WARNUNG: Dokument-Ingestion fehlgeschlagen: $RESPONSE"
    fi
else
    echo "[3/4] Kein Dokument angegeben, übersprungen"
fi

# 4. Tenant-Statistik
echo "[4/4] Tenant verifizieren..."
STATS=$(docker exec "$PG_CONTAINER" psql -U postgres -d app_db -t -A -c "
SELECT
    (SELECT count(*) FROM sources WHERE tenant_id = '${TENANT_ID}') AS sources,
    (SELECT count(*) FROM documents WHERE tenant_id = '${TENANT_ID}') AS docs,
    (SELECT count(*) FROM chunks WHERE tenant_id = '${TENANT_ID}') AS chunks,
    (SELECT count(*) FROM embeddings WHERE tenant_id = '${TENANT_ID}') AS embeddings;
")
echo "  Daten: $STATS (sources|docs|chunks|embeddings)"

# Zusammenfassung
echo ""
echo "========================================"
echo "  Onboarding abgeschlossen!"
echo "========================================"
echo ""
echo "  Tenant:    $NAME ($SLUG)"
echo "  Tenant ID: $TENANT_ID"
echo "  API-Key:   $API_KEY"
echo "  Plan:      $PLAN"
echo ""
echo "  Webhooks:"
echo "    Ingestion: POST ${WEBHOOK_BASE}/rag-ingest"
echo "               Body: {\"tenant_id\": \"${TENANT_ID}\", \"text\": \"...\", \"source_name\": \"...\"}"
echo ""
echo "    RAG-Query: POST ${WEBHOOK_BASE}/rag-query"
echo "               Body: {\"tenant_id\": \"${TENANT_ID}\", \"query\": \"...\"}"
echo ""
echo "    Lead:      POST ${WEBHOOK_BASE}/ingest"
echo "               Body: {\"name\": \"...\", \"email\": \"...\", \"nachricht\": \"...\", \"quelle\": \"$SLUG\"}"
echo ""
echo "  WICHTIG: API-Key sicher speichern – er wird nicht erneut angezeigt!"
echo "========================================"
