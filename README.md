# FVE Dashboard

Jednoduchý solární dashboard pro Home Assistant (Deye/Solarman integrace).

Generuje statický HTML s aktuálními daty a grafy z HA REST API, servírovaný přes nginx.

## Funkce
- Aktuální výkon FVE (gauge)
- Denní/celková výroba, export, import
- Grafy: PV stringy, výroba vs spotřeba, baterie SOC (24h)
- Časová osa s proporcionálním rozložením (Chart.js time scale)
- Automatická aktualizace každých 5 minut (cron)

## Instalace na Proxmox

```bash
bash fve-proxmox-install.sh
```

Skript automaticky vytvoří LXC kontejner, nainstaluje závislosti a nasadí dashboard.

## Ruční instalace (v LXC/VM)

1. Nainstaluj závislosti: `apt install nginx python3 python3-requests python3-jinja2`
2. Zkopíruj soubory do `/opt/fve-dashboard/`
3. Zkopíruj `.env.example` → `.env` a uprav
4. Spusť: `bash setup.sh`

## Konfigurace

Uprav `.env` soubor — viz `.env.example` pro popis všech proměnných.
