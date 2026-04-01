#!/bin/bash
# ============================================================
# FVE Dashboard — ALL-IN-ONE Proxmox installer
#
# Spusť tento JEDEN skript v Proxmox shellu jako root:
#   bash fve-proxmox-install.sh
#
# Skript:
#  1. Detekuje storage a šablonu
#  2. Vytvoří LXC kontejner
#  3. Nainstaluje nginx, python, závislosti
#  4. Nasadí FVE dashboard (přes pct push — spolehlivé)
#  5. Nastaví cron
# ============================================================

set -euo pipefail

CT_ID=200
CT_HOSTNAME="fve-web"
CT_MEMORY=256
CT_SWAP=256
CT_CORES=1
CT_DISK_SIZE=2
BRIDGE="vmbr0"
HA_URL="http://192.168.0.104:8123"
HA_TOKEN="TVUJ_TOKEN_ZDE"
DEVICE_PREFIX="Inverter"
MAX_POWER="6000"

STAGING="/tmp/fve-staging"

echo ""
echo "========================================"
echo "  FVE Dashboard — Proxmox Installer"
echo "========================================"
echo ""

# -------------------------------------------------------
# 0. Příprava staging adresáře na hostu
# -------------------------------------------------------
echo "[0/9] Příprava staging souborů..."
rm -rf "$STAGING"
mkdir -p "$STAGING/templates"

# --- generate.py ---
cat > "$STAGING/generate.py" << 'PYEOF'
#!/usr/bin/env python3
"""
FVE Dashboard Generator
Stahuje data z Home Assistant REST API (Deye/Solarman integrace)
a generuje statický index.html.

Spouštěno cronem každých 5 minut.
"""

import json
import logging
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests
from jinja2 import Environment, FileSystemLoader

# ============================================================
# KONFIGURACE — uprav podle svého HA
# ============================================================

# Home Assistant URL (interní IP v Proxmoxu)
HA_URL = os.getenv("HA_URL", "http://192.168.1.100:8123")

# Long-Lived Access Token z HA (Profil → Security → Create Token)
HA_TOKEN = os.getenv("HA_TOKEN", "TVUJ_TOKEN_ZDE")

# Cesta kam se generuje výstupní HTML
OUTPUT_DIR = os.getenv("OUTPUT_DIR", "/var/www/html")

# Mapování entity_id → klíč v šabloně
# !! UPRAV <device> podle názvu tvého zařízení v HA !!
# Zjistíš je v HA → Developer Tools → States → filtruj "solarman" nebo "deye"
#
# Naming pattern Solarman integrace: sensor.<device_name>_<sensor_name>
# Např. pokud se tvůj inverter jmenuje "inverter": sensor.inverter_pv_power
# Pokud "deye": sensor.deye_pv_power
#
# Výchozí prefix: "deye" — změň v DEVICE_PREFIX nebo přes env proměnnou
DEVICE_PREFIX = os.getenv("DEVICE_PREFIX", "deye")

ENTITY_MAP = {
    # Aktuální celkový PV výkon
    "pv_power": os.getenv("ENTITY_PV_POWER", f"sensor.{DEVICE_PREFIX}_pv_power"),
    # Denní výroba
    "daily_production": os.getenv("ENTITY_DAILY_PRODUCTION", f"sensor.{DEVICE_PREFIX}_today_production"),
    # Celková výroba
    "total_production": os.getenv("ENTITY_TOTAL_PRODUCTION", f"sensor.{DEVICE_PREFIX}_total_production"),
    # Napětí DC string 1
    "pv1_voltage": os.getenv("ENTITY_PV1_VOLTAGE", f"sensor.{DEVICE_PREFIX}_pv1_voltage"),
    # Napětí DC string 2
    "pv2_voltage": os.getenv("ENTITY_PV2_VOLTAGE", f"sensor.{DEVICE_PREFIX}_pv2_voltage"),
    # Výkon string 1
    "pv1_power": os.getenv("ENTITY_PV1_POWER", f"sensor.{DEVICE_PREFIX}_pv1_power"),
    # Výkon string 2
    "pv2_power": os.getenv("ENTITY_PV2_POWER", f"sensor.{DEVICE_PREFIX}_pv2_power"),
    # AC výkon (celkový výstup střídače)
    "ac_power": os.getenv("ENTITY_AC_POWER", f"sensor.{DEVICE_PREFIX}_power"),
    "load_power": os.getenv("ENTITY_LOAD_POWER", f"sensor.{DEVICE_PREFIX}_load_power"),
    # AC frekvence sítě
    "ac_frequency": os.getenv("ENTITY_AC_FREQUENCY", f"sensor.{DEVICE_PREFIX}_grid_frequency"),
    # Teplota střídače
    "temperature": os.getenv("ENTITY_TEMPERATURE", f"sensor.{DEVICE_PREFIX}_temperature"),
    # Denní spotřeba
    "daily_consumption": os.getenv("ENTITY_DAILY_CONSUMPTION", f"sensor.{DEVICE_PREFIX}_today_load_consumption"),
    # Grid export dnes
    "daily_export": os.getenv("ENTITY_DAILY_EXPORT", f"sensor.{DEVICE_PREFIX}_today_energy_export"),
    # Grid import dnes
    "daily_import": os.getenv("ENTITY_DAILY_IMPORT", f"sensor.{DEVICE_PREFIX}_today_energy_import"),
    # Baterie SOC (pro hybridní střídače)
    "battery_soc": os.getenv("ENTITY_BATTERY_SOC", f"sensor.{DEVICE_PREFIX}_battery"),
    # Baterie výkon (+ nabíjení, - vybíjení)
    "battery_power": os.getenv("ENTITY_BATTERY_POWER", f"sensor.{DEVICE_PREFIX}_battery_power"),
    # Aktuální výkon ze sítě (grid power)
    "grid_power": os.getenv("ENTITY_GRID_POWER", f"sensor.{DEVICE_PREFIX}_grid_power"),
}

# ============================================================
# LOGGING
# ============================================================

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("fve-dashboard")

# ============================================================
# FUNKCE
# ============================================================


def fetch_entity(entity_id: str) -> dict:
    """Stáhne stav jedné entity z HA REST API."""
    url = f"{HA_URL}/api/states/{entity_id.lower()}"
    headers = {
        "Authorization": f"Bearer {HA_TOKEN}",
        "Content-Type": "application/json",
    }
    try:
        resp = requests.get(url, headers=headers, timeout=10)
        resp.raise_for_status()
        return resp.json()
    except requests.RequestException as e:
        log.warning(f"Nepodařilo se stáhnout {entity_id}: {e}")
        return None


def parse_value(entity_data: dict) -> dict:
    """Extrahuje hodnotu a jednotku z HA entity."""
    if entity_data is None:
        return {"value": "N/A", "unit": "", "raw": None, "available": False}

    state = entity_data.get("state", "unavailable")
    attrs = entity_data.get("attributes", {})
    unit = attrs.get("unit_of_measurement", "")
    friendly_name = attrs.get("friendly_name", "")

    if state in ("unavailable", "unknown", None):
        return {
            "value": "---",
            "unit": unit,
            "raw": None,
            "available": False,
            "name": friendly_name,
        }

    try:
        numeric = float(state)
        if numeric == int(numeric) and abs(numeric) < 100000:
            formatted = str(int(numeric))
        else:
            formatted = f"{numeric:.1f}"
        return {
            "value": formatted,
            "unit": unit,
            "raw": numeric,
            "available": True,
            "name": friendly_name,
        }
    except (ValueError, TypeError):
        return {
            "value": state,
            "unit": unit,
            "raw": state,
            "available": True,
            "name": friendly_name,
        }


def fetch_history(entity_ids: list, hours: int = 24) -> dict:
    if not entity_ids:
        return {}

    end_time = datetime.now(timezone.utc)
    start_time = end_time - timedelta(hours=hours)
    start_iso = start_time.isoformat().replace("+00:00", "Z")
    end_iso = end_time.isoformat().replace("+00:00", "Z")

    filter_ids = ",".join(entity_ids)
    url = (
        f"{HA_URL}/api/history/period/{start_iso}"
        f"?end_time={end_iso}&filter_entity_id={filter_ids}&minimal_response&no_attributes"
    )
    headers = {
        "Authorization": f"Bearer {HA_TOKEN}",
        "Content-Type": "application/json",
    }

    try:
        resp = requests.get(url, headers=headers, timeout=15)
        resp.raise_for_status()
        raw_history = resp.json()
    except requests.RequestException as e:
        log.warning(f"Nepodařilo se stáhnout historii: {e}")
        return {}
    except ValueError as e:
        log.warning(f"Neplatná odpověď historie z HA: {e}")
        return {}

    # Debug: struktura odpovědi
    if isinstance(raw_history, list):
        log.info(f"  History API: {len(raw_history)} sérií")
        for idx, series in enumerate(raw_history):
            if isinstance(series, list) and len(series) > 0:
                first = series[0] if isinstance(series[0], dict) else {}
                log.info(f"    Série {idx}: {len(series)} záznamů, klíče={list(first.keys())}, první={first}")
            else:
                log.info(f"    Série {idx}: typ={type(series).__name__}, len={len(series) if isinstance(series, list) else 'N/A'}")
    else:
        log.warning(f"  History API: neočekávaný typ odpovědi: {type(raw_history).__name__}")

    entity_ids_lower = {eid.lower(): eid for eid in entity_ids}
    history = {entity_id: [] for entity_id in entity_ids}

    for idx, series in enumerate(raw_history if isinstance(raw_history, list) else []):
        if not isinstance(series, list):
            continue

        raw_eid = None
        if series and isinstance(series[0], dict):
            raw_eid = series[0].get("entity_id")

        if raw_eid:
            entity_id = entity_ids_lower.get(raw_eid.lower(), raw_eid)
        elif idx < len(entity_ids):
            entity_id = entity_ids[idx]
        else:
            continue

        points = []
        for entry in series:
            if not isinstance(entry, dict):
                continue
            state = entry.get("state") or entry.get("s")
            if state in ("unavailable", "unknown", None):
                continue

            try:
                value = float(state)
            except (ValueError, TypeError):
                continue

            changed_raw = (
                entry.get("last_changed")
                or entry.get("last_updated")
                or entry.get("lu")
                or entry.get("lc")
            )
            if not changed_raw:
                continue

            try:
                changed_dt = datetime.fromisoformat(changed_raw.replace("Z", "+00:00"))
            except ValueError:
                continue

            points.append({"time": changed_dt.isoformat(), "value": value})

        history[entity_id] = points

    return history


def fetch_all_data() -> dict:
    """Stáhne všechny entity a vrátí slovník pro šablonu."""
    data = {}
    for key, entity_id in ENTITY_MAP.items():
        raw = fetch_entity(entity_id)
        data[key] = parse_value(raw)
        if data[key]["available"]:
            log.info(f"  {key}: {data[key]['value']} {data[key]['unit']}")
        else:
            log.info(f"  {key}: nedostupné ({entity_id})")

    # Metadata
    data["last_update"] = datetime.now().strftime("%d.%m.%Y %H:%M:%S")
    data["ha_url"] = HA_URL

    load_power_entity = ENTITY_MAP["load_power"]
    history_entities = [
        ENTITY_MAP["pv1_power"],
        ENTITY_MAP["pv2_power"],
        ENTITY_MAP["ac_power"],
        load_power_entity,
        ENTITY_MAP["battery_soc"],
    ]
    history = fetch_history(history_entities, hours=24)
    data["history_pv1"] = json.dumps(history.get(ENTITY_MAP["pv1_power"], []))
    data["history_pv2"] = json.dumps(history.get(ENTITY_MAP["pv2_power"], []))
    data["history_production"] = json.dumps(history.get(ENTITY_MAP["ac_power"], []))
    data["history_consumption"] = json.dumps(history.get(load_power_entity, []))
    data["history_battery"] = json.dumps(history.get(ENTITY_MAP["battery_soc"], []))

    # Vypočítané hodnoty
    pv1 = data.get("pv1_power", {}).get("raw")
    pv2 = data.get("pv2_power", {}).get("raw")
    if pv1 is not None and pv2 is not None:
        total_pv = pv1 + pv2
        data["total_pv_power"] = {
            "value": str(int(total_pv)),
            "unit": "W",
            "raw": total_pv,
            "available": True,
        }
    else:
        data["total_pv_power"] = data.get("pv_power", {"value": "---", "unit": "W", "available": False})

    # Maximální výkon pro gauge (nastav podle svého systému)
    data["max_power"] = int(os.getenv("MAX_POWER", "6000"))  # W
    data["max_grid_power"] = int(os.getenv("MAX_GRID_POWER", "6000"))  # W

    grid_raw = data.get("grid_power", {}).get("raw")
    if grid_raw is not None:
        grid_pct = min(abs(grid_raw) / data["max_grid_power"] * 100, 100)
    else:
        grid_pct = 0
    data["grid_power_pct"] = round(grid_pct, 1)

    return data


def render_html(data: dict) -> str:
    """Vyrenderuje HTML šablonu s daty."""
    template_dir = Path(__file__).parent / "templates"
    env = Environment(loader=FileSystemLoader(str(template_dir)))
    template = env.get_template("dashboard.html")
    return template.render(**data)


def main():
    log.info("=== FVE Dashboard Generator ===")
    log.info(f"HA URL: {HA_URL}")
    log.info("Stahuji data z Home Assistant...")

    data = fetch_all_data()

    log.info("Generuji HTML...")
    html = render_html(data)

    output_path = Path(OUTPUT_DIR) / "index.html"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(html, encoding="utf-8")

    log.info(f"Hotovo! Výstup: {output_path}")
    log.info(f"Velikost: {len(html)} bytes")


if __name__ == "__main__":
    main()
PYEOF

# --- dashboard.html ---
cat > "$STAGING/templates/dashboard.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="cs">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="refresh" content="300">
    <title>Solární Elektrárna</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns@3/dist/chartjs-adapter-date-fns.bundle.min.js"></script>
    <style>
        :root {
            /* Colors */
            --bg-body: #0f172a;
            --bg-card: rgba(30, 41, 59, 0.4);
            --bg-card-hover: rgba(51, 65, 85, 0.5);
            --border-card: rgba(148, 163, 184, 0.1);
            
            --text-primary: #f8fafc;
            --text-secondary: #94a3b8;
            --text-muted: #64748b;

            --color-solar: #fbbf24; /* Amber 400 */
            --color-production: #34d399; /* Emerald 400 */
            --color-grid: #60a5fa; /* Blue 400 */
            --color-import: #f87171; /* Red 400 */
            --color-battery: #a78bfa; /* Violet 400 */

            /* Spacing */
            --space-xs: 0.25rem;
            --space-sm: 0.5rem;
            --space-md: 1rem;
            --space-lg: 1.5rem;
            --space-xl: 2rem;

            /* Radii */
            --radius-lg: 1rem;
            --radius-full: 9999px;

            /* Transitions */
            --transition-base: 0.3s cubic-bezier(0.4, 0, 0.2, 1);
        }

        /* Reset */
        *, *::before, *::after {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }

        body {
            background-color: var(--bg-body);
            color: var(--text-primary);
            font-family: system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            line-height: 1.5;
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            padding: var(--space-md);
            background-image: 
                radial-gradient(circle at 50% 0%, rgba(56, 189, 248, 0.1) 0%, transparent 50%),
                linear-gradient(rgba(15, 23, 42, 0.95), rgba(15, 23, 42, 0.95)),
                url("data:image/svg+xml,%3Csvg width='60' height='60' viewBox='0 0 60 60' xmlns='http://www.w3.org/2000/svg'%3E%3Cg fill='none' fill-rule='evenodd'%3E%3Cg fill='%231e293b' fill-opacity='0.4'%3E%3Cpath d='M36 34v-4h-2v4h-4v2h4v4h2v-4h4v-2h-4zm0-30V0h-2v4h-4v2h4v4h2V6h4V4h-4zM6 34v-4H4v4H0v2h4v4h2v-4h4v-2H6zM6 4V0H4v4H0v2h4v4h2V6h4V4H6z'/%3E%3C/g%3E%3C/g%3E%3C/svg%3E");
        }

        .container {
            width: 100%;
            max-width: 1200px;
            margin: 0 auto;
            flex: 1;
            display: flex;
            flex-direction: column;
            gap: var(--space-xl);
        }

        .text-solar { color: var(--color-solar); }
        .text-prod { color: var(--color-production); }
        .text-grid { color: var(--color-grid); }
        .text-import { color: var(--color-import); }
        .text-batt { color: var(--color-battery); }
        
        header {
            text-align: center;
            padding-bottom: var(--space-md);
            border-bottom: 1px solid var(--border-card);
            margin-bottom: var(--space-lg);
        }

        h1 {
            font-size: clamp(1.5rem, 4vw, 2.5rem);
            font-weight: 800;
            letter-spacing: -0.025em;
            background: linear-gradient(to right, #fff, #94a3b8);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            margin-bottom: var(--space-xs);
        }

        .subtitle {
            font-size: 0.875rem;
            color: var(--text-secondary);
            font-variant-numeric: tabular-nums;
        }

        .hero {
            display: flex;
            justify-content: center;
            align-items: center;
            position: relative;
            padding: var(--space-lg) 0;
            gap: var(--space-xl);
            flex-wrap: wrap;
        }

        .gauge-container { position: relative; width: 250px; height: 250px; }
        @media (min-width: 768px) { .gauge-container { width: 280px; height: 280px; } }
        .gauge-svg { transform: rotate(-90deg); width: 100%; height: 100%; }
        .gauge-bg { fill: none; stroke: var(--bg-card); stroke-width: 8; }
        .gauge-fill { fill: none; stroke: var(--color-solar); stroke-width: 8; stroke-linecap: round; stroke-dasharray: 753; stroke-dashoffset: 753; transition: stroke-dashoffset 1.5s cubic-bezier(0.4, 0, 0.2, 1); filter: drop-shadow(0 0 8px rgba(251, 191, 36, 0.3)); }
        .gauge-fill-grid { fill: none; stroke: var(--color-import); stroke-width: 8; stroke-linecap: round; stroke-dasharray: 753; stroke-dashoffset: 753; transition: stroke-dashoffset 1.5s cubic-bezier(0.4, 0, 0.2, 1); filter: drop-shadow(0 0 8px rgba(248, 113, 113, 0.3)); }
        .gauge-content { position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%); text-align: center; display: flex; flex-direction: column; align-items: center; }
        .current-power-value { font-size: 3.5rem; font-weight: 700; line-height: 1; letter-spacing: -0.05em; color: var(--text-primary); font-variant-numeric: tabular-nums; text-shadow: 0 0 20px rgba(251, 191, 36, 0.2); }
        .current-power-unit { font-size: 1.25rem; color: var(--text-secondary); font-weight: 500; margin-top: var(--space-xs); }
        .current-power-label { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.1em; color: var(--text-muted); margin-top: var(--space-sm); }

        .stats-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: var(--space-md); }
        @media (min-width: 768px) { .stats-grid { grid-template-columns: repeat(4, 1fr); } }

        .card { background: var(--bg-card); backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px); border: 1px solid var(--border-card); border-radius: var(--radius-lg); padding: var(--space-lg); display: flex; flex-direction: column; position: relative; overflow: hidden; transition: var(--transition-base); }
        .card:hover { background: var(--bg-card-hover); transform: translateY(-2px); box-shadow: 0 10px 30px -10px rgba(0, 0, 0, 0.5); }
        .card::before { content: ''; position: absolute; left: 0; top: 0; bottom: 0; width: 4px; background: var(--accent-color, var(--text-muted)); }
        .card-icon { font-size: 1.5rem; margin-bottom: var(--space-sm); opacity: 0.8; }
        .card-label { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; color: var(--text-secondary); margin-bottom: var(--space-xs); }
        .card-value { font-size: 1.5rem; font-weight: 600; color: var(--text-primary); font-variant-numeric: tabular-nums; }
        .card-unit { font-size: 0.875rem; color: var(--text-muted); margin-left: 2px; }

        .details-grid { display: grid; grid-template-columns: 1fr; gap: var(--space-md); }
        @media (min-width: 768px) { .details-grid { grid-template-columns: 1fr 1fr; } }
        .detail-row { display: flex; justify-content: space-between; padding: var(--space-sm) 0; border-bottom: 1px solid var(--border-card); }
        .detail-row:last-child { border-bottom: none; }
        .detail-label { color: var(--text-secondary); font-size: 0.875rem; }
        .detail-value { color: var(--text-primary); font-weight: 500; font-variant-numeric: tabular-nums; }
        .chart-section { margin-top: var(--space-md); }
        .battery-section { margin-top: var(--space-md); }
        .battery-viz { display: flex; align-items: center; gap: var(--space-md); margin-top: var(--space-md); }
        .battery-bar-container { flex: 1; height: 12px; background: rgba(0,0,0,0.3); border-radius: var(--radius-full); overflow: hidden; position: relative; }
        .battery-bar-fill { height: 100%; background: var(--color-battery); border-radius: var(--radius-full); transition: width 1s ease-out; box-shadow: 0 0 10px rgba(167, 139, 250, 0.4); }

        footer { margin-top: auto; text-align: center; padding-top: var(--space-xl); color: var(--text-muted); font-size: 0.75rem; }
        .footer-logo { display: inline-flex; align-items: center; gap: 6px; opacity: 0.6; }

        @keyframes fadeIn { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: translateY(0); } }
        .animate-in { animation: fadeIn 0.6s ease-out forwards; opacity: 0; }
        .delay-1 { animation-delay: 0.1s; }
        .delay-2 { animation-delay: 0.2s; }
        .delay-3 { animation-delay: 0.3s; }
        .delay-4 { animation-delay: 0.4s; }
    </style>
</head>
<body>
    <div class="container">
        <header class="animate-in">
            <h1>Solární Elektrárna</h1>
            <div class="subtitle">Poslední aktualizace: {{ last_update }}</div>
        </header>

        <section class="hero animate-in delay-1">
            <div class="gauge-container">
                <svg class="gauge-svg" viewBox="0 0 250 250">
                    <circle class="gauge-bg" cx="125" cy="125" r="120"></circle>
                    <circle class="gauge-fill" cx="125" cy="125" r="120"
                            style="stroke-dashoffset: calc(753 - (753 * {{ ((total_pv_power.raw or 0) / max_power * 100) | round(1) }} / 100));"></circle>
                </svg>
                <div class="gauge-content">
                    <div class="current-power-value">{{ total_pv_power.value }}</div>
                    <div class="current-power-unit">{{ total_pv_power.unit }}</div>
                    <div class="current-power-label">Aktuální výkon</div>
                </div>
            </div>
            <div class="gauge-container">
                <svg class="gauge-svg" viewBox="0 0 250 250">
                    <circle class="gauge-bg" cx="125" cy="125" r="120"></circle>
                    <circle class="gauge-fill-grid" cx="125" cy="125" r="120"
                            style="stroke-dashoffset: calc(753 - (753 * {{ grid_power_pct }} / 100));"></circle>
                </svg>
                <div class="gauge-content">
                    <div class="current-power-value">{{ grid_power.value }}</div>
                    <div class="current-power-unit">{{ grid_power.unit }}</div>
                    <div class="current-power-label">Nákup ze sítě</div>
                </div>
            </div>
        </section>

        <section class="stats-grid animate-in delay-2">
            <div class="card" style="--accent-color: var(--color-production);"><div class="card-icon text-prod">☀️</div><div class="card-label">Výroba dnes</div><div><span class="card-value">{{ daily_production.value }}</span><span class="card-unit">{{ daily_production.unit }}</span></div></div>
            <div class="card" style="--accent-color: var(--color-solar);"><div class="card-icon text-solar">⚡</div><div class="card-label">Celková výroba</div><div><span class="card-value">{{ total_production.value }}</span><span class="card-unit">{{ total_production.unit }}</span></div></div>
            <div class="card" style="--accent-color: var(--color-grid);"><div class="card-icon text-grid">💰</div><div class="card-label">Prodej dnes</div><div><span class="card-value">{{ daily_export.value }}</span><span class="card-unit">{{ daily_export.unit }}</span></div></div>
            <div class="card" style="--accent-color: var(--color-import);"><div class="card-icon text-import">🔌</div><div class="card-label">Nákup dnes</div><div><span class="card-value">{{ daily_import.value }}</span><span class="card-unit">{{ daily_import.unit }}</span></div></div>
        </section>

        <section class="details-grid animate-in delay-3">
            <div class="card" style="--accent-color: var(--color-solar);"><div class="card-label" style="margin-bottom: var(--space-md);">DC Stringy</div><div class="detail-row"><span class="detail-label">String 1 (Výkon/Napětí)</span><span class="detail-value text-solar">{{ pv1_power.value }} W / {{ pv1_voltage.value }} V</span></div><div class="detail-row"><span class="detail-label">String 2 (Výkon/Napětí)</span><span class="detail-value text-solar">{{ pv2_power.value }} W / {{ pv2_voltage.value }} V</span></div></div>
            <div class="card" style="--accent-color: var(--color-grid);"><div class="card-label" style="margin-bottom: var(--space-md);">Stav sítě & Měniče</div><div class="detail-row"><span class="detail-label">AC Výkon</span><span class="detail-value text-grid">{{ ac_power.value }} {{ ac_power.unit }}</span></div><div class="detail-row"><span class="detail-label">Frekvence sítě</span><span class="detail-value">{{ ac_frequency.value }} {{ ac_frequency.unit }}</span></div><div class="detail-row"><span class="detail-label">Teplota měniče</span><span class="detail-value">{{ temperature.value }} {{ temperature.unit }}</span></div></div>
        </section>

        <section class="card chart-section animate-in delay-3" style="--accent-color: var(--color-solar);"><div class="card-label" style="margin-bottom: var(--space-md);">Výkon stringů (24h)</div><div style="position: relative; height: 250px;"><canvas id="chartPvStrings"></canvas></div></section>
        <section class="card chart-section animate-in delay-3" style="--accent-color: var(--color-grid);"><div class="card-label" style="margin-bottom: var(--space-md);">Výroba vs Spotřeba (24h)</div><div style="position: relative; height: 250px;"><canvas id="chartProductionConsumption"></canvas></div></section>

        {% if battery_soc.available %}
        <section class="card chart-section animate-in delay-4" style="--accent-color: var(--color-battery);"><div class="card-label" style="margin-bottom: var(--space-md);">Stav baterie (24h)</div><div style="position: relative; height: 250px;"><canvas id="chartBatterySoc"></canvas></div></section>
        {% endif %}

        {% if battery_soc.available %}
        <section class="card battery-section animate-in delay-4" style="--accent-color: var(--color-battery);"><div class="card-label">Bateriové úložiště</div><div class="battery-viz"><div class="card-icon text-batt">🔋</div><div class="battery-bar-container"><div class="battery-bar-fill" style="width: {{ battery_soc.value }}%;"></div></div><div style="text-align: right; min-width: 80px;"><div class="card-value">{{ battery_soc.value }}%</div><div class="detail-label" style="font-size: 0.7rem;">{{ battery_power.value }} {{ battery_power.unit }}</div></div></div></section>
        {% endif %}

        <footer class="animate-in delay-4"><div class="footer-logo"><span>Aktualizováno: {{ last_update }}</span><span>•</span><span>Powered by Home Assistant</span></div></footer>
    </div>

    <script type="application/json" id="history-pv1">{{ history_pv1 | safe }}</script>
    <script type="application/json" id="history-pv2">{{ history_pv2 | safe }}</script>
    <script type="application/json" id="history-production">{{ history_production | safe }}</script>
    <script type="application/json" id="history-consumption">{{ history_consumption | safe }}</script>
    <script type="application/json" id="history-battery">{{ history_battery | safe }}</script>
    <script>
        document.addEventListener('DOMContentLoaded', () => {
            const historyPv1 = JSON.parse(document.getElementById('history-pv1')?.textContent || '[]');
            const historyPv2 = JSON.parse(document.getElementById('history-pv2')?.textContent || '[]');
            const historyProduction = JSON.parse(document.getElementById('history-production')?.textContent || '[]');
            const historyConsumption = JSON.parse(document.getElementById('history-consumption')?.textContent || '[]');
            const historyBattery = JSON.parse(document.getElementById('history-battery')?.textContent || '[]');
            const toXY = (points) => points.map((p) => ({ x: new Date(p.time), y: p.value }));
            Chart.defaults.color = '#94a3b8';
            Chart.defaults.borderColor = 'rgba(148, 163, 184, 0.1)';
            const tooltipDefaults = { backgroundColor: '#1e293b', borderColor: 'rgba(148, 163, 184, 0.2)', borderWidth: 1, titleColor: '#f8fafc', bodyColor: '#cbd5e1', displayColors: true };
            const axisGridColor = 'rgba(148, 163, 184, 0.08)';
            const timeScaleX = { type: 'time', time: { unit: 'hour', displayFormats: { hour: 'HH:mm', minute: 'HH:mm' }, tooltipFormat: 'HH:mm' }, ticks: { maxTicksLimit: 12, autoSkip: true }, grid: { color: axisGridColor } };
            const baseLineOptions = { responsive: true, maintainAspectRatio: false, interaction: { mode: 'nearest', axis: 'x', intersect: false }, plugins: { legend: { labels: { usePointStyle: true, pointStyle: 'circle' } }, tooltip: tooltipDefaults }, scales: { x: timeScaleX, y: { grid: { color: axisGridColor }, beginAtZero: true } } };
            const ctxPv = document.getElementById('chartPvStrings');
            if (ctxPv) { new Chart(ctxPv, { type: 'line', data: { datasets: [{ label: 'PV1', data: toXY(historyPv1), borderColor: '#fbbf24', backgroundColor: 'rgba(251, 191, 36, 0.1)', tension: 0.3, borderWidth: 2, fill: false, pointRadius: 0, pointHoverRadius: 4 }, { label: 'PV2', data: toXY(historyPv2), borderColor: '#34d399', backgroundColor: 'rgba(52, 211, 153, 0.1)', tension: 0.3, borderWidth: 2, fill: false, pointRadius: 0, pointHoverRadius: 4 }] }, options: { ...baseLineOptions, scales: { ...baseLineOptions.scales, y: { ...baseLineOptions.scales.y, title: { display: true, text: 'W' } } } } }); }
            const ctxProdCons = document.getElementById('chartProductionConsumption');
            if (ctxProdCons) { new Chart(ctxProdCons, { type: 'line', data: { datasets: [{ label: 'Výroba', data: toXY(historyProduction), borderColor: '#60a5fa', backgroundColor: 'rgba(96, 165, 250, 0.1)', tension: 0.3, borderWidth: 2, fill: true, pointRadius: 0, pointHoverRadius: 4 }, { label: 'Spotřeba', data: toXY(historyConsumption), borderColor: '#f87171', backgroundColor: 'rgba(248, 113, 113, 0.1)', tension: 0.3, borderWidth: 2, fill: true, pointRadius: 0, pointHoverRadius: 4 }] }, options: { ...baseLineOptions, scales: { ...baseLineOptions.scales, y: { ...baseLineOptions.scales.y, title: { display: true, text: 'W' } } } } }); }
            const ctxBattery = document.getElementById('chartBatterySoc');
            if (ctxBattery && historyBattery.length > 0) { new Chart(ctxBattery, { type: 'line', data: { datasets: [{ label: 'SOC', data: toXY(historyBattery), borderColor: '#a78bfa', backgroundColor: 'rgba(167, 139, 250, 0.1)', tension: 0.3, borderWidth: 2, fill: true, pointRadius: 0, pointHoverRadius: 4 }] }, options: { ...baseLineOptions, scales: { ...baseLineOptions.scales, y: { ...baseLineOptions.scales.y, min: 0, max: 100, ticks: { callback: (value) => `${value}%` } } } } }); }
        });
    </script>
</body>
</html>
HTMLEOF

# --- .env ---
cat > "$STAGING/dot-env" << ENVEOF
HA_URL=${HA_URL}
HA_TOKEN=${HA_TOKEN}
DEVICE_PREFIX=${DEVICE_PREFIX}
OUTPUT_DIR=/var/www/html
MAX_POWER=${MAX_POWER}
ENVEOF

# --- run.sh ---
cat > "$STAGING/run.sh" << 'RUNEOF'
#!/bin/bash
set -a
source /opt/fve-dashboard/.env
set +a
/usr/bin/python3 /opt/fve-dashboard/generate.py
RUNEOF
chmod +x "$STAGING/run.sh"

# --- nginx config ---
cat > "$STAGING/nginx-fve" << 'NGXEOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.html;
    server_name _;
    location / { try_files $uri $uri/ =404; }
    location = /index.html { add_header Cache-Control "public, max-age=300"; }
    location ~ /\. { deny all; }
    location = /health { return 200 "OK"; add_header Content-Type text/plain; }
}
NGXEOF

echo "  Staging soubory připraveny v $STAGING"

# -------------------------------------------------------
# 1. Detekce storage
# -------------------------------------------------------
echo "[1/9] Detekce storage..."
STORAGE=""
for s in local-lvm local-zfs local; do
    if pvesm status | grep -q "^${s}\s"; then
        STORAGE="$s"
        break
    fi
done

if [ -z "$STORAGE" ]; then
    echo "CHYBA: Nepodařilo se najít storage. Dostupné:"
    pvesm status
    exit 1
fi
echo "  Nalezen storage: $STORAGE"

# -------------------------------------------------------
# 2. Stažení šablony (pokud chybí)
# -------------------------------------------------------
echo "[2/9] Kontrola Debian 12 šablony..."
TEMPLATE=$(pveam list local 2>/dev/null | grep "debian-12-standard" | tail -1 | awk '{print $1}') || true

if [ -z "$TEMPLATE" ]; then
    echo "  Šablona nenalezena lokálně, stahuji..."
    pveam update || echo "  Varování: pveam update selhal"
    TEMPLATE_NAME=$(pveam available --section system | grep "debian-12-standard" | tail -1 | awk '{print $2}') || true
    if [ -z "$TEMPLATE_NAME" ]; then
        echo "CHYBA: Debian 12 šablona není dostupná."
        exit 1
    fi
    echo "  Stahuji: $TEMPLATE_NAME ..."
    pveam download local "$TEMPLATE_NAME"
    TEMPLATE="local:vztmpl/${TEMPLATE_NAME}"
else
    echo "  Nalezena: $TEMPLATE"
fi

# -------------------------------------------------------
# 3. Kontrola CT ID
# -------------------------------------------------------
echo "[3/9] Kontrola CT ID $CT_ID..."
if pct status "$CT_ID" &>/dev/null; then
    echo "CHYBA: Kontejner $CT_ID již existuje!"
    echo "Pro smazání: pct stop $CT_ID && pct destroy $CT_ID"
    exit 1
fi
echo "  ID $CT_ID je volné"

# -------------------------------------------------------
# 4. Vytvoření kontejneru
# -------------------------------------------------------
echo "[4/9] Vytváření LXC kontejneru..."
pct create "$CT_ID" "$TEMPLATE" \
    --hostname "$CT_HOSTNAME" \
    --memory "$CT_MEMORY" \
    --swap "$CT_SWAP" \
    --cores "$CT_CORES" \
    --rootfs "${STORAGE}:${CT_DISK_SIZE}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged 1 \
    --features nesting=1 \
    --start 1

echo "  Kontejner vytvořen a spuštěn"
echo "  Čekám na start..."
sleep 5

# -------------------------------------------------------
# 5. Instalace balíčků uvnitř LXC
# -------------------------------------------------------
echo "[5/9] Instalace balíčků v kontejneru..."
pct exec "$CT_ID" -- bash -c "apt-get update -qq && apt-get install -y --no-install-recommends nginx python3 python3-requests python3-jinja2 curl ca-certificates"
echo "  Balíčky nainstalovány"

# -------------------------------------------------------
# 6. Vytvoření adresářové struktury v kontejneru
# -------------------------------------------------------
echo "[6/9] Vytváření adresářů v kontejneru..."
pct exec "$CT_ID" -- bash -c "mkdir -p /opt/fve-dashboard/templates && mkdir -p /var/www/html && echo OK"
echo "  Adresáře vytvořeny"

# -------------------------------------------------------
# 7. Kopírování souborů přes pct push
# -------------------------------------------------------
echo "[7/9] Kopírování souborů do kontejneru (pct push)..."

pct push "$CT_ID" "$STAGING/generate.py"              /opt/fve-dashboard/generate.py
echo "  -> generate.py"

pct push "$CT_ID" "$STAGING/templates/dashboard.html"  /opt/fve-dashboard/templates/dashboard.html
echo "  -> templates/dashboard.html"

pct push "$CT_ID" "$STAGING/dot-env"                   /opt/fve-dashboard/.env
echo "  -> .env"

pct push "$CT_ID" "$STAGING/run.sh"                    /opt/fve-dashboard/run.sh
pct exec "$CT_ID" -- chmod +x /opt/fve-dashboard/run.sh
echo "  -> run.sh"

pct push "$CT_ID" "$STAGING/nginx-fve"                 /etc/nginx/sites-available/fve
echo "  -> nginx config"

echo "  Všechny soubory zkopírovány"

# -------------------------------------------------------
# 8. Nginx konfigurace
# -------------------------------------------------------
echo "[8/9] Konfigurace Nginx..."
pct exec "$CT_ID" -- bash -c "rm -f /etc/nginx/sites-enabled/default && ln -sf /etc/nginx/sites-available/fve /etc/nginx/sites-enabled/fve && nginx -t && systemctl restart nginx && systemctl enable nginx"
echo "  Nginx nakonfigurován a spuštěn"

# -------------------------------------------------------
# 9. Cron
# -------------------------------------------------------
echo "[9/9] Nastavení cronu..."
pct exec "$CT_ID" -- bash -c 'echo "*/5 * * * * /opt/fve-dashboard/run.sh >> /var/log/fve-dashboard.log 2>&1" | crontab -'
echo "  Cron nastaven (každých 5 minut)"

# -------------------------------------------------------
# Úklid staging
# -------------------------------------------------------
rm -rf "$STAGING"

# -------------------------------------------------------
# Hotovo!
# -------------------------------------------------------
CT_IP=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}') || true

echo ""
echo "========================================"
echo "  HOTOVO!"
echo "========================================"
echo ""
echo "  Kontejner: $CT_ID ($CT_HOSTNAME)"
echo "  IP adresa: ${CT_IP:-'zjisti: pct exec $CT_ID -- hostname -I'}"
echo ""
echo "  TESTOVÁNÍ:"
echo "    pct exec $CT_ID -- /opt/fve-dashboard/run.sh"
echo "    Otevři: http://${CT_IP:-<IP>}"
echo ""
echo "  KONFIGURACE (pokud potřebuješ změnit):"
echo "    pct exec $CT_ID -- nano /opt/fve-dashboard/.env"
echo ""
echo "  PRO PŘÍSTUP Z INTERNETU (Cloudflare Tunnel):"
echo "    pct exec $CT_ID -- bash"
echo "    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cf.deb && dpkg -i /tmp/cf.deb"
echo "    cloudflared tunnel login"
echo "    cloudflared tunnel create fve-dashboard"
echo "    cloudflared tunnel route dns fve-dashboard fve.tvojedomena.cz"
echo ""
