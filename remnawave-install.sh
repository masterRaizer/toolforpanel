#!/bin/bash
# ============================================================
#  Remnawave Panel 2.8.0 — One-Click Installer
#  https://github.com/shashachkaaa/remnawave-scripts
# ============================================================

set -e

# Colors
CLR='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'

# Directories
INSTALL_DIR="/opt/remnawave"
NGINX_DIR="$INSTALL_DIR/nginx"
SUB_DIR="$INSTALL_DIR/subscription"
LOG_FILE="/var/log/remnawave-install.log"

# Defaults
PANEL_DOMAIN=""
SUB_DOMAIN=""

# ============================================================
# Helpers
# ============================================================
log_init() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

info()    { echo -e "${BLUE}[•]${CLR} $1"; }
ok()      { echo -e "${GREEN}[✓]${CLR} $1"; }
warn()    { echo -e "${YELLOW}[!]${CLR} $1"; }
err()     { echo -e "${RED}[✗]${CLR} $1"; }
step()    { echo -e "\n${CYAN}▶${CLR} ${BOLD}$1${CLR}"; }
banner()  { echo -e "${PURPLE}$1${CLR}"; }

header() {
    clear 2>/dev/null || true
    echo ""
    echo -e "${PURPLE}    ╔══════════════════════════════════════════════════════════╗${CLR}"
    echo -e "${PURPLE}    ║                                                          ║${CLR}"
    echo -e "${PURPLE}    ║        ██████  ███████ ███    ███ ███    ██              ║${CLR}"
    echo -e "${PURPLE}    ║        ██   ██ ██      ████  ████ ████   ██              ║${CLR}"
    echo -e "${PURPLE}    ║        ██████  █████   ██ ████ ██ ██ ██  ██              ║${CLR}"
    echo -e "${PURPLE}    ║        ██   ██ ██      ██  ██  ██ ██  ██ ██              ║${CLR}"
    echo -e "${PURPLE}    ║        ██   ██ ███████ ██      ██ ██   ████              ║${CLR}"
    echo -e "${PURPLE}    ║                                                          ║${CLR}"
    echo -e "${PURPLE}    ║              Panel 2.8.0 — One-Click Setup               ║${CLR}"
    echo -e "${PURPLE}    ╚══════════════════════════════════════════════════════════╝${CLR}"
    echo ""
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root. Use: ${YELLOW}sudo su -${CLR}"
        exit 1
    fi
}

# ============================================================
# Docker
# ============================================================
install_docker() {
    step "Checking Docker"
    if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
        ok "Docker $(docker --version | awk '{print $3}' | tr -d ',') is already installed"
        return 0
    fi
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
    systemctl enable docker --now >/dev/null 2>&1
    ok "Docker installed successfully"
}

# ============================================================
# Generate secrets
# ============================================================
generate_secrets() {
    step "Generating secure secrets"
    JWT_AUTH_SECRET=$(openssl rand -hex 64)
    JWT_API_TOKENS_SECRET=$(openssl rand -hex 64)
    APP_SECRET=$(openssl rand -hex 64)
    METRICS_PASS=$(openssl rand -hex 64)
    WEBHOOK_SECRET=$(openssl rand -hex 64 | head -c 64)
    POSTGRES_PASSWORD=$(openssl rand -hex 24)
    ok "Secrets generated"
}

# ============================================================
# Domain input
# ============================================================
ask_domains() {
    step "Domain Configuration"

    if [[ -z "$PANEL_DOMAIN" ]]; then
        read -rp "Enter panel domain (e.g., panel.example.com): " PANEL_DOMAIN
    fi
    if [[ -z "$SUB_DOMAIN" ]]; then
        read -rp "Enter subscription domain (e.g., sub.example.com): " SUB_DOMAIN
    fi

    ok "Panel domain:    ${GREEN}$PANEL_DOMAIN${CLR}"
    ok "Sub domain:      ${GREEN}$SUB_DOMAIN${CLR}"
}

# ============================================================
# Download configs
# ============================================================
download_configs() {
    step "Downloading configuration files"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    info "Fetching docker-compose.yml (backend:2.8.0)..."
    curl -fsSL -o docker-compose.yml \
        "https://raw.githubusercontent.com/remnawave/backend/main/docker-compose-prod.yml" 2>/dev/null

    # Pin to 2.8.0
    sed -i 's|remnawave/backend:2$|remnawave/backend:2.8.0|' docker-compose.yml
    sed -i 's|remnawave/backend:2 |remnawave/backend:2.8.0 |' docker-compose.yml

    info "Fetching .env.sample..."
    curl -fsSL -o .env \
        "https://raw.githubusercontent.com/remnawave/backend/main/.env.sample" 2>/dev/null

    ok "Configuration files downloaded"
}

# ============================================================
# Configure .env
# ============================================================
configure_env() {
    step "Configuring environment"
    cd "$INSTALL_DIR"

    # Apply secrets
    sed -i "s|^JWT_AUTH_SECRET=.*|JWT_AUTH_SECRET=$JWT_AUTH_SECRET|" .env
    sed -i "s|^JWT_API_TOKENS_SECRET=.*|JWT_API_TOKENS_SECRET=$JWT_API_TOKENS_SECRET|" .env
    sed -i "s|^#\?APP_SECRET=.*|APP_SECRET=$APP_SECRET|" .env
    sed -i "s|^METRICS_PASS=.*|METRICS_PASS=$METRICS_PASS|" .env
    sed -i "s|^WEBHOOK_SECRET_HEADER=.*|WEBHOOK_SECRET_HEADER=$WEBHOOK_SECRET|" .env
    sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASSWORD|" .env
    sed -i "s|postgresql://postgres:[^@]*@|postgresql://postgres:$POSTGRES_PASSWORD@|" .env

    # Domains
    sed -i "s|^FRONT_END_DOMAIN=.*|FRONT_END_DOMAIN=$PANEL_DOMAIN|" .env
    sed -i "s|^SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=$SUB_DOMAIN|" .env
    sed -i "s|^PANEL_DOMAIN=.*|PANEL_DOMAIN=$PANEL_DOMAIN|" .env

    # Disable Telegram by default
    sed -i "s|^IS_TELEGRAM_NOTIFICATIONS_ENABLED=.*|IS_TELEGRAM_NOTIFICATIONS_ENABLED=false|" .env

    ok ".env configured"
}

# ============================================================
# Start panel
# ============================================================
start_panel() {
    step "Starting Remnawave Panel 2.8.0"
    cd "$INSTALL_DIR"
    docker compose up -d

    info "Waiting for services to become healthy..."
    for i in {1..60}; do
        if curl -fs http://127.0.0.1:3001/health &>/dev/null; then
            ok "Panel is healthy and running"
            return 0
        fi
        sleep 1
        echo -n "."
    done
    echo ""
    warn "Health check timed out. Check logs: docker compose logs -f"
}

# ============================================================
# Nginx + SSL
# ============================================================
setup_nginx() {
    step "Setting up Nginx reverse proxy with SSL"

    mkdir -p "$NGINX_DIR"
    cd "$NGINX_DIR"

    # Dependencies
    info "Installing dependencies (cron, socat)..."
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq cron socat >/dev/null 2>&1

    # acme.sh
    if [[ ! -d "$HOME/.acme.sh" ]]; then
        info "Installing acme.sh..."
        curl https://get.acme.sh | sh -s email="admin@$PANEL_DOMAIN" >/dev/null 2>&1
    fi
    export PATH="$HOME/.acme.sh:$PATH"

    # Issue SSL
    info "Requesting SSL certificate for $PANEL_DOMAIN..."
    acme.sh --issue --standalone -d "$PANEL_DOMAIN" \
        --key-file "$NGINX_DIR/privkey.pem" \
        --fullchain-file "$NGINX_DIR/fullchain.pem" \
        --alpn --tlsport 8443

    acme.sh --install-cert -d "$PANEL_DOMAIN" \
        --key-file "$NGINX_DIR/privkey.pem" \
        --fullchain-file "$NGINX_DIR/fullchain.pem" \
        --reloadcmd "docker exec remnawave-nginx nginx -s reload 2>/dev/null || true"

    # nginx.conf
    cat > "$NGINX_DIR/nginx.conf" << EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${PANEL_DOMAIN};

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;
    ssl_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 valid=60s;
    resolver_timeout 2s;

    gzip on; gzip_vary on; gzip_proxied any; gzip_comp_level 6;
    gzip_min_length 256;
    gzip_types application/json application/javascript text/css text/plain text/xml;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOF

    # docker-compose for nginx
    cat > "$NGINX_DIR/docker-compose.yml" << EOF
services:
  remnawave-nginx:
    image: nginx:1.30-alpine
    container_name: remnawave-nginx
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro
      - ./privkey.pem:/etc/nginx/ssl/privkey.pem:ro
    restart: always
    ports:
      - '0.0.0.0:443:443'
    networks:
      - remnawave-network

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: true
EOF

    docker compose up -d
    ok "Nginx running on port 443 with SSL"
}

# ============================================================
# Subscription Page
# ============================================================
setup_subscription() {
    step "Setting up Subscription Page"

    mkdir -p "$SUB_DIR"
    cd "$SUB_DIR"

    cat > "$SUB_DIR/docker-compose.yml" << EOF
services:
  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    restart: always
    env_file:
      - ${INSTALL_DIR}/.env
    ports:
      - '127.0.0.1:3010:3010'
    networks:
      - remnawave-network

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: true
EOF

    docker compose up -d
    ok "Subscription Page running on port 3010"
}

# ============================================================
# Save credentials
# ============================================================
save_credentials() {
    cat > "$INSTALL_DIR/.credentials" << EOF
========================================
  REMNAWAVE PANEL 2.8.0 CREDENTIALS
========================================

Panel URL:      https://${PANEL_DOMAIN}
Subscription:   https://${SUB_DOMAIN}

--- Secrets (SAVE THESE!) ---
APP_SECRET:            ${APP_SECRET}
JWT_AUTH_SECRET:       ${JWT_AUTH_SECRET}
JWT_API_TOKENS_SECRET: ${JWT_API_TOKENS_SECRET}
METRICS_PASS:          ${METRICS_PASS}
POSTGRES_PASSWORD:     ${POSTGRES_PASSWORD}
WEBHOOK_SECRET:        ${WEBHOOK_SECRET}

--- Directories ---
Panel:          ${INSTALL_DIR}
Nginx:          ${NGINX_DIR}
Subscription:   ${SUB_DIR}

--- Useful Commands ---
Logs:   cd ${INSTALL_DIR} && docker compose logs -f
Stop:   cd ${INSTALL_DIR} && docker compose down
Restart: cd ${INSTALL_DIR} && docker compose restart

========================================
EOF
    chmod 600 "$INSTALL_DIR/.credentials"
    ok "Credentials saved to $INSTALL_DIR/.credentials"
}

# ============================================================
# Summary
# ============================================================
show_summary() {
    echo ""
    banner "╔══════════════════════════════════════════════════════════╗"
    banner "║           INSTALLATION COMPLETE! ✓                      ║"
    banner "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo -e "  ${BOLD}Panel URL:${CLR}      ${GREEN}https://${PANEL_DOMAIN}${CLR}"
    echo -e "  ${BOLD}Subscription:${CLR}   ${GREEN}https://${SUB_DOMAIN}${CLR}"
    echo ""
    echo -e "  ${YELLOW}NEXT STEPS:${CLR}"
    echo -e "  1. Open ${GREEN}https://${PANEL_DOMAIN}${CLR} in your browser"
    echo -e "  2. Create superadmin account (first launch)"
    echo -e "  3. Go to Settings → General → configure panel"
    echo -e "  4. Add nodes in the Nodes section"
    echo -e "  5. Create users with subscription links"
    echo ""
    echo -e "  ${CYAN}Credentials:${CLR}    cat ${INSTALL_DIR}/.credentials"
    echo -e "  ${CYAN}Panel Logs:${CLR}     cd ${INSTALL_DIR} && docker compose logs -f"
    echo -e "  ${CYAN}Nginx Logs:${CLR}     cd ${NGINX_DIR} && docker compose logs -f"
    echo ""

    # Show running containers
    info "Running containers:"
    docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null | grep -E "remnawave" || true
    echo ""
}

# ============================================================
# Uninstall
# ============================================================
do_uninstall() {
    header
    step "Uninstalling Remnawave"
    warn "This will remove all Remnawave containers and data!"
    read -rp "Are you sure? Type 'yes' to confirm: " confirm
    if [[ "$confirm" != "yes" ]]; then
        info "Uninstall cancelled"
        return
    fi

    cd "$INSTALL_DIR" 2>/dev/null && docker compose down -v 2>/dev/null || true
    cd "$NGINX_DIR" 2>/dev/null && docker compose down -v 2>/dev/null || true
    cd "$SUB_DIR" 2>/dev/null && docker compose down -v 2>/dev/null || true

    rm -rf "$INSTALL_DIR"
    ok "Remnawave uninstalled"
}

# ============================================================
# Show logs
# ============================================================
show_logs() {
    header
    echo -e "${CYAN}1)${CLR} Panel logs"
    echo -e "${CYAN}2)${CLR} Nginx logs"
    echo -e "${CYAN}3)${CLR} Subscription logs"
    echo -e "${CYAN}4)${CLR} All containers"
    read -rp "Select: " choice
    case $choice in
        1) cd "$INSTALL_DIR" && docker compose logs -f ;;
        2) cd "$NGINX_DIR" && docker compose logs -f ;;
        3) cd "$SUB_DIR" && docker compose logs -f ;;
        4) docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep remnawave ;;
        *) info "Cancelled" ;;
    esac
}

# ============================================================
# Status check
# ============================================================
show_status() {
    header
    step "Container Status"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | grep -E "(NAME|remnawave)" || warn "No Remnawave containers running"
    echo ""
    if [[ -f "$INSTALL_DIR/.credentials" ]]; then
        step "Saved Configuration"
        grep -E "(URL|DOMAIN)" "$INSTALL_DIR/.credentials" 2>/dev/null || true
    fi
}

# ============================================================
# Menu
# ============================================================
show_menu() {
    header
    echo -e "  ${CYAN}1)${CLR} ${BOLD}Install Remnawave 2.8.0${CLR}  — Full installation"
    echo -e "  ${CYAN}2)${CLR} ${BOLD}Show Status${CLR}            — Running containers"
    echo -e "  ${CYAN}3)${CLR} ${BOLD}View Logs${CLR}              — Container logs"
    echo -e "  ${CYAN}4)${CLR} ${RED}${BOLD}Uninstall${CLR}              — Remove everything"
    echo -e "  ${CYAN}0)${CLR} ${BOLD}Exit${CLR}"
    echo ""
    read -rp "Select option [0-4]: " choice
    echo ""

    case $choice in
        1) do_install ;;
        2) show_status; read -rp "Press Enter..."; show_menu ;;
        3) show_logs ;;
        4) do_uninstall; read -rp "Press Enter..."; show_menu ;;
        0) info "Goodbye!"; exit 0 ;;
        *) warn "Invalid option"; sleep 1; show_menu ;;
    esac
}

# ============================================================
# Main install flow
# ============================================================
do_install() {
    header
    log_init
    require_root

    # Check if already installed
    if [[ -d "$INSTALL_DIR" ]] && docker ps --format '{{.Names}}' | grep -q "remnawave"; then
        warn "Remnawave appears to be already installed!"
        read -rp "Continue and overwrite? [y/N]: " overwrite
        [[ "$overwrite" =~ ^[Yy]$ ]] || { show_menu; return; }
    fi

    ask_domains
    install_docker
    generate_secrets
    download_configs
    configure_env
    start_panel
    setup_nginx
    setup_subscription
    save_credentials
    show_summary
}

# ============================================================
# Entrypoint
# ============================================================
# If called with arguments (non-interactive)
if [[ "${1:-}" == "install" ]]; then
    PANEL_DOMAIN="${2:-}"
    SUB_DOMAIN="${3:-}"
    if [[ -z "$PANEL_DOMAIN" || -z "$SUB_DOMAIN" ]]; then
        err "Usage: $0 install <panel_domain> <sub_domain>"
        exit 1
    fi
    do_install
    exit 0
fi

# Interactive menu
show_menu
