# EPPCOM Token-Sync – Anleitung

## Übersicht

Synchronisiert Claude Pro Usage-Daten von deinem Mac zu `code.eppcom.de`.

```
Mac (Cronjob alle 5 Min)
  → Claude OAuth Token lesen
  → Anthropic Usage API abfragen
  → Daten an code.eppcom.de/api/token-usage senden
  → Lokaler Cache unter ~/.eppcom/last_usage.json
```

---

## Installation

### 1. Setup ausführen

```bash
cd ~/projects/eppcom-ai-automation/tools/token-sync
chmod +x setup_cronjob.sh
./setup_cronjob.sh
```

### 2. OAuth-Token konfigurieren

**Option A:** Umgebungsvariable (empfohlen)

```bash
# In ~/.eppcom/.env eintragen:
CLAUDE_OAUTH_TOKEN=dein-oauth-token
```

**Option B:** Credentials-Datei

Das Skript sucht automatisch in:
- `~/.claude/.credentials.json`
- `~/.claude/credentials.json`
- `~/.config/claude/credentials.json`

Format:
```json
{
  "access_token": "dein-token-hier"
}
```

### 3. Sync API-Key setzen

Generiere einen sicheren Key:
```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

Trage ihn in `~/.eppcom/.env` ein:
```bash
EPPCOM_SYNC_API_KEY=dein-generierter-key
```

> Derselbe Key muss auf code.eppcom.de im Endpoint `/api/token-usage` konfiguriert werden.

### 4. Testen

```bash
# Manuell ausführen
python3 tools/token-sync/sync_tokens.py

# Logs prüfen
tail -20 ~/.eppcom/token_sync.log

# Lokalen Cache anzeigen
cat ~/.eppcom/last_usage.json | python3 -m json.tool
```

---

## Dateien

| Datei | Zweck |
|---|---|
| `sync_tokens.py` | Hauptskript – Token lesen, API abfragen, synchronisieren |
| `setup_cronjob.sh` | Installation + Cronjob einrichten |
| `~/.eppcom/.env` | Umgebungsvariablen (Token, API-Key) |
| `~/.eppcom/run_sync.sh` | Wrapper für Cronjob (lädt .env) |
| `~/.eppcom/token_sync.log` | Logdatei |
| `~/.eppcom/last_usage.json` | Letzter Usage-Cache |

---

## Umgebungsvariablen

| Variable | Pflicht | Beschreibung |
|---|---|---|
| `CLAUDE_OAUTH_TOKEN` | Ja* | OAuth-Token (*oder Credentials-Datei) |
| `EPPCOM_SYNC_API_KEY` | Nein | API-Key für code.eppcom.de Endpoint |
| `EPPCOM_SYNC_URL` | Nein | Überschreibt Standard-URL |

---

## Troubleshooting

### "Kein OAuth-Token gefunden"
- Prüfe ob `CLAUDE_OAUTH_TOKEN` in `~/.eppcom/.env` gesetzt ist
- Oder erstelle `~/.claude/.credentials.json` mit `{"access_token": "..."}`

### "Token ungültig oder abgelaufen (401)"
- Token ist abgelaufen – erneuere es über Claude Pro Dashboard
- Prüfe ob das Token korrekt kopiert wurde (keine Leerzeichen)

### "Rate-Limit erreicht (429)"
- Warte 5 Minuten – der Cronjob versucht es automatisch erneut
- Falls dauerhaft: Cronjob-Intervall auf 10 Minuten erhöhen

### "Verbindung zu code.eppcom.de fehlgeschlagen"
- Prüfe ob code.eppcom.de erreichbar ist: `curl -sI https://code.eppcom.de`
- Der Endpoint `/api/token-usage` muss noch implementiert werden

### "EPPCOM_SYNC_API_KEY nicht gesetzt"
- Das ist nur eine Warnung – die Usage-Daten werden trotzdem lokal gecacht
- Setze den Key wenn der Endpoint auf code.eppcom.de bereit ist

### Cronjob läuft nicht
```bash
# Cronjob prüfen
crontab -l | grep eppcom

# Manuell testen
bash ~/.eppcom/run_sync.sh

# macOS: Cron-Berechtigung prüfen
# Systemeinstellungen → Datenschutz → Festplattenzugriff → cron erlauben
```

### Daten im Browser debuggen
```bash
# Letzten Cache anzeigen
cat ~/.eppcom/last_usage.json

# Logs der letzten Stunde
grep "$(date '+%Y-%m-%d %H')" ~/.eppcom/token_sync.log

# API-Antwort manuell testen (Token einsetzen)
curl -s https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer DEIN_TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" | python3 -m json.tool
```

---

## Cronjob verwalten

```bash
# Cronjob anzeigen
crontab -l

# Cronjob entfernen
crontab -l | grep -v "EPPCOM" | grep -v "run_sync" | crontab -

# Intervall ändern (z.B. alle 10 Minuten)
# In setup_cronjob.sh: */5 → */10 ändern, dann erneut ausführen
```
