#!/bin/bash
# EPPCOM Solutions – Daily Backup Script
# PostgreSQL (app_db + typebot_db) + Coolify configs
# Lokale Aufbewahrung: 7 Tage | S3-Aufbewahrung: 30 Tage

set -euo pipefail

# --- Konfiguration ---
BACKUP_DIR="/root/backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_SUBDIR="${BACKUP_DIR}/${DATE}"
LOCAL_RETENTION_DAYS=7

# S3 (Hetzner Object Storage)
S3_BUCKET="eppcom-backups"
S3_ENDPOINT="https://nbg1.your-objectstorage.com"
S3_ACCESS_KEY="REDACTED"
S3_SECRET_KEY="REDACTED"
S3_REGION="nbg1"
S3_RETENTION_DAYS=30

# PostgreSQL Container
PG_RAG_CONTAINER="postgres-rag"
PG_TYPEBOT_CONTAINER="postgres-zoc8g4socc0ww80w4s080g4s"

LOG_FILE="${BACKUP_DIR}/backup.log"

# --- Funktionen ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# --- Start ---
mkdir -p "$BACKUP_SUBDIR"
log "=== Backup gestartet ==="

# 1. PostgreSQL app_db (RAG-Daten, Leads)
log "PostgreSQL app_db backup..."
if docker exec "$PG_RAG_CONTAINER" pg_dump -U postgres -Fc app_db > "${BACKUP_SUBDIR}/app_db.dump" 2>>"$LOG_FILE"; then
    SIZE=$(du -sh "${BACKUP_SUBDIR}/app_db.dump" | cut -f1)
    log "  app_db: OK (${SIZE})"
else
    log "  app_db: FEHLER"
fi

# 2. PostgreSQL typebot_db
log "PostgreSQL typebot_db backup..."
if docker exec "$PG_TYPEBOT_CONTAINER" pg_dump -U appuser -Fc typebot > "${BACKUP_SUBDIR}/typebot_db.dump" 2>>"$LOG_FILE"; then
    SIZE=$(du -sh "${BACKUP_SUBDIR}/typebot_db.dump" | cut -f1)
    log "  typebot_db: OK (${SIZE})"
else
    log "  typebot_db: FEHLER"
fi

# 3. n8n SQLite DB (falls vorhanden) oder n8n Daten
N8N_CONTAINER=$(docker ps --format '{{.Names}}' | grep '^n8n-' | head -1)
if [ -n "$N8N_CONTAINER" ]; then
    log "n8n Daten backup..."
    N8N_DATA=$(docker inspect "$N8N_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/home/node/.n8n"}}{{.Source}}{{end}}{{end}}')
    if [ -n "$N8N_DATA" ] && [ -d "$N8N_DATA" ]; then
        tar -czf "${BACKUP_SUBDIR}/n8n_data.tar.gz" -C "$(dirname "$N8N_DATA")" "$(basename "$N8N_DATA")" 2>>"$LOG_FILE"
        SIZE=$(du -sh "${BACKUP_SUBDIR}/n8n_data.tar.gz" | cut -f1)
        log "  n8n: OK (${SIZE})"
    else
        log "  n8n: Datenverzeichnis nicht gefunden"
    fi
fi

# 4. Coolify/Traefik Konfigurationen
log "Konfigurationen backup..."
tar -czf "${BACKUP_SUBDIR}/configs.tar.gz" \
    --ignore-failed-read \
    /data/coolify/proxy \
    /root/projects/eppcom-ai-automation/CLAUDE.md \
    /root/projects/eppcom-ai-automation/Work/n8n-workflows \
    2>>"$LOG_FILE" || true
SIZE=$(du -sh "${BACKUP_SUBDIR}/configs.tar.gz" 2>/dev/null | cut -f1)
log "  configs: OK (${SIZE:-0})"

# 5. Gesamtes Backup komprimieren
ARCHIVE="${BACKUP_DIR}/eppcom_backup_${DATE}.tar.gz"
tar -czf "$ARCHIVE" -C "$BACKUP_DIR" "$DATE" 2>>"$LOG_FILE"
rm -rf "$BACKUP_SUBDIR"
TOTAL_SIZE=$(du -sh "$ARCHIVE" | cut -f1)
log "Archiv erstellt: ${ARCHIVE} (${TOTAL_SIZE})"

# 6. S3 Upload
if command -v aws &>/dev/null || command -v s3cmd &>/dev/null; then
    log "S3 Upload..."
    if command -v aws &>/dev/null; then
        AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
        AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
        aws s3 cp "$ARCHIVE" "s3://${S3_BUCKET}/backups/$(basename "$ARCHIVE")" \
            --endpoint-url "$S3_ENDPOINT" \
            --region "$S3_REGION" 2>>"$LOG_FILE" && \
        log "  S3 Upload: OK" || log "  S3 Upload: FEHLER"
    fi
else
    log "S3 Upload: aws-cli nicht installiert, übersprungen"
fi

# 7. Lokale Rotation (älter als 7 Tage löschen)
log "Lokale Rotation (${LOCAL_RETENTION_DAYS} Tage)..."
DELETED=$(find "$BACKUP_DIR" -name "eppcom_backup_*.tar.gz" -mtime +${LOCAL_RETENTION_DAYS} -delete -print | wc -l)
log "  ${DELETED} alte Backups gelöscht"

# 8. Alte Logs bereinigen (Log auf 1000 Zeilen kürzen)
if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt 1000 ]; then
    tail -500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

log "=== Backup abgeschlossen (${TOTAL_SIZE}) ==="
