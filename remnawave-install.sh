#!/bin/bash
# ============================================================
#  Remnawave Panel 2.8.0 + Node + Migration — All-in-One Installer
#  https://github.com/masterRaizer/toolforpanel
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
NODE_DIR="/opt/remnanode"
LOG_FILE="/var/log/remnawave-install.log"

# Defaults
PANEL_DOMAIN=""
SUB_DOMAIN=""

# ============================================================
# Helpers
# ============================================================
info()    { echo -e "${BLUE}[*]${CLR} $1"; }
ok()      { echo -e "${GREEN}[OK]${CLR} $1"; }
warn()    { echo -e "${YELLOW}[!]${CLR} $1"; }
err()     { echo -e "${RED}[ERROR]${CLR} $1"; }
step()    { echo -e "\n${CYAN}==>${CLR} ${BOLD}$1${CLR}"; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root. Use: ${YELLOW}sudo su -${CLR}"
        exit 1
    fi
}

header() {
    echo ""
    echo -e "${PURPLE}    ╔══════════════════════════════════════════════════════════╗${CLR}"
    echo -e "${PURPLE}    ║          Remnawave All-in-One Tool                       ║${CLR}"
    echo -e "${PURPLE}    ║          Panel 2.8.0 + Node + Migration                  ║${CLR}"
    echo -e "${PURPLE}    ╚══════════════════════════════════════════════════════════╝${CLR}"
    echo ""
}

safe_apt_install() {
    info "Installing packages: $@"
    set +e
    systemctl mask nginx.service &>/dev/null || true
    dpkg --configure -a &>/dev/null || true
    apt-get --fix-broken install -y -qq &>/dev/null || true
    systemctl unmask nginx.service &>/dev/null || true
    set -e
    apt-get update -qq
    for pkg in "$@"; do
        apt-get install "$pkg" -y -qq
    done
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
# INSTALL PANEL
# ============================================================
install_panel() {
    header
    require_root
    log_init 2>/dev/null || true
    
    if [[ -d "$INSTALL_DIR" ]] && docker ps --format '{{.Names}}' | grep -q "remnawave"; then
        warn "Remnawave appears to be already installed!"
        read -rp "Continue and overwrite? [y/N]: " overwrite
        [[ "$overwrite" =~ ^[Yy]$ ]] || { return; }
    fi
    
    ask_domains
    install_docker
    generate_secrets
    
    step "Downloading configuration files"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    curl -fsSL -o docker-compose.yml \
        "https://raw.githubusercontent.com/remnawave/backend/main/docker-compose-prod.yml" 2>/dev/null
    sed -i 's|remnawave/backend:2$|remnawave/backend:2.8.0|' docker-compose.yml
    sed -i 's|remnawave/backend:2 |remnawave/backend:2.8.0 |' docker-compose.yml
    
    curl -fsSL -o .env \
        "https://raw.githubusercontent.com/remnawave/backend/main/.env.sample" 2>/dev/null
    
    step "Configuring environment"
    sed -i "s|^JWT_AUTH_SECRET=.*|JWT_AUTH_SECRET=$JWT_AUTH_SECRET|" .env
    sed -i "s|^JWT_API_TOKENS_SECRET=.*|JWT_API_TOKENS_SECRET=$JWT_API_TOKENS_SECRET|" .env
    sed -i "s|^#\?APP_SECRET=.*|APP_SECRET=$APP_SECRET|" .env
    sed -i "s|^METRICS_PASS=.*|METRICS_PASS=$METRICS_PASS|" .env
    sed -i "s|^WEBHOOK_SECRET_HEADER=.*|WEBHOOK_SECRET_HEADER=$WEBHOOK_SECRET|" .env
    sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASSWORD|" .env
    sed -i "s|postgresql://postgres:[^@]*@|postgresql://postgres:$POSTGRES_PASSWORD@|" .env
    sed -i "s|^FRONT_END_DOMAIN=.*|FRONT_END_DOMAIN=$PANEL_DOMAIN|" .env
    sed -i "s|^SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=$SUB_DOMAIN|" .env
    sed -i "s|^PANEL_DOMAIN=.*|PANEL_DOMAIN=$PANEL_DOMAIN|" .env
    sed -i "s|^IS_TELEGRAM_NOTIFICATIONS_ENABLED=.*|IS_TELEGRAM_NOTIFICATIONS_ENABLED=false|" .env
    
    step "Starting Remnawave Panel 2.8.0"
    docker compose up -d
    
    info "Waiting for services..."
    for i in {1..60}; do
        if curl -fs http://127.0.0.1:3001/health &>/dev/null; then
            ok "Panel is healthy!"
            break
        fi
        sleep 1
    done
    
    # Nginx + SSL
    setup_nginx
    
    # Subscription Page
    setup_subscription
    
    # Save credentials
    save_credentials
    show_summary
}

# ============================================================
# NGINX + SSL
# ============================================================
setup_nginx() {
    step "Setting up Nginx with SSL"
    mkdir -p "$NGINX_DIR"
    cd "$NGINX_DIR"
    
    apt-get install -y -qq cron socat
    
    if [[ ! -d "$HOME/.acme.sh" ]]; then
        curl https://get.acme.sh | sh -s email="admin@$PANEL_DOMAIN" >/dev/null 2>&1
    fi
    export PATH="$HOME/.acme.sh:$PATH"
    
    acme.sh --issue --standalone -d "$PANEL_DOMAIN" \
        --key-file "$NGINX_DIR/privkey.pem" \
        --fullchain-file "$NGINX_DIR/fullchain.pem" \
        --alpn --tlsport 8443
    
    if [[ "$SUB_DOMAIN" != "$PANEL_DOMAIN" ]]; then
        acme.sh --issue --standalone -d "$SUB_DOMAIN" \
            --key-file "$NGINX_DIR/privkey-sub.pem" \
            --fullchain-file "$NGINX_DIR/fullchain-sub.pem" \
            --alpn --tlsport 8443
    fi
    
    # Get container IPs
    REMNAWAVE_IP=$(docker network inspect remnawave-network --format "{{range .Containers}}{{if eq .Name \"remnawave\"}}{{.IPv4Address}}{{end}}{{end}}" | cut -d/ -f1)
    SUB_IP=$(docker network inspect remnawave-network --format "{{range .Containers}}{{if eq .Name \"remnawave-subscription-page\"}}{{.IPv4Address}}{{end}}{{end}}" | cut -d/ -f1)
    
    cat > "$NGINX_DIR/nginx.conf" << EOF
server {
    listen 443 ssl http2;
    server_name ${PANEL_DOMAIN};
    location / {
        proxy_http_version 1.1;
        proxy_pass http://${REMNAWAVE_IP}:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_redirect off;
    }
    ssl_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/privkey.pem";
}
EOF
    
    if [[ "$SUB_DOMAIN" != "$PANEL_DOMAIN" && -n "$SUB_IP" ]]; then
        cat >> "$NGINX_DIR/nginx.conf" << EOF
server {
    listen 443 ssl http2;
    server_name ${SUB_DOMAIN};
    location / {
        proxy_http_version 1.1;
        proxy_pass http://${SUB_IP}:3010;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_redirect off;
    }
    ssl_certificate "/etc/nginx/ssl-sub/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl-sub/privkey.pem";
}
EOF
    fi
    
    cat >> "$NGINX_DIR/nginx.conf" << EOF
server { listen 443 ssl default_server; server_name _; ssl_reject_handshake on; }
EOF
    
    cat > "$NGINX_DIR/docker-compose.yml" << EOF
services:
  remnawave-nginx:
    image: nginx:1.30-alpine
    container_name: remnawave-nginx
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro
      - ./privkey.pem:/etc/nginx/ssl/privkey.pem:ro
EOF
    
    if [[ "$SUB_DOMAIN" != "$PANEL_DOMAIN" ]]; then
        cat >> "$NGINX_DIR/docker-compose.yml" << EOF
      - ./fullchain-sub.pem:/etc/nginx/ssl-sub/fullchain.pem:ro
      - ./privkey-sub.pem:/etc/nginx/ssl-sub/privkey.pem:ro
EOF
    fi
    
    cat >> "$NGINX_DIR/docker-compose.yml" << EOF
    restart: always
    ports:
      - "0.0.0.0:443:443"
    networks:
      - remnawave-network

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: true
EOF
    
    docker compose up -d
    ok "Nginx running on port 443"
}

# ============================================================
# SUBSCRIPTION PAGE
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
      - ./.env
    ports:
      - "127.0.0.1:3010:3010"
    networks:
      - remnawave-network

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: true
EOF
    
    cat > "$SUB_DIR/.env" << EOF
APP_PORT=3010
REMNAWAVE_PANEL_URL=http://remnawave:3000
REMNAWAVE_API_TOKEN=YOUR_API_TOKEN_HERE
TRUST_PROXY=true
CUSTOM_SUB_PREFIX=
MARZBAN_LEGACY_LINK_ENABLED=false
SUB_PUBLIC_DOMAIN=\${SUB_DOMAIN}
EOF
    
    docker compose up -d
    ok "Subscription Page running on port 3010"
    warn "IMPORTANT: Edit $SUB_DIR/.env and set your REMNAWAVE_API_TOKEN"
}

# ============================================================
# INSTALL NODE
# ============================================================
install_node() {
    step "Installing Remnawave Node"
    bash <(curl -Ls https://raw.githubusercontent.com/nerioff1337/remnawave-node-auto/refs/heads/main/install.sh)
    ok "Node installation complete!"
    read -rp "Press Enter to continue..."
}

# ============================================================
# SETUP HYSTERIA2
# ============================================================
setup_hysteria2() {
    step "Setting up Hysteria2"
    read -rp "Node directory [/opt/remnanode]: " NODE_PATH
    NODE_PATH=${NODE_PATH:-/opt/remnanode}
    read -rp "Domain (e.g., node.example.com): " DOMAIN
    
    safe_apt_install certbot
    
    CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    
    if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
        certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos \
            --register-unsafely-without-email \
            --deploy-hook "docker compose -f $NODE_PATH/docker-compose.yml restart remnanode"
    fi
    
    COMPOSE="$NODE_PATH/docker-compose.yml"
    cp "$COMPOSE" "${COMPOSE}.bak"
    
    sed -i -E 's|remnawave/node:[a-zA-Z0-9_.-]+|remnawave/node:latest|g' "$COMPOSE"
    sed -i '/\/var\/lib\/remnawave\/configs\/xray\/ssl/d' "$COMPOSE"
    
    # Add SSL volumes
    if grep -q "^\s*volumes:" "$COMPOSE"; then
        VOL=$(grep -m 1 "^\s*volumes:" "$COMPOSE" | sed -E 's/^([[:space:]]*).*/\1/')
        INDENT="${VOL}  "
        sed -i "/^[[:space:]]*volumes:/a \\
${INDENT}- $CERT:/var/lib/remnawave/configs/xray/ssl/cert.pem:ro\\
${INDENT}- $KEY:/var/lib/remnawave/configs/xray/ssl/cert.key:ro" "$COMPOSE"
    fi
    
    docker compose -f "$COMPOSE" pull
    docker compose -f "$COMPOSE" down
    docker compose -f "$COMPOSE" up -d
    
    ok "Hysteria2 setup complete!"
    read -rp "Press Enter..."
}

# ============================================================
# UPDATE XRAY CORE
# ============================================================
update_xray_core() {
    step "Updating Xray Core"
    read -rp "Custom Xray path [/opt/remnanode/custom-xray]: " CX_DIR
    CX_DIR=${CX_DIR:-/opt/remnanode/custom-xray}
    read -rp "Node path [/opt/remnanode]: " NODE_PATH
    NODE_PATH=${NODE_PATH:-/opt/remnanode}
    read -rp "Version [latest]: " VER
    VER=${VER:-latest}
    
    safe_apt_install curl unzip
    mkdir -p "$CX_DIR"
    cd "$CX_DIR"
    
    if [[ "$VER" == "latest" ]]; then
        VER=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    fi
    
    wget -qO Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/download/${VER}/Xray-linux-64.zip"
    unzip -o Xray-linux-64.zip >/dev/null
    chmod +x xray
    
    COMPOSE="$NODE_PATH/docker-compose.yml"
    if ! grep -q "$CX_DIR/xray:/usr/local/bin/xray:ro" "$COMPOSE"; then
        cp "$COMPOSE" "${COMPOSE}.bak"
        if grep -q "^\s*volumes:" "$COMPOSE"; then
            VOL=$(grep -m 1 "^\s*volumes:" "$COMPOSE" | sed -E 's/^([[:space:]]*).*/\1/')
            INDENT="${VOL}  "
            sed -i "/^[[:space:]]*volumes:/a \\
${INDENT}- $CX_DIR/xray:/usr/local/bin/xray:ro" "$COMPOSE"
        fi
        docker compose -f "$COMPOSE" down
        docker compose -f "$COMPOSE" up -d
    else
        docker compose -f "$COMPOSE" restart remnanode
    fi
    
    ok "Xray updated to $VER!"
    read -rp "Press Enter..."
}

# ============================================================
# RESTART NODE
# ============================================================
restart_node() {
    step "Restarting Node"
    read -rp "Node path [/opt/remnanode]: " NODE_PATH
    NODE_PATH=${NODE_PATH:-/opt/remnanode}
    docker compose -f "$NODE_PATH/docker-compose.yml" restart remnanode
    ok "Node restarted!"
    read -rp "Press Enter..."
}

# ============================================================
# VIEW LOGS
# ============================================================
view_logs() {
    step "Node Logs"
    read -rp "Node path [/opt/remnanode]: " NODE_PATH
    NODE_PATH=${NODE_PATH:-/opt/remnanode}
    echo -e "${YELLOW}Press Ctrl+C to exit${CLR}"
    docker compose -f "$NODE_PATH/docker-compose.yml" logs -f --tail 50 remnanode
}

# ============================================================
# RENEW CERTS
# ============================================================
renew_certs() {
    step "Renewing SSL Certificates"
    certbot renew --force-renewal
    ok "Certificates renewed!"
    read -rp "Press Enter..."
}

# ============================================================
# SWITCH BRANCH
# ============================================================
switch_branch() {
    step "Switching Branch (stable/dev)"
    echo -e "  ${YELLOW}1.${NC} Node"
    echo -e "  ${YELLOW}2.${NC} Panel"
    echo -e "  ${YELLOW}3.${NC} Custom path"
    read -rp "Select (1-3): " choice
    case $choice in
        1) DEFAULT="/opt/remnanode" ;;
        2) DEFAULT="/opt/remnawave" ;;
        3) DEFAULT="" ;;
        *) return ;;
    esac
    read -rp "Path [$DEFAULT]: " PATH_DIR
    PATH_DIR=${PATH_DIR:-$DEFAULT}
    COMPOSE="$PATH_DIR/docker-compose.yml"
    
    [[ ! -f "$COMPOSE" ]] && { err "File not found!"; read -rp "Press Enter..."; return; }
    
    echo -e "  ${YELLOW}1.${NC} DEV branch"
    echo -e "  ${YELLOW}2.${NC} STABLE branch"
    read -rp "Select (1-2): " branch
    
    cp "$COMPOSE" "${COMPOSE}.bak"
    case $branch in
        1)
            sed -i -E 's|remnawave/node:[a-zA-Z0-9_.-]+|remnawave/node:dev|g' "$COMPOSE"
            sed -i -E 's|remnawave/backend:[a-zA-Z0-9_.-]+|remnawave/backend:dev|g' "$COMPOSE"
            ;;
        2)
            sed -i -E 's|remnawave/node:[a-zA-Z0-9_.-]+|remnawave/node:latest|g' "$COMPOSE"
            sed -i -E 's|remnawave/backend:[a-zA-Z0-9_.-]+|remnawave/backend:2|g' "$COMPOSE"
            ;;
        *) return ;;
    esac
    
    docker compose -f "$COMPOSE" pull
    docker compose -f "$COMPOSE" down
    docker compose -f "$COMPOSE" up -d
    ok "Branch switched!"
    read -rp "Press Enter..."
}

# ============================================================
# MIGRATE PANEL (Backup/Restore)
# ============================================================
migrate_panel() {
    while true; do
        clear
        header
        echo -e "  ${YELLOW}1.${NC} Backup panel (export DB + configs)"
        echo -e "  ${YELLOW}2.${NC} Restore panel (import to new server)"
        echo -e "  ${YELLOW}0.${NC} Back"
        read -rp "Select (0-2): " choice
        case $choice in
            1) backup_panel ;;
            2) restore_panel ;;
            0) break ;;
        esac
    done
}

backup_panel() {
    step "Backing up Panel"
    BACKUP_DIR="/opt/remnawave-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    DB_PASS=$(grep POSTGRES_PASSWORD "$INSTALL_DIR/.env" | cut -d= -f2)
    export PGPASSWORD=$DB_PASS
    
    pg_dump -h localhost -p 6767 -U postgres -d postgres --format=custom > "$BACKUP_DIR/db.dump"
    ok "Database dumped"
    
    cp "$INSTALL_DIR/.env" "$BACKUP_DIR/"
    cp "$INSTALL_DIR/docker-compose.yml" "$BACKUP_DIR/"
    mkdir -p "$BACKUP_DIR/nginx"
    cp "$NGINX_DIR"/*.pem "$NGINX_DIR"/*.conf "$BACKUP_DIR/nginx/" 2>/dev/null || true
    
    tar czf "${BACKUP_DIR}.tar.gz" -C "$(dirname "$BACKUP_DIR")" "$(basename "$BACKUP_DIR")"
    ok "Backup created: ${BACKUP_DIR}.tar.gz"
    echo -e "${YELLOW}Copy this file to your new server and run Restore.${CLR}"
    read -rp "Press Enter..."
}

restore_panel() {
    step "Restoring Panel from Backup"
    
    # Find backup files (support both naming formats)
    echo -e "${CYAN}Scanning for backup files...${CLR}"
    mapfile -t BACKUPS < <(find / -maxdepth 3 -name "remnawave_backup_*.tar.gz" -o -name "remnawave-backup-*.tar.gz" 2>/dev/null | sort -r)
    
    if [[ ${#BACKUPS[@]} -gt 0 ]]; then
        echo -e "${GREEN}Found backups:${CLR}"
        for i in "${!BACKUPS[@]}"; do
            size=$(du -h "${BACKUPS[$i]}" 2>/dev/null | cut -f1)
            echo -e "  ${YELLOW}$((i+1)).${CLR} ${BACKUPS[$i]} (${size})"
        done
        echo -e "  ${YELLOW}0.${CLR} Enter custom path"
        read -rp "Select backup [0-${#BACKUPS[@]}]: " sel
        
        if [[ "$sel" =~ ^[0-9]+$ && "$sel" -ge 1 && "$sel" -le ${#BACKUPS[@]} ]]; then
            BACKUP_TGZ="${BACKUPS[$((sel-1))]}"
        else
            read -rp "Enter backup file path: " BACKUP_TGZ
        fi
    else
        echo -e "${YELLOW}No backups found automatically.${CLR}"
        read -rp "Enter backup file path (e.g., /root/remnawave_backup_2026-07-16_00_00_07.tar.gz): " BACKUP_TGZ
    fi
    
    # Validate file
    [[ -z "$BACKUP_TGZ" ]] && { err "No file specified!"; read -rp "Press Enter..."; return; }
    [[ ! -f "$BACKUP_TGZ" ]] && { err "File not found: $BACKUP_TGZ"; read -rp "Press Enter..."; return; }
    
    ok "Selected: $BACKUP_TGZ"
    
    # Extract backup
    BACKUP_DIR="/opt/remnawave-restore-tmp"
    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    
    info "Extracting backup..."
    tar xzf "$BACKUP_TGZ" -C "$BACKUP_DIR"
    
    # Detect structure (strip top-level directory if present)
    if [[ $(ls -1 "$BACKUP_DIR" | wc -l) -eq 1 && -d "$BACKUP_DIR"/$(ls -1 "$BACKUP_DIR") ]]; then
        SUBDIR=$(ls -1 "$BACKUP_DIR")
        mv "$BACKUP_DIR/$SUBDIR"/* "$BACKUP_DIR/" 2>/dev/null || true
        rmdir "$BACKUP_DIR/$SUBDIR" 2>/dev/null || true
    fi
    
    # Verify required files
    info "Verifying backup contents..."
    [[ ! -f "$BACKUP_DIR/db.dump" ]] && { err "Missing db.dump in backup!"; rm -rf "$BACKUP_DIR"; read -rp "Press Enter..."; return; }
    [[ ! -f "$BACKUP_DIR/.env" ]] && { err "Missing .env in backup!"; rm -rf "$BACKUP_DIR"; read -rp "Press Enter..."; return; }
    [[ ! -f "$BACKUP_DIR/docker-compose.yml" ]] && { err "Missing docker-compose.yml in backup!"; rm -rf "$BACKUP_DIR"; read -rp "Press Enter..."; return; }
    
    ok "Backup verified (db.dump + .env + docker-compose.yml)"
    
    # Stop existing panel if running
    if [[ -d "$INSTALL_DIR" ]]; then
        warn "Existing panel found. Stopping..."
        cd "$INSTALL_DIR"
        docker compose down 2>/dev/null || true
    fi
    
    # Install Docker if needed
    install_docker
    
    # Setup directories
    mkdir -p "$INSTALL_DIR" "$NGINX_DIR" "$SUB_DIR"
    
    # Copy files
    cp "$BACKUP_DIR/.env" "$INSTALL_DIR/"
    cp "$BACKUP_DIR/docker-compose.yml" "$INSTALL_DIR/"
    cp "$BACKUP_DIR/nginx"/* "$NGINX_DIR/" 2>/dev/null || true
    
    # Copy subscription if exists
    if [[ -d "$BACKUP_DIR/subscription" ]]; then
        cp -r "$BACKUP_DIR/subscription"/* "$SUB_DIR/" 2>/dev/null || true
        ok "Subscription config restored"
    fi
    
    # Fix backend version
    sed -i 's|remnawave/backend:latest|remnawave/backend:2.8.0|' "$INSTALL_DIR/docker-compose.yml"
    
    # Start DB only
    cd "$INSTALL_DIR"
    docker compose up -d remnawave-db
    
    info "Waiting for DB..."
    for i in {1..30}; do
        if docker exec remnawave-db pg_isready -U postgres &>/dev/null; then
            ok "DB ready!"
            break
        fi
        sleep 1
    done
    
    # Restore database
    DB_PASS=$(grep POSTGRES_PASSWORD "$INSTALL_DIR/.env" | cut -d= -f2)
    export PGPASSWORD=$DB_PASS
    docker exec -i remnawave-db pg_restore -U postgres -d postgres --clean --if-exists < "$BACKUP_DIR/db.dump"
    ok "Database restored!"
    
    # Fix nginx IPs
    cd "$NGINX_DIR"
    sed -i 's|172\.18\.0\.[0-9]*:3000|remnawave:3000|g' nginx.conf 2>/dev/null || true
    sed -i 's|172\.18\.0\.[0-9]*:3010|remnawave-subscription-page:3010|g' nginx.conf 2>/dev/null || true
    
    # Start all services
    cd "$INSTALL_DIR"
    docker compose up -d
    cd "$NGINX_DIR"
    docker compose up -d
    
    # Fix IPs
    REMNAWAVE_IP=$(docker network inspect remnawave-network --format "{{range .Containers}}{{if eq .Name \"remnawave\"}}{{.IPv4Address}}{{end}}{{end}}" | cut -d/ -f1)
    SUB_IP=$(docker network inspect remnawave-network --format "{{range .Containers}}{{if eq .Name \"remnawave-subscription-page\"}}{{.IPv4Address}}{{end}}{{end}}" | cut -d/ -f1)
    sed -i "s|proxy_pass http://remnawave:3000;|proxy_pass http://$REMNAWAVE_IP:3000;|" nginx.conf
    sed -i "s|proxy_pass http://remnawave-subscription-page:3010;|proxy_pass http://$SUB_IP:3010;|" nginx.conf
    docker compose restart
    
    rm -rf "$BACKUP_DIR"
    ok "Panel restored successfully!"
    read -rp "Press Enter..."
}

# ============================================================
# SAVE CREDENTIALS
# ============================================================
save_credentials() {
    cat > "$INSTALL_DIR/.credentials" << EOF
========================================
  REMNAWAVE PANEL 2.8.0
========================================
Panel URL:      https://${PANEL_DOMAIN}
Subscription:   https://${SUB_DOMAIN}

Directories:
  Panel:    ${INSTALL_DIR}
  Nginx:    ${NGINX_DIR}
  Node:     ${NODE_DIR}

Commands:
  Logs:   cd ${INSTALL_DIR} && docker compose logs -f
  Stop:   cd ${INSTALL_DIR} && docker compose down
========================================
EOF
    chmod 600 "$INSTALL_DIR/.credentials"
}

show_summary() {
    echo ""
    echo -e "${GREEN}========================================${CLR}"
    echo -e "${GREEN}  Remnawave Installed!${CLR}"
    echo -e "${GREEN}========================================${CLR}"
    echo -e "  ${BOLD}Panel:${CLR}      ${GREEN}https://${PANEL_DOMAIN}${CLR}"
    echo -e "  ${BOLD}Sub:${CLR}        ${GREEN}https://${SUB_DOMAIN}${CLR}"
    echo -e "\n  ${YELLOW}Next steps:${CLR}"
    echo -e "  1. Open https://${PANEL_DOMAIN}"
    echo -e "  2. Create superadmin account"
    echo -e "  3. Add API token to ${SUB_DIR}/.env"
}

# ============================================================
# MAIN MENU
# ============================================================
show_menu() {
    while true; do
        clear
        header
        echo -e "  ${CYAN}1.${CLR} ${BOLD}Install Panel${CLR}        - Full panel setup"
        echo -e "  ${CYAN}2.${CLR} ${BOLD}Install Node${CLR}         - Install remnawave/node"
        echo -e "  ${CYAN}3.${CLR} ${BOLD}Setup Hysteria2${CLR}      - Configure H2 on node"
        echo -e "  ${CYAN}4.${CLR} ${BOLD}Update Xray Core${CLR}     - Custom Xray version"
        echo -e "  ${CYAN}5.${CLR} ${BOLD}Restart Node${CLR}         - Restart remnanode"
        echo -e "  ${CYAN}6.${CLR} ${BOLD}View Logs${CLR}            - Node logs"
        echo -e "  ${CYAN}7.${CLR} ${BOLD}Renew SSL Certs${CLR}      - Force cert renewal"
        echo -e "  ${CYAN}8.${CLR} ${BOLD}Switch Branch${CLR}        - stable/dev"
        echo -e "  ${CYAN}9.${CLR} ${BOLD}Migrate Panel${CLR}        - Backup/Restore"
        echo -e "  ${RED}0.${CLR} ${BOLD}Exit${CLR}"
        echo ""
        read -rp "Select [0-9]: " choice
        
        case $choice in
            1) install_panel ;;
            2) install_node ;;
            3) setup_hysteria2 ;;
            4) update_xray_core ;;
            5) restart_node ;;
            6) view_logs ;;
            7) renew_certs ;;
            8) switch_branch ;;
            9) migrate_panel ;;
            0) echo -e "${GREEN}Goodbye!${CLR}"; exit 0 ;;
            *) warn "Invalid option"; sleep 1 ;;
        esac
    done
}

# Non-interactive mode
if [[ "${1:-}" == "install" ]]; then
    PANEL_DOMAIN="${2:-}"
    SUB_DOMAIN="${3:-}"
    [[ -z "$PANEL_DOMAIN" || -z "$SUB_DOMAIN" ]] && { err "Usage: $0 install <panel_domain> <sub_domain>"; exit 1; }
    install_panel
    exit 0
fi

# Interactive menu
show_menu
