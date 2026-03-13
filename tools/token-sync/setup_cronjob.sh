#!/bin/bash
# EPPCOM Token-Sync Setup
# Installiert das Python-Skript und richtet den Cronjob ein

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/sync_tokens.py"
INSTALL_DIR="$HOME/.eppcom"
LOG_FILE="$INSTALL_DIR/token_sync.log"
ENV_FILE="$INSTALL_DIR/.env"

echo "=== EPPCOM Token-Sync Setup ==="
echo ""

# 1. Verzeichnis erstellen
echo "[1/5] Verzeichnis erstellen..."
mkdir -p "$INSTALL_DIR"

# 2. Python prüfen
echo "[2/5] Python prüfen..."
if ! command -v python3 &>/dev/null; then
    echo "FEHLER: python3 nicht gefunden. Bitte installiere Python 3."
    exit 1
fi
PYTHON_VERSION=$(python3 --version 2>&1)
echo "       $PYTHON_VERSION"

# 3. Dependencies installieren
echo "[3/5] Dependencies installieren..."
if python3 -c "import requests" 2>/dev/null; then
    echo "       requests bereits installiert"
else
    echo "       requests installieren..."
    pip3 install --user requests
fi

# 4. Umgebungsvariablen konfigurieren
echo "[4/5] Umgebungsvariablen konfigurieren..."
if [ ! -f "$ENV_FILE" ]; then
    cat > "$ENV_FILE" << 'ENVEOF'
# EPPCOM Token-Sync Konfiguration
# OAuth-Token (falls nicht automatisch erkannt)
# CLAUDE_OAUTH_TOKEN=dein-token-hier

# API-Key für den Sync-Endpoint auf code.eppcom.de
# Generiere einen sicheren Key: python3 -c "import secrets; print(secrets.token_urlsafe(32))"
EPPCOM_SYNC_API_KEY=

# Sync-URL (Standard: https://code.eppcom.de/api/token-usage)
# EPPCOM_SYNC_URL=https://code.eppcom.de/api/token-usage
ENVEOF
    chmod 600 "$ENV_FILE"
    echo "       $ENV_FILE erstellt – bitte API-Key eintragen!"
else
    echo "       $ENV_FILE existiert bereits"
fi

# 5. Cronjob einrichten (alle 5 Minuten)
echo "[5/5] Cronjob einrichten..."

# Wrapper-Skript mit env-Laden erstellen
WRAPPER="$INSTALL_DIR/run_sync.sh"
cat > "$WRAPPER" << WRAPPEREOF
#!/bin/bash
# Lade Umgebungsvariablen
set -a
[ -f "$ENV_FILE" ] && source "$ENV_FILE"
set +a

# Sync ausführen
python3 "$SYNC_SCRIPT" >> "$LOG_FILE" 2>&1
WRAPPEREOF
chmod +x "$WRAPPER"

# Cronjob-Eintrag
CRON_ENTRY="*/5 * * * * $WRAPPER"
CRON_MARKER="# EPPCOM Token-Sync"

# Prüfen ob Cronjob bereits existiert
if crontab -l 2>/dev/null | grep -q "EPPCOM Token-Sync"; then
    echo "       Cronjob existiert bereits – wird aktualisiert"
    crontab -l 2>/dev/null | grep -v "EPPCOM Token-Sync" | grep -v "run_sync.sh" | {
        cat
        echo "$CRON_MARKER"
        echo "$CRON_ENTRY"
    } | crontab -
else
    (crontab -l 2>/dev/null; echo "$CRON_MARKER"; echo "$CRON_ENTRY") | crontab -
fi
echo "       Cronjob eingerichtet (alle 5 Minuten)"

echo ""
echo "=== Setup abgeschlossen ==="
echo ""
echo "Nächste Schritte:"
echo "  1. Token konfigurieren:"
echo "     export CLAUDE_OAUTH_TOKEN='dein-token'"
echo "     oder in $ENV_FILE eintragen"
echo ""
echo "  2. API-Key setzen (in $ENV_FILE):"
echo "     EPPCOM_SYNC_API_KEY=dein-api-key"
echo ""
echo "  3. Manuell testen:"
echo "     python3 $SYNC_SCRIPT"
echo ""
echo "  4. Logs prüfen:"
echo "     tail -f $LOG_FILE"
echo ""
echo "  5. Cronjob prüfen:"
echo "     crontab -l | grep eppcom"
