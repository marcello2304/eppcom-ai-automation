#!/usr/bin/env python3
"""
EPPCOM Token-Synchronisierung
Liest Claude OAuth-Token aus, fragt Usage-API ab und synchronisiert zu code.eppcom.de
"""

import json
import logging
import os
import platform
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import requests
except ImportError:
    print("FEHLER: 'requests' nicht installiert. Führe aus: pip3 install requests")
    sys.exit(1)

# --- Konfiguration ---

# macOS Keychain Service-Name für Claude Code
KEYCHAIN_SERVICE = "Claude Code-credentials"

# Token-Quellen als Fallback (in Prioritätsreihenfolge)
CREDENTIALS_PATHS = [
    Path.home() / ".claude" / ".credentials.json",
    Path.home() / ".claude" / "credentials.json",
    Path.home() / ".config" / "claude" / "credentials.json",
]

# Anthropic Usage API
USAGE_API_URL = "https://api.anthropic.com/api/oauth/usage"
ANTHROPIC_BETA = "oauth-2025-04-20"

# EPPCOM Sync Endpoint
EPPCOM_SYNC_URL = os.environ.get(
    "EPPCOM_SYNC_URL", "https://code.eppcom.de/api/token-usage"
)
EPPCOM_SYNC_API_KEY = os.environ.get("EPPCOM_SYNC_API_KEY", "")

# Logging
LOG_DIR = Path.home() / ".eppcom"
LOG_FILE = LOG_DIR / "token_sync.log"


def setup_logging():
    """Logging konfigurieren – Datei + Konsole."""
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        handlers=[
            logging.FileHandler(LOG_FILE, encoding="utf-8"),
            logging.StreamHandler(sys.stdout),
        ],
    )


def load_token_from_keychain() -> str | None:
    """OAuth-Token aus macOS Keychain laden."""
    if platform.system() != "Darwin":
        return None

    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            logging.debug("Keychain-Eintrag '%s' nicht gefunden", KEYCHAIN_SERVICE)
            return None

        raw = result.stdout.strip()
        data = json.loads(raw)

        # Claude Code speichert unter "claudeAiOauth" ein verschachteltes JSON
        oauth_raw = data.get("claudeAiOauth")
        if oauth_raw:
            # claudeAiOauth kann ein JSON-String sein mit accessToken
            if isinstance(oauth_raw, str):
                try:
                    oauth_data = json.loads(oauth_raw)
                    token = oauth_data.get("accessToken")
                    if token:
                        logging.info("Token aus Keychain geladen (claudeAiOauth.accessToken, %d Zeichen)", len(token))
                        return token
                except json.JSONDecodeError:
                    # Ist direkt der Token-String
                    logging.info("Token aus Keychain geladen (claudeAiOauth, %d Zeichen)", len(oauth_raw))
                    return oauth_raw
            elif isinstance(oauth_raw, dict):
                token = oauth_raw.get("accessToken")
                if token:
                    logging.info("Token aus Keychain geladen (claudeAiOauth.accessToken, %d Zeichen)", len(token))
                    return token

        # Fallback auf andere Felder
        token = data.get("access_token") or data.get("oauth_token")
        if token:
            logging.info("Token aus macOS Keychain geladen (%d Zeichen)", len(token))
            return token

        logging.warning("Keychain-Eintrag gefunden aber kein Token-Feld. Keys: %s", list(data.keys()))
    except subprocess.TimeoutExpired:
        logging.error("Keychain-Abfrage Timeout")
    except (json.JSONDecodeError, ValueError) as e:
        logging.error("Keychain-Daten konnten nicht geparst werden: %s", e)
    except OSError as e:
        logging.error("Keychain-Zugriff fehlgeschlagen: %s", e)

    return None


def load_oauth_token() -> str | None:
    """OAuth-Token laden – Keychain → Umgebungsvariable → Credentials-Datei."""

    # 1. macOS Keychain (automatisch, kein manuelles Eintragen nötig)
    token = load_token_from_keychain()
    if token:
        return token

    # 2. Umgebungsvariable
    env_token = os.environ.get("CLAUDE_OAUTH_TOKEN")
    if env_token:
        logging.info("Token aus Umgebungsvariable CLAUDE_OAUTH_TOKEN geladen")
        return env_token

    # 3. Credentials-Dateien durchsuchen
    for path in CREDENTIALS_PATHS:
        if path.exists():
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                token = (
                    data.get("access_token")
                    or data.get("oauth_token")
                    or data.get("token")
                    or data.get("claudeAiOauth")
                )
                if token:
                    logging.info("Token geladen aus: %s", path)
                    return token

                logging.warning("Datei gefunden aber kein Token-Feld: %s", path)
            except (json.JSONDecodeError, OSError) as e:
                logging.error("Fehler beim Lesen von %s: %s", path, e)

    logging.error(
        "Kein OAuth-Token gefunden. Auf macOS wird automatisch der Keychain geprüft. "
        "Alternativ: CLAUDE_OAUTH_TOKEN setzen oder Credentials-Datei erstellen."
    )
    return None


def fetch_usage(token: str) -> dict | None:
    """Anthropic Usage API abfragen."""
    headers = {
        "Authorization": f"Bearer {token}",
        "anthropic-beta": ANTHROPIC_BETA,
        "Content-Type": "application/json",
    }

    try:
        response = requests.get(USAGE_API_URL, headers=headers, timeout=15)

        if response.status_code == 401:
            logging.error("Token ungültig oder abgelaufen (401)")
            return None

        if response.status_code == 403:
            logging.error("Zugriff verweigert (403) – Token hat keine Usage-Berechtigung")
            return None

        if response.status_code == 429:
            logging.warning("Rate-Limit erreicht (429) – nächster Versuch in 5 Minuten")
            return None

        response.raise_for_status()

        data = response.json()
        logging.info(
            "Usage abgefragt: %.1f%% genutzt, Reset: %s",
            data.get("utilization", 0) * 100,
            data.get("resets_at", "unbekannt"),
        )
        return data

    except requests.exceptions.ConnectionError:
        logging.error("Verbindung zu Anthropic API fehlgeschlagen – Netzwerkproblem?")
    except requests.exceptions.Timeout:
        logging.error("Anthropic API Timeout nach 15s")
    except requests.exceptions.HTTPError as e:
        logging.error("HTTP-Fehler: %s", e)
    except (json.JSONDecodeError, ValueError) as e:
        logging.error("Ungültige API-Antwort: %s", e)

    return None


def sync_to_eppcom(usage_data: dict) -> bool:
    """Usage-Daten an EPPCOM Endpoint senden."""
    if not EPPCOM_SYNC_API_KEY:
        logging.warning(
            "EPPCOM_SYNC_API_KEY nicht gesetzt – Sync zu code.eppcom.de übersprungen"
        )
        return False

    payload = {
        "utilization": usage_data.get("utilization", 0),
        "resets_at": usage_data.get("resets_at", ""),
        "synced_at": datetime.now(timezone.utc).isoformat(),
        "source": "mac-local",
    }

    headers = {
        "Authorization": f"Bearer {EPPCOM_SYNC_API_KEY}",
        "Content-Type": "application/json",
    }

    try:
        response = requests.post(
            EPPCOM_SYNC_URL, json=payload, headers=headers, timeout=10
        )
        response.raise_for_status()
        logging.info("Sync erfolgreich → %s", EPPCOM_SYNC_URL)
        return True

    except requests.exceptions.ConnectionError:
        logging.error("Verbindung zu %s fehlgeschlagen", EPPCOM_SYNC_URL)
    except requests.exceptions.Timeout:
        logging.error("Timeout beim Sync zu %s", EPPCOM_SYNC_URL)
    except requests.exceptions.HTTPError as e:
        logging.error("Sync fehlgeschlagen: %s", e)

    return False


def save_local_cache(usage_data: dict):
    """Usage-Daten lokal cachen (Fallback wenn Sync fehlschlägt)."""
    cache_file = LOG_DIR / "last_usage.json"
    try:
        cache = {
            **usage_data,
            "cached_at": datetime.now(timezone.utc).isoformat(),
        }
        cache_file.write_text(json.dumps(cache, indent=2), encoding="utf-8")
        logging.info("Lokaler Cache aktualisiert: %s", cache_file)
    except OSError as e:
        logging.error("Cache-Datei konnte nicht geschrieben werden: %s", e)


def main():
    setup_logging()
    logging.info("=== EPPCOM Token-Sync gestartet ===")

    # 1. Token laden
    token = load_oauth_token()
    if not token:
        sys.exit(1)

    # 2. Usage abfragen
    usage_data = fetch_usage(token)
    if not usage_data:
        sys.exit(1)

    # 3. Lokal cachen
    save_local_cache(usage_data)

    # 4. An EPPCOM senden
    sync_to_eppcom(usage_data)

    logging.info("=== Token-Sync abgeschlossen ===")


if __name__ == "__main__":
    main()
