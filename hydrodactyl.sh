#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Banner
# ------------------------------------------------------------
show_banner() {
  cat <<'EOF'
====================================================
  _    _            _____ _                 _ 
 | |  | |          / ____| |               | |
 | |__| | _____  _| |    | | ___  _   _  __| |
 |  __  |/ _ \ \/ / |    | |/ _ \| | | |/ _` |
 | |  | |  __/>  <| |____| | (_) | |_| | (_| |
 |_|  |_|\___/_/\_\\_____|_|\___/ \__,_|\__,_|

           Developer: Michael
   All-in-One Manager: HydroDactyl + Wings
          + Cloudflared (HTTP/2 + IPv4)
====================================================
EOF
}

INSTALL_DIR="/root/HydroDactyl"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
DATA_DIR="/srv/pterodactyl"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
check_root() {
  [[ $EUID -eq 0 ]] || { echo "This script must be run as root."; exit 1; }
}

ensure_docker() {
  if ! command -v docker &>/dev/null; then
    echo "Installing Docker..."
    apt-get update
    apt-get install -y docker.io docker-compose-plugin
    systemctl enable --now docker
  fi
  if ! docker compose version &>/dev/null; then
    apt-get update
    apt-get install -y docker-compose-plugin
  fi
}

# Write compose file with the panel domain and LE email baked in.
write_compose_file() {
  local domain="$1"
  local le_email="$2"

  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  cat > docker-compose.yml <<YAML
x-common:
    database: &db-environment
        MYSQL_PASSWORD: &db-password 'keasuisapottan67'
        MYSQL_ROOT_PASSWORD: 'keasuisapottan67'
    panel: &panel-environment
        APP_URL: 'https://${domain}'
        APP_TIMEZONE: 'UTC'
        APP_SERVICE_AUTHOR: 'ItzStrider@Outlook.in'
        DB_USERNAME: "pterodactyl"
        LE_EMAIL: '${le_email}'
    mail: &mail-environment
        MAIL_FROM: 'noreply@example.com'
        MAIL_DRIVER: 'smtp'
        MAIL_HOST: 'mail'
        MAIL_PORT: '1025'
        MAIL_USERNAME: ''
        MAIL_PASSWORD: ''
        MAIL_ENCRYPTION: 'true'

services:
    database:
        image: mariadb:10.5
        restart: no
        command: --default-authentication-plugin=mysql_native_password
        volumes:
          - '/srv/pterodactyl/database:/var/lib/mysql'
        environment:
            <<: *db-environment
            MYSQL_DATABASE: 'panel'
            MYSQL_USER: 'pterodactyl'
    cache:
        image: redis:alpine
        restart: no
    panel:
        image: ghcr.io/blueprintframework/hydrodactyl:latest
        restart: no
        # Bound to localhost – Cloudflare Tunnel is the ingress.
        ports:
            - '127.0.0.1:80:80'
            - '127.0.0.1:443:443'
        links:
            - database
            - cache
        volumes:
            - '/srv/pterodactyl/var/:/app/var/'
            - '/srv/pterodactyl/nginx/:/etc/nginx/http.d/'
            - '/srv/pterodactyl/certs/:/etc/letsencrypt/'
            - '/srv/pterodactyl/logs/:/app/storage/logs'
            - '/srv/pterodactyl/storage/:/app/storage/app/public'
        environment:
            <<: [*panel-environment, *mail-environment]
            DB_PASSWORD: *db-password
            APP_ENV: 'production'
            APP_ENVIRONMENT_ONLY: 'false'
            CACHE_DRIVER: 'redis'
            SESSION_DRIVER: 'redis'
            QUEUE_DRIVER: 'redis'
            REDIS_HOST: 'cache'
            DB_CONNECTION: 'mariadb'
            DB_HOST: 'database'
            DB_PORT: '3306'
            HASHIDS_LENGTH: 8
networks:
    default:
        ipam:
            config:
                - subnet: 172.20.0.0/16
YAML
}

# Install / re-patch cloudflared with the given token (HTTP/2 + IPv4).
install_cloudflared_service() {
  local token="$1"

  if ! command -v cloudflared &>/dev/null; then
    echo "Installing cloudflared..."
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
      | tee /etc/apt/sources.list.d/cloudflared.list
    apt-get update
    apt-get install -y cloudflared
  fi

  pkill cloudflared >/dev/null 2>&1 || true
  cloudflared service install "$token" >/dev/null 2>&1 || true

  sed -i "s|^ExecStart=.*|ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel --protocol http2 --edge-ip-version 4 run --token $token|" \
    /etc/systemd/system/cloudflared.service

  if ! grep -q "TimeoutStartSec=0" /etc/systemd/system/cloudflared.service; then
    sed -i '/^\[Service\]/a TimeoutStartSec=0' /etc/systemd/system/cloudflared.service
  fi

  systemctl daemon-reload
  systemctl restart cloudflared
  systemctl --no-pager --full status cloudflared || true
}

# ------------------------------------------------------------
# Install
# ------------------------------------------------------------
do_install() {
  echo ""
  echo "=============================================="
  echo " HydroDactyl – Install"
  echo "=============================================="
  echo ""

  read -rp "Panel domain (e.g. panel.example.com): " PANEL_DOMAIN
  PANEL_DOMAIN="${PANEL_DOMAIN#https://}"
  PANEL_DOMAIN="${PANEL_DOMAIN#http://}"
  PANEL_DOMAIN="${PANEL_DOMAIN%/}"

  read -rp "Let's Encrypt email: " LE_EMAIL
  read -rp "Cloudflare Tunnel token (or paste full command): " CF_INPUT

  CF_TOKEN=$(echo "$CF_INPUT" | awk '{print $NF}')

  if [[ -z "$PANEL_DOMAIN" || -z "$LE_EMAIL" || -z "$CF_TOKEN" ]]; then
    echo "❌ Domain, email, and tunnel token are all required."
    return
  fi

  ensure_docker
  write_compose_file "$PANEL_DOMAIN" "$LE_EMAIL"

  echo ""
  echo "Installing and starting cloudflared..."
  install_cloudflared_service "$CF_TOKEN"

  echo ""
  echo "Starting HydroDactyl (APP_URL=https://${PANEL_DOMAIN})..."
  cd "$INSTALL_DIR"
  docker compose up -d

  sleep 10

  cat <<EOF

==============================================
✅  HydroDactyl has been installed.
==============================================

  APP_URL : https://${PANEL_DOMAIN}
  LE email: ${LE_EMAIL}

The panel is now requesting a Let's Encrypt cert for
${PANEL_DOMAIN}.  For that to succeed, the Cloudflare
Tunnel must first expose the panel over HTTP.

📋 Step 1 — Set the tunnel to HTTP (temporary):

  1. Cloudflare Zero Trust → Networks → Tunnels
  2. Edit the tunnel tied to your token.
  3. Public Hostname:
        Domain:  ${PANEL_DOMAIN}
        Type:    HTTP
        URL:     localhost:80
  4. Save and wait ~1–2 minutes for the cert to be issued.

  Verify the cert exists:
     ls /srv/pterodactyl/certs/live/${PANEL_DOMAIN}/

📋 Step 2 — Switch the tunnel to HTTPS (final):

  5. Edit the same Public Hostname:
        Type:    HTTPS
        URL:     localhost:443
  6. Additional application settings → TLS:
        Enable  "No TLS Verify"
  7. Save.

🌐 Step 3 — Open your panel:

     https://${PANEL_DOMAIN}

You should now see the HydroDactyl login page with a valid
Let's Encrypt certificate.

==============================================
Developer: Michael
==============================================
EOF
}

# ------------------------------------------------------------
# Uninstall
# ------------------------------------------------------------
do_uninstall() {
  echo ""
  echo "=============================================="
  echo " HydroDactyl – Uninstall"
  echo "=============================================="

  if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "No HydroDactyl installation found at $INSTALL_DIR."
    return
  fi

  read -rp "Stop and remove HydroDactyl containers? [y/N]: " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Cancelled."; return; }

  cd "$INSTALL_DIR"
  docker compose down

  read -rp "Also delete panel data ($DATA_DIR) and compose file? [y/N]: " DELETE_DATA
  if [[ "$DELETE_DATA" =~ ^[Yy]$ ]]; then
    rm -rf "$DATA_DIR" "$INSTALL_DIR"
    echo "Data and install dir removed."
  else
    echo "Data kept at $DATA_DIR."
  fi
  echo "✅ Uninstall complete."
}

# ------------------------------------------------------------
# Update
# ------------------------------------------------------------
do_update() {
  echo ""
  echo "=============================================="
  echo " HydroDactyl – Update"
  echo "=============================================="

  if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "No HydroDactyl installation found at $INSTALL_DIR."
    return
  fi

  cd "$INSTALL_DIR"
  docker compose pull
  docker compose up -d
  echo "✅ Update complete."
  docker compose ps
}

# ------------------------------------------------------------
# Pterodactyl Wings
# ------------------------------------------------------------
do_wings() {
  echo ""
  echo "=============================================="
  echo " Pterodactyl Wings – Auto Setup"
  echo "=============================================="

  if ! command -v wings &>/dev/null; then
    echo "⚠️  Wings is not installed. Install it first, then re-run."
    return
  fi

  local s="/tmp/wings-auto-setup.sh"
  curl -fsSL "https://raw.githubusercontent.com/StriderCraft315/Codes/refs/heads/main/srv/wings/auto1.sh" -o "$s"
  chmod +x "$s"
  bash "$s"
  rm -f "$s"
}

# ------------------------------------------------------------
# Cloudflared re-patch (token only)
# ------------------------------------------------------------
do_cloudflared() {
  echo ""
  echo "=============================================="
  echo " Cloudflared – Reinstall / Re-patch"
  echo "=============================================="

  read -rp "Paste tunnel token (or full command): " input
  local token
  token=$(echo "$input" | awk '{print $NF}')
  [[ -z "${token:-}" ]] && { echo "❌ No token detected."; return; }

  install_cloudflared_service "$token"
  echo "✅ Cloudflared is running with HTTP/2 over IPv4."
}

# ------------------------------------------------------------
# Menu
# ------------------------------------------------------------
show_menu() {
  echo ""
  echo "=============================================="
  echo " HydroDactyl Manager"
  echo "=============================================="
  echo " 1) Install HydroDactyl (with Cloudflare Tunnel)"
  echo " 2) Uninstall HydroDactyl"
  echo " 3) Update HydroDactyl"
  echo " 4) Pterodactyl Wings Setup"
  echo " 5) Reinstall / Re-patch Cloudflared"
  echo " 6) Exit"
  echo "=============================================="
  read -rp "Select an option [1-6]: " CHOICE
}

main() {
  check_root
  show_banner

  while true; do
    show_menu
    case "$CHOICE" in
      1) do_install ;;
      2) do_uninstall ;;
      3) do_update ;;
      4) do_wings ;;
      5) do_cloudflared ;;
      6) echo "Goodbye."; exit 0 ;;
      *) echo "Invalid option." ;;
    esac
    echo ""
    read -rp "Press Enter to return to the menu..." _
  done
}

main
