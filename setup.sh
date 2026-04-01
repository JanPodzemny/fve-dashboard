#!/bin/bash
# ============================================================
# FVE Dashboard — instalační skript pro LXC kontejner (Debian 12)
# Spusť jako root: bash setup.sh
# ============================================================

set -euo pipefail

APP_DIR="/opt/fve-dashboard"
WEB_DIR="/var/www/html"
CRON_USER="www-data"

echo "=== FVE Dashboard — Setup ==="

# 1. Aktualizace systému a instalace balíčků
echo "[1/7] Instalace balíčků..."
apt-get update
apt-get install -y --no-install-recommends \
    nginx \
    python3 \
    python3-pip \
    python3-venv \
    python3-requests \
    python3-jinja2 \
    curl \
    ca-certificates

# 2. Vytvoření adresářové struktury
echo "[2/7] Vytváření adresářů..."
mkdir -p "$APP_DIR/templates"
mkdir -p "$WEB_DIR"

# 3. Kopírování souborů
echo "[3/7] Kopírování souborů aplikace..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$SCRIPT_DIR/generate.py" "$APP_DIR/generate.py"
cp "$SCRIPT_DIR/templates/dashboard.html" "$APP_DIR/templates/dashboard.html"

# 4. Konfigurace .env
echo "[4/7] Konfigurace..."
if [ ! -f "$APP_DIR/.env" ]; then
    cp "$SCRIPT_DIR/.env.example" "$APP_DIR/.env"
    echo ""
    echo "  !! DŮLEŽITÉ: Uprav $APP_DIR/.env !!"
    echo "  Nastav HA_URL, HA_TOKEN a DEVICE_PREFIX"
    echo ""
else
    echo "  .env již existuje, přeskakuji"
fi

# 5. Nastavení Nginx
echo "[5/7] Konfigurace Nginx..."
cp "$SCRIPT_DIR/nginx-fve.conf" /etc/nginx/sites-available/fve
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/fve /etc/nginx/sites-enabled/fve
nginx -t
systemctl enable nginx
systemctl restart nginx

# 6. Vytvoření wrapper skriptu pro cron (načte .env)
echo "[6/7] Nastavení cronu..."
cat > "$APP_DIR/run.sh" << 'WRAPPER'
#!/bin/bash
set -a
source /opt/fve-dashboard/.env
set +a
/usr/bin/python3 /opt/fve-dashboard/generate.py
WRAPPER
chmod +x "$APP_DIR/run.sh"

# Cron: každých 5 minut
CRON_LINE="*/5 * * * * /opt/fve-dashboard/run.sh >> /var/log/fve-dashboard.log 2>&1"
(crontab -l 2>/dev/null | grep -v "fve-dashboard"; echo "$CRON_LINE") | crontab -

# 7. První spuštění
echo "[7/7] První generování stránky..."
chmod +x "$APP_DIR/generate.py"

if grep -q "TVUJ_DLOUHY_TOKEN_ZDE\|TVUJ_TOKEN_ZDE" "$APP_DIR/.env"; then
    echo ""
    echo "============================================"
    echo "  Setup dokončen!"
    echo ""
    echo "  DALŠÍ KROKY:"
    echo "  1. Uprav $APP_DIR/.env"
    echo "     - Nastav HA_URL (IP adresa tvého HA)"
    echo "     - Nastav HA_TOKEN (Long-Lived Access Token)"
    echo "     - Nastav DEVICE_PREFIX (název zařízení v HA)"
    echo "     - Nastav MAX_POWER (špičkový výkon FVE)"
    echo ""
    echo "  2. Zjisti názvy svých entit:"
    echo "     HA → Developer Tools → States → filtruj 'solarman' nebo 'deye'"
    echo ""
    echo "  3. Spusť ručně pro test:"
    echo "     source $APP_DIR/.env && python3 $APP_DIR/generate.py"
    echo ""
    echo "  4. Ověř stránku:"
    echo "     curl http://localhost"
    echo "============================================"
else
    source "$APP_DIR/.env"
    python3 "$APP_DIR/generate.py" || echo "  Varování: Generování selhalo. Zkontroluj .env"
    echo ""
    echo "  Setup dokončen! Stránka by měla být na http://localhost"
fi
