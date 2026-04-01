#!/bin/bash
# ============================================================
# FVE Dashboard — Cloudflare Tunnel setup
# Spusť jako root po dokončení setup.sh
# ============================================================

set -euo pipefail

echo "=== Cloudflare Tunnel — Setup ==="

# 1. Instalace cloudflared
echo "[1/5] Instalace cloudflared..."
if ! command -v cloudflared &> /dev/null; then
    # Detekce architektury
    ARCH=$(dpkg --print-architecture)
    case "$ARCH" in
        amd64) CF_ARCH="amd64" ;;
        arm64) CF_ARCH="arm64" ;;
        armhf) CF_ARCH="arm" ;;
        *) echo "Nepodporovaná architektura: $ARCH"; exit 1 ;;
    esac
    
    curl -L "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}.deb" \
        -o /tmp/cloudflared.deb
    dpkg -i /tmp/cloudflared.deb
    rm /tmp/cloudflared.deb
    echo "  cloudflared nainstalován"
else
    echo "  cloudflared již nainstalován: $(cloudflared --version)"
fi

echo ""
echo "=== Další kroky (ruční) ==="
echo ""
echo "2. Přihlášení do Cloudflare:"
echo "   cloudflared tunnel login"
echo "   (otevře se URL — přihlas se a vyber doménu)"
echo ""
echo "3. Vytvoření tunnelu:"
echo "   cloudflared tunnel create fve-dashboard"
echo "   (zapiš si TUNNEL_ID z výstupu)"
echo ""
echo "4. Konfigurace tunnelu:"
echo "   Vytvoř /etc/cloudflared/config.yml:"
echo ""
echo "   tunnel: <TUNNEL_ID>"
echo "   credentials-file: /root/.cloudflared/<TUNNEL_ID>.json"
echo "   ingress:"
echo "     - hostname: fve.tvojedomena.cz"
echo "       service: http://localhost:80"
echo "     - service: http_status:404"
echo ""
echo "5. DNS záznam:"
echo "   cloudflared tunnel route dns fve-dashboard fve.tvojedomena.cz"
echo ""
echo "6. Spuštění jako systemd služba:"
echo "   cloudflared service install"
echo "   systemctl enable cloudflared"
echo "   systemctl start cloudflared"
echo ""
echo "7. Ověření:"
echo "   cloudflared tunnel info fve-dashboard"
echo "   curl https://fve.tvojedomena.cz"
echo ""
