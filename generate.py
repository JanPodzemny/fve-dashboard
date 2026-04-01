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
