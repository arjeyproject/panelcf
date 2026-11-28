#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/arjeyproject/panelcf.git}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/panelcf}"

echo "============================================================"
echo "  CFHub V24 — One-Click Installer (Bot + iOS Mini App + 24/7)"
echo "============================================================"

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] Please run as root (sudo bash install.sh)."
  exit 1
fi

echo ">>> [1/5] Installing prerequisites (git, curl, ufw, cron, docker)..."
apt-get update -y
apt-get install -y git curl ca-certificates ufw cron openssl
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker cron
ufw allow 22/tcp >/dev/null 2>&1 || true
ufw allow 8088/tcp >/dev/null 2>&1 || true

echo ">>> [2/5] Fetching / updating repository at $INSTALL_DIR..."
if [ -d "$INSTALL_DIR/.git" ]; then
  cd "$INSTALL_DIR"
  git pull --ff-only || true
else
  git clone "$REPO_URL" "$INSTALL_DIR"
  cd "$INSTALL_DIR"
fi
mkdir -p data
chmod 777 data

echo ">>> [3/5] Configuring .env..."
if [ ! -f .env ]; then
  read -rp "Enter TELEGRAM_BOT_TOKEN: " BOT_TOKEN
  read -rp "Enter Admin Telegram numeric ID (e.g. 8516792883): " ADMIN_ID
  read -rp "Enter Mini App HTTPS URL [https://app.prostoreshop.site]: " APP_URL
  APP_URL="${APP_URL:-https://app.prostoreshop.site}"
  read -rp "Enter Support Username without @ (optional): " SUP_USER

  # Auto-wrap numeric ID(s) in brackets for Pydantic list validation
  ADMIN_ID_CLEAN="$(echo "$ADMIN_ID" | tr -d ' []')"
  ENC_KEY="$(openssl rand -hex 24)"
  JWT_KEY="$(openssl rand -hex 24)"

  cat <<EOF > .env
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
OWNER_TELEGRAM_IDS=[${ADMIN_ID_CLEAN}]
ENCRYPTION_MASTER_KEY=${ENC_KEY}
JWT_SECRET_KEY=${JWT_KEY}
WEBAPP_URL=${APP_URL}
SUPPORT_USERNAME=${SUP_USER}
EOF
  # Escape any literal '$' for Docker Compose safety
  sed -i 's/\$/\$\$/g' .env
  echo "[OK] Created .env with secure random keys."
else
  echo "[OK] Existing .env detected — keeping current credentials."
fi

echo ">>> [4/5] Installing 2-minute 24/7 Watchdog..."
cat <<__WD_EOF__ > /usr/local/bin/cfhub-watchdog.sh
#!/usr/bin/env bash
if ! curl -sf --max-time 6 http://127.0.0.1:8088/health >/dev/null 2>&1; then
  sleep 3
  if ! curl -sf --max-time 6 http://127.0.0.1:8088/health >/dev/null 2>&1; then
    echo "\$(date -u +%FT%TZ) [WATCHDOG] Unhealthy -> restarting telegram_bot" >> /var/log/cfhub-watchdog.log
    cd "$INSTALL_DIR" && docker compose up -d --no-deps telegram_bot >> /var/log/cfhub-watchdog.log 2>&1
  fi
fi
__WD_EOF__
chmod +x /usr/local/bin/cfhub-watchdog.sh
(crontab -l 2>/dev/null | grep -v "cfhub-watchdog.sh"; echo "*/2 * * * * /usr/local/bin/cfhub-watchdog.sh") | crontab - || true

echo ">>> [5/5] Building and starting telegram_bot (V24)..."
docker compose up -d --build --no-deps telegram_bot
sleep 5
echo -n "Health check: "
curl -s http://127.0.0.1:8088/health || true
echo ""
echo "============================================================"
echo "  DONE! Bot & iOS Mini App are running 24/7 on port 8088."
echo "  View logs: cd $INSTALL_DIR && docker compose logs -f telegram_bot"
echo "============================================================"
