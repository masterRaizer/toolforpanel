#!/bin/bash
# Remnawave Utility — Панель, Нода, Миграция
# v3.0 — Полностью переписано
set -e

# Цвета
R='\033[0m'; RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'
BLU='\033[0;34m'; PUR='\033[0;35m'; CYN='\033[0;36m'; BOLD='\033[1m'

info() { echo -e "${BLU}[*]${R} $1"; }
ok()   { echo -e "${GRN}[OK]${R} $1"; }
warn() { echo -e "${YEL}[!]${R} $1"; }
err()  { echo -e "${RED}[ERR]${R} $1"; }
step() { echo -e "\n${CYN}▶${R} ${BOLD}$1${R}"; }

# === ПОИСК ПАПКИ ПАНЕЛИ ===
find_panel_dir() {
    local SEARCH_DIRS=("/opt/remnawave" "/root/remnawave" "/home/*/remnawave" "/var/lib/remnawave")
    for d in "${SEARCH_DIRS[@]}"; do
        for found in $d; do
            [[ -f "$found/docker-compose.yml" ]] && { echo "$found"; return 0; }
        done
    done
    # Fallback: find по всей системе (до 4 уровней)
    local FOUND=$(find / -maxdepth 4 -name "docker-compose.yml" -path "*/remnawave/*" 2>/dev/null | head -1)
    [[ -n "$FOUND" ]] && { dirname "$FOUND"; return 0; }
    return 1
}

# === ПОИСК ПАПКИ НОДЫ ===
find_node_dir() {
    local SEARCH_DIRS=("/opt/remnanode" "/root/remnanode" "/home/*/remnanode" "/var/lib/remnanode")
    for d in "${SEARCH_DIRS[@]}"; do
        for found in $d; do
            [[ -f "$found/docker-compose.yml" ]] && { echo "$found"; return 0; }
        done
    done
    local FOUND=$(find / -maxdepth 4 -name "docker-compose.yml" -path "*/remnanode/*" 2>/dev/null | head -1)
    [[ -n "$FOUND" ]] && { dirname "$FOUND"; return 0; }
    return 1
}

# === ПОЛУЧЕНИЕ ВЕРСИИ PANEL С GITHUB ===
get_latest_panel() {
    local V=$(curl -s https://api.github.com/repos/remnawave/backend/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    echo "${V:-2.8.0}"
}

# === ПОЛУЧЕНИЕ ВЕРСИИ NODE С GITHUB ===
get_latest_node() {
    local V=$(curl -s https://api.github.com/repos/remnawave/node/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    echo "${V:-latest}"
}

# === УСТАНОВКА DOCKER ===
install_docker() {
    if ! command -v docker &>/dev/null; then
        info "Установка Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker --now
    fi
    ok "Docker: $(docker --version | awk '{print $3}' | tr -d ',')"
}

require_root() { [[ $EUID -ne 0 ]] && { err "Нужен root"; exit 1; }; }

# === NGINX + ACME.SH SSL ===
setup_nginx() {
    local PD=$1; local SD=$2; local PDIR=$3
    step "Настройка Nginx + SSL (acme.sh)"
    
    apt-get install -y -qq nginx socat cron
    
    # acme.sh установка
    if [[ ! -d "$HOME/.acme.sh" ]]; then
        curl https://get.acme.sh | sh -s email="admin@$PD"
    fi
    export PATH="$HOME/.acme.sh:$PATH"
    
    mkdir -p "$PDIR/nginx"
    cd "$PDIR/nginx"
    
    # Получение сертификатов
    acme.sh --issue --standalone -d "$PD" --key-file "$PDIR/nginx/privkey.pem" --fullchain-file "$PDIR/nginx/fullchain.pem" --alpn --tlsport 8443
    acme.sh --install-cert -d "$PD" --key-file "$PDIR/nginx/privkey.pem" --fullchain-file "$PDIR/nginx/fullchain.pem" --reloadcmd "docker compose -f $PDIR/nginx/docker-compose.yml restart 2>/dev/null || true"
    
    if [[ "$SD" != "$PD" ]]; then
        acme.sh --issue --standalone -d "$SD" --key-file "$PDIR/nginx/privkey-sub.pem" --fullchain-file "$PDIR/nginx/fullchain-sub.pem" --alpn --tlsport 8443
        acme.sh --install-cert -d "$SD" --key-file "$PDIR/nginx/privkey-sub.pem" --fullchain-file "$PDIR/nginx/fullchain-sub.pem" --reloadcmd "docker compose -f $PDIR/nginx/docker-compose.yml restart 2>/dev/null || true"
    fi
    
    # Nginx config для панели
    cat > "$PDIR/nginx/nginx.conf" << EOF
server {
    listen 443 ssl http2;
    server_name $PD;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
    ssl_certificate /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
}
EOF
    if [[ "$SD" != "$PD" ]]; then
        cat >> "$PDIR/nginx/nginx.conf" << EOF
server {
    listen 443 ssl http2;
    server_name $SD;
    location / {
        proxy_pass http://127.0.0.1:3010;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
    }
    ssl_certificate /etc/nginx/ssl-sub/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl-sub/privkey.pem;
}
EOF
    fi
    
    cat > "$PDIR/nginx/docker-compose.yml" << 'COMPOSE'
services:
  nginx:
    image: nginx:alpine
    container_name: rw-nginx
    volumes:
      - __PDIR__/nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - __PDIR__/nginx/fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro
      - __PDIR__/nginx/privkey.pem:/etc/nginx/ssl/privkey.pem:ro
__EXTRA_VOLUMES__
    ports:
      - "0.0.0.0:443:443"
      - "0.0.0.0:80:80"
    network_mode: host
    restart: always
COMPOSE
    sed -i "s|__PDIR__|$PDIR|g" "$PDIR/nginx/docker-compose.yml"
    if [[ "$SD" != "$PD" ]]; then
        sed -i "s|__EXTRA_VOLUMES__|      - $PDIR/nginx/fullchain-sub.pem:/etc/nginx/ssl-sub/fullchain.pem:ro\n      - $PDIR/nginx/privkey-sub.pem:/etc/nginx/ssl-sub/privkey.pem:ro|" "$PDIR/nginx/docker-compose.yml"
    else
        sed -i "s|__EXTRA_VOLUMES__||" "$PDIR/nginx/docker-compose.yml"
    fi
    
    docker compose -f "$PDIR/nginx/docker-compose.yml" up -d
    ok "Nginx + SSL настроены (acme.sh автообновление)"
}

# === SUBSCRIPTION PAGE ===
setup_subscription() {
    local SD=$1; local PDIR=$2
    step "Настройка Subscription Page"
    
    mkdir -p "$PDIR/subscription" && cd "$PDIR/subscription"
    
    # Получение API токена из базы панели
    local TOKEN=""
    local DB_PASS=$(grep POSTGRES_PASSWORD "$PDIR/.env" | cut -d= -f2)
    if docker ps --format '{{.Names}}' | grep -q 'rw-db\|postgres' 2>/dev/null; then
        TOKEN=$(docker exec rw-db psql -U postgres -d postgres -t -c "SELECT token FROM api_tokens LIMIT 1" 2>/dev/null | xargs || true)
    fi
    
    if [[ -z "$TOKEN" ]]; then
        warn "API токен не найден. Введите вручную после установки."
        TOKEN="ВАШ_API_ТОКЕН"
    else
        ok "API токен получен из базы"
    fi
    
    cat > "$PDIR/subscription/docker-compose.yml" << 'COMPOSE'
services:
  sub:
    image: remnawave/subscription-page:latest
    container_name: rw-sub
    env_file:
      - .env
    ports:
      - "127.0.0.1:3010:3010"
    network_mode: host
    restart: always
COMPOSE
    
    cat > "$PDIR/subscription/.env" << EOF
APP_PORT=3010
REMNAWAVE_PANEL_URL=http://127.0.0.1:3000
REMNAWAVE_API_TOKEN=$TOKEN
TRUST_PROXY=true
SUB_PUBLIC_DOMAIN=$SD
EOF
    
    docker compose -f "$PDIR/subscription/docker-compose.yml" up -d
    ok "Subscription Page запущен"
}

# === УСТАНОВКА PANEL ===
install_panel() {
    step "Установка Remnawave Panel"
    require_root
    
    local PDIR=$(find_panel_dir 2>/dev/null || true)
    if [[ -n "$PDIR" ]]; then
        warn "Найдена существующая панель: $PDIR"
        read -rp "Удалить и установить заново? [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] || return
        cd "$PDIR" && docker compose down -v 2>/dev/null || true
        rm -rf "$PDIR"
    fi
    
    # Домены
    read -rp "Домен панели: " PD
    read -rp "Домен подписок: " SD
    [[ -z "$PD" || -z "$SD" ]] && { err "Домены обязательны"; return; }
    
    install_docker
    
    local PDIR="/opt/remnawave"
    mkdir -p "$PDIR" && cd "$PDIR"
    
    # Скачивание
    local VER=$(get_latest_panel)
    ok "Версия панели: $VER"
    curl -fsSL -o docker-compose.yml https://raw.githubusercontent.com/remnawave/backend/main/docker-compose-prod.yml
    curl -fsSL -o .env https://raw.githubusercontent.com/remnawave/backend/main/.env.sample
    
    # Настройка .env
    local J1=$(openssl rand -hex 64)
    local J2=$(openssl rand -hex 64)
    local MP=$(openssl rand -hex 64)
    local WH=$(openssl rand -hex 64)
    local PP=$(openssl rand -hex 24)
    
    sed -i "s|^JWT_AUTH_SECRET=.*|JWT_AUTH_SECRET=$J1|; s|^JWT_API_TOKENS_SECRET=.*|JWT_API_TOKENS_SECRET=$J2|; s|^#\?APP_SECRET=.*|APP_SECRET=$(openssl rand -hex 64)|; s|^METRICS_PASS=.*|METRICS_PASS=$MP|; s|^WEBHOOK_SECRET_HEADER=.*|WEBHOOK_SECRET_HEADER=$WH|; s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$PP|; s|postgresql://postgres:[^@]*@|postgresql://postgres:$PP@|; s|^FRONT_END_DOMAIN=.*|FRONT_END_DOMAIN=$PD|; s|^SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=$SD|; s|^PANEL_DOMAIN=.*|PANEL_DOMAIN=$PD|; s|^IS_TELEGRAM_NOTIFICATIONS_ENABLED=.*|IS_TELEGRAM_NOTIFICATIONS_ENABLED=false" .env
    
    # Фикс версии
    sed -i "s|remnawave/backend:latest|remnawave/backend:$VER|g" docker-compose.yml
    sed -i "s|remnawave/backend:2$|remnawave/backend:$VER|" docker-compose.yml
    sed -i "s|remnawave/backend:2 |remnawave/backend:$VER |" docker-compose.yml
    
    # Запуск
    docker compose up -d
    
    info "Ожидание запуска..."
    for i in {1..60}; do
        curl -fs http://127.0.0.1:3001/health &>/dev/null && { ok "Панель запущена"; break; }
        sleep 1
    done
    
    # Nginx + acme.sh SSL с автообновлением
    setup_nginx "$PD" "$SD" "$PDIR"
    
    # Subscription page
    setup_subscription "$SD" "$PDIR"
    
    # Сохранение данных
    cat > "$PDIR/.credentials" << EOF
Панель:   https://$PD
Подписки: https://$SD
Папка:    $PDIR
Логи:     cd $PDIR && docker compose logs -f
EOF
    chmod 600 "$PDIR/.credentials"
    
    echo -e "\n${GRN}=== Панель установлена ===${R}"
    echo -e "Панель:   ${GRN}https://$PD${R}"
    echo -e "Подписки: ${GRN}https://$SD${R}"
    echo -e "\n${YEL}Создайте superadmin в браузере, затем добавьте API токен${R}"
}

# === УСТАНОВКА НОДЫ ===
install_node() {
    step "Установка Remnawave Node"
    require_root
    
    local NDIR="/opt/remnanode"
    read -rp "Папка ноды [$NDIR]: " NDIR; NDIR=${NDIR:-/opt/remnanode}
    
    read -rp "IP/Домен панели: " PANEL_URL
    read -rp "SECRET_KEY из панели: " SECRET
    [[ -z "$PANEL_URL" || -z "$SECRET" ]] && { err "Обязательные параметры"; return; }
    
    install_docker
    mkdir -p "$NDIR/certs" && cd "$NDIR"
    
    # Расшифровка SECRET_KEY
    echo "$SECRET" | base64 -d > secret.json 2>/dev/null || { err "Неверный SECRET_KEY"; return; }
    
    python3 -c "
import json
with open('$NDIR/secret.json') as f:
    d=json.load(f)
for k,v in d.items():
    fname = k.replace('Pem','.pem') if 'Pem' in k else k
    open(f'$NDIR/certs/{fname}', 'w').write(v.replace('\\n','\n'))
" 2>/dev/null || { err "Ошибка расшифровки — нужен python3"; return; }
    
    local VER=$(get_latest_node)
    ok "Версия ноды: $VER"
    
    cat > "$NDIR/docker-compose.yml" << 'COMPOSE'
services:
  node:
    image: remnawave/node:__VER__
    container_name: rw-node
    network_mode: host
    privileged: true
    cap_add: [NET_ADMIN]
    environment:
      - NODE_PORT=2222
      - PANEL_URL=wss://__PANEL_URL__
      - SECRET_KEY=__SECRET__
      - CERT_KEY_PATH=/app/cert/node.key
      - CERT_CERT_PATH=/app/cert/node.crt
      - CA_CERT_PATH=/app/cert/ca.crt
      - JWT_PUBLIC_KEY_PATH=/app/cert/jwt.pub
    volumes:
      - __NDIR__/certs:/app/cert:ro
    restart: always
COMPOSE
    sed -i "s|__VER__|$VER|; s|__PANEL_URL__|$PANEL_URL|; s|__SECRET__|$SECRET|; s|__NDIR__|$NDIR|" "$NDIR/docker-compose.yml"
    
    docker compose up -d
    ok "Нода установлена! Проверьте статус в панели."
}

# === 3. НАСТРОЙКА HYSTERIA2 ===
setup_hysteria2() {
    step "Настройка Hysteria2 на ноде"
    local NDIR=$(find_node_dir)
    [[ -z "$NDIR" ]] && { err "Нода не найдена. Сначала установите ноду (пункт 2)"; return; }
    ok "Нода: $NDIR"
    
    local PANEL_URL=$(grep 'PANEL_URL=' "$NDIR/docker-compose.yml" | head -1 | sed 's/.*wss:\/\///' | tr -d '"' || echo "")
    [[ -z "$PANEL_URL" ]] && read -rp "IP/Домен панели: " PANEL_URL
    
    read -rp "Домен Hysteria2 (например, h2.yourdomain.com): " H2_DOMAIN
    [[ -z "$H2_DOMAIN" ]] && { err "Домен обязателен"; return; }
    
    read -rp "Порт Hysteria2 [443]: " H2_PORT; H2_PORT=${H2_PORT:-443}
    
    install_docker
    
    # acme.sh для H2
    if [[ ! -d "$HOME/.acme.sh" ]]; then
        curl https://get.acme.sh | sh -s email="admin@$H2_DOMAIN"
    fi
    export PATH="$HOME/.acme.sh:$PATH"
    
    mkdir -p "$NDIR/hysteria"
    acme.sh --issue --standalone -d "$H2_DOMAIN" --key-file "$NDIR/hysteria/h2.key" --fullchain-file "$NDIR/hysteria/h2.crt" --alpn --tlsport 8443
    acme.sh --install-cert -d "$H2_DOMAIN" --key-file "$NDIR/hysteria/h2.key" --fullchain-file "$NDIR/hysteria/h2.crt" --reloadcmd "docker compose -f $NDIR/docker-compose.yml restart 2>/dev/null || true"
    
    # Hysteria2 docker-compose overlay
    cat > "$NDIR/docker-compose.yml" << 'COMPOSE'
services:
  node:
    image: remnawave/node:latest
    container_name: rw-node
    network_mode: host
    privileged: true
    cap_add: [NET_ADMIN]
    environment:
      - NODE_PORT=2222
      - PANEL_URL=wss://__PANEL_URL__
      - SECRET_KEY=__SECRET__
      - CERT_KEY_PATH=/app/cert/node.key
      - CERT_CERT_PATH=/app/cert/node.crt
      - CA_CERT_PATH=/app/cert/ca.crt
      - JWT_PUBLIC_KEY_PATH=/app/cert/jwt.pub
    volumes:
      - __NDIR__/certs:/app/cert:ro
      - __NDIR__/hysteria:/app/hysteria:ro
    restart: always
  hysteria2:
    image: tobyxdd/hysteria2:latest
    container_name: rw-hysteria2
    network_mode: host
    privileged: true
    cap_add: [NET_ADMIN]
    volumes:
      - __NDIR__/hysteria:/etc/hysteria:ro
    command: ["server", "-c", "/etc/hysteria/server.yaml"]
    restart: always
COMPOSE

    cat > "$NDIR/hysteria/server.yaml" << EOF
listen: :$H2_PORT
tls:
  cert: /etc/hysteria/h2.crt
  key: /etc/hysteria/h2.key
auth:
  type: password
  password: $(openssl rand -hex 32)
masquerade:
  type: proxy
  proxy:
    url: https://$H2_DOMAIN
    rewriteHost: true
bandwidth:
  up: 1 gbps
  down: 1 gbps
EOF
    
    local SECRET=$(grep 'SECRET_KEY=' "$NDIR/docker-compose.yml" | head -1 | sed 's/.*=//' || echo "")
    sed -i "s|__PANEL_URL__|$PANEL_URL|; s|__SECRET__|$SECRET|; s|__NDIR__|$NDIR|" "$NDIR/docker-compose.yml"
    
    docker compose -f "$NDIR/docker-compose.yml" up -d
    ok "Hysteria2 настроен на порту $H2_PORT"
    echo -e "${YEL}Добавьте Hysteria2 инбаунд в панели (порт $H2_PORT)${R}"
}

# === 4. ОБНОВЛЕНИЕ XRAY / НОДЫ ===
update_xray() {
    echo ""
    echo "1. Обновить ноду (docker compose pull)"
    echo "2. Установить кастомное ядро Xray"
    echo "3. Удалить кастомное ядро (использовать встроенное)"
    echo "0. Назад"
    read -rp "> " ux
    
    case $ux in
        1) update_node_docker;;
        2) install_custom_xray;;
        3) remove_custom_xray;;
        0) return;;
    esac
}

update_node_docker() {
    step "Обновление ноды"
    local NDIR=$(find_node_dir)
    [[ -z "$NDIR" ]] && { err "Нода не найдена"; return; }
    ok "Нода: $NDIR"
    
    info "docker compose pull && up -d..."
    cd "$NDIR" && docker compose pull && docker compose up -d
    
    sleep 3
    if docker ps --format '{{.Names}}' | grep -q 'rw-node'; then
        ok "Нода обновлена"
        docker logs --tail 15 rw-node
    else
        err "Нода не запустилась"
        docker logs --tail 30 rw-node 2>/dev/null || true
    fi
}

install_custom_xray() {
    step "Установка кастомного ядра Xray"
    local NDIR=$(find_node_dir)
    [[ -z "$NDIR" ]] && { err "Нода не найдена"; return; }
    ok "Нода: $NDIR"
    
    read -rp "Папка custom-xray [$NDIR/custom-xray]: " CXDIR
    CXDIR=${CXDIR:-$NDIR/custom-xray}
    
    read -rp "Версия Xray (например 3.0.0, v25.3.31, или 'latest'): " XVER
    [[ -z "$XVER" ]] && { err "Версия обязательна"; return; }
    
    # Установка зависимостей
    apt-get install -y -qq curl unzip 2>/dev/null || true
    
    # Определение URL
    local URL=""
    if [[ "$XVER" == "latest" ]]; then
        local LATEST=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        [[ -z "$LATEST" ]] && { err "Не удалось получить latest версию"; return; }
        XVER="$LATEST"
        ok "Latest версия: $XVER"
    fi
    
    # Формат версии (добавляем v если нет)
    [[ "$XVER" != v* ]] && URL="https://github.com/XTLS/Xray-core/releases/download/v${XVER}/Xray-linux-64.zip" || URL="https://github.com/XTLS/Xray-core/releases/download/${XVER}/Xray-linux-64.zip"
    
    mkdir -p "$CXDIR"
    cd "$CXDIR"
    
    info "Скачивание Xray $XVER..."
    rm -f xray Xray-linux-64.zip
    
    if ! curl -fsSL -o Xray-linux-64.zip "$URL"; then
        err "Не удалось скачать: $URL"
        # Пробуем без v префикса
        URL="https://github.com/XTLS/Xray-core/releases/download/${XVER}/Xray-linux-64.zip"
        info "Пробуем: $URL"
        curl -fsSL -o Xray-linux-64.zip "$URL" || { err "Тоже не сработало"; return; }
    fi
    
    unzip -o Xray-linux-64.zip xray 2>/dev/null || { err "Ошибка распаковки"; return; }
    rm -f Xray-linux-64.zip
    chmod +x xray
    
    ok "Xray $XVER установлен в $CXDIR/xray"
    ls -la "$CXDIR/xray"
    
    # Добавляем volume в docker-compose если нет
    if ! grep -q 'custom-xray' "$NDIR/docker-compose.yml"; then
        info "Добавление volume custom-xray в docker-compose..."
        sed -i "/certs:\/app\/cert:ro/a\      - $CXDIR:/app/custom-xray:ro" "$NDIR/docker-compose.yml"
        ok "Volume добавлен"
    fi
    
    # Перезапуск
    info "Перезапуск ноды..."
    cd "$NDIR" && docker compose restart
    sleep 2
    
    if docker ps --format '{{.Names}}' | grep -q 'rw-node'; then
        ok "Нода перезапущена с кастомным Xray $XVER"
        docker logs --tail 10 rw-node
    else
        err "Нода не запустилась"
    fi
}

remove_custom_xray() {
    step "Удаление кастомного ядра Xray"
    local NDIR=$(find_node_dir)
    [[ -z "$NDIR" ]] && { err "Нода не найдена"; return; }
    
    read -rp "Удалить $NDIR/custom-xray/xray? [y/N]: " ans
    [[ ! "$ans" =~ ^[Yy]$ ]] && return
    
    rm -f "$NDIR/custom-xray/xray"
    
    # Удаляем volume из docker-compose
    sed -i '/custom-xray/d' "$NDIR/docker-compose.yml"
    
    cd "$NDIR" && docker compose restart
    ok "Кастомное ядро удалено. Нода использует встроенный Xray."
}

# === 5. ПЕРЕЗАПУСК НОДЫ ===
restart_node() {
    step "Перезапуск ноды"
    local NDIR=$(find_node_dir)
    if [[ -z "$NDIR" ]]; then
        err "Нода не найдена"
        return
    fi
    ok "Нода: $NDIR"
    
    cd "$NDIR" && docker compose restart
    sleep 2
    
    if docker ps --format '{{.Names}}' | grep -q 'rw-node'; then
        ok "Нода перезапущена"
    else
        err "Нода не запустилась"
    fi
}

# === 6. ЛОГИ ===
view_logs() {
    echo ""
    echo "1. Логи панели (backend)"
    echo "2. Логи базы данных"
    echo "3. Логи ноды"
    echo "4. Логи Hysteria2"
    echo "5. Логи Nginx"
    echo "0. Назад"
    read -rp "> " log_choice
    
    case $log_choice in
        1)
            local PDIR=$(find_panel_dir 2>/dev/null)
            [[ -n "$PDIR" ]] && { cd "$PDIR" && docker compose logs -f --tail 100 backend 2>/dev/null; } || err "Панель не найдена"
            ;;
        2)
            local PDIR=$(find_panel_dir 2>/dev/null)
            [[ -n "$PDIR" ]] && { cd "$PDIR" && docker compose logs -f --tail 100 db 2>/dev/null; } || err "Панель не найдена"
            ;;
        3)
            docker logs -f --tail 100 rw-node 2>/dev/null || err "Нода не запущена"
            ;;
        4)
            docker logs -f --tail 100 rw-hysteria2 2>/dev/null || err "Hysteria2 не запущен"
            ;;
        5)
            docker logs -f --tail 100 rw-nginx 2>/dev/null || err "Nginx не запущен"
            ;;
        0) return;;
    esac
}

# === 7. ОБНОВЛЕНИЕ SSL ===
renew_ssl() {
    step "Обновление SSL сертификатов"
    
    if [[ ! -d "$HOME/.acme.sh" ]]; then
        err "acme.sh не установлен"
        return
    fi
    export PATH="$HOME/.acme.sh:$PATH"
    
    local PDIR=$(find_panel_dir 2>/dev/null)
    local DOMAINS=()
    
    # Собираем все домены
    if [[ -n "$PDIR" && -f "$PDIR/.env" ]]; then
        local PD=$(grep FRONT_END_DOMAIN "$PDIR/.env" | cut -d= -f2)
        local SD=$(grep SUB_PUBLIC_DOMAIN "$PDIR/.env" | cut -d= -f2)
        [[ -n "$PD" ]] && DOMAINS+=("$PD")
        [[ -n "$SD" && "$SD" != "$PD" ]] && DOMAINS+=("$SD")
    fi
    
    # Hysteria2 домены
    local NDIR=$(find_node_dir 2>/dev/null)
    if [[ -n "$NDIR" && -f "$NDIR/hysteria/server.yaml" ]]; then
        local H2_DOMAIN=$(grep 'url:' "$NDIR/hysteria/server.yaml" | sed 's/.*https:\/\///' 2>/dev/null)
        [[ -n "$H2_DOMAIN" ]] && DOMAINS+=("$H2_DOMAIN")
    fi
    
    if [[ ${#DOMAINS[@]} -eq 0 ]]; then
        warn "Домены не найдены, введите вручную"
        read -rp "Домен: " d
        [[ -n "$d" ]] && DOMAINS+=("$d")
    fi
    
    for d in "${DOMAINS[@]}"; do
        info "Обновление: $d"
        acme.sh --renew -d "$d" --force || acme.sh --issue --standalone -d "$d" --force
    done
    
    # Перезапуск nginx
    docker restart rw-nginx 2>/dev/null || true
    ok "SSL обновлён"
}

# === 8. ПЕРЕКЛЮЧЕНИЕ ВЕТКИ ===
switch_branch() {
    step "Переключение ветки (stable / dev)"
    
    echo "Текущие версии:"
    echo "  Панель: $(grep 'remnawave/backend:' "$(find_panel_dir)/docker-compose.yml" 2>/dev/null | sed 's/.*://' | tr -d ' "' || echo "N/A")"
    echo "  Нода:   $(grep 'remnawave/node:' "$(find_node_dir)/docker-compose.yml" 2>/dev/null | sed 's/.*://' | tr -d ' "' || echo "N/A")"
    echo ""
    echo "1. Stable (latest)"
    echo "2. Dev (тестовая)"
    echo "3. Конкретная версия"
    echo "0. Назад"
    read -rp "> " b
    
    local PDIR=$(find_panel_dir 2>/dev/null)
    local NDIR=$(find_node_dir 2>/dev/null)
    
    case $b in
        1)
            local PV=$(get_latest_panel)
            local NV=$(get_latest_node)
            [[ -n "$PDIR" ]] && { sed -i "s|remnawave/backend:.*|remnawave/backend:$PV|" "$PDIR/docker-compose.yml"; cd "$PDIR" && docker compose up -d; }
            [[ -n "$NDIR" ]] && { sed -i "s|remnawave/node:.*|remnawave/node:$NV|" "$NDIR/docker-compose.yml"; cd "$NDIR" && docker compose up -d; }
            ok "Переключено на stable: panel=$PV node=$NV"
            ;;
        2)
            [[ -n "$PDIR" ]] && { sed -i 's|remnawave/backend:.*|remnawave/backend:dev|' "$PDIR/docker-compose.yml"; cd "$PDIR" && docker compose up -d; }
            [[ -n "$NDIR" ]] && { sed -i 's|remnawave/node:.*|remnawave/node:dev|' "$NDIR/docker-compose.yml"; cd "$NDIR" && docker compose up -d; }
            ok "Переключено на dev"
            ;;
        3)
            read -rp "Версия панели (например 2.8.0): " PV
            read -rp "Версия ноды (например latest): " NV
            [[ -n "$PDIR" && -n "$PV" ]] && { sed -i "s|remnawave/backend:.*|remnawave/backend:$PV|" "$PDIR/docker-compose.yml"; cd "$PDIR" && docker compose up -d; }
            [[ -n "$NDIR" && -n "$NV" ]] && { sed -i "s|remnawave/node:.*|remnawave/node:$NV|" "$NDIR/docker-compose.yml"; cd "$NDIR" && docker compose up -d; }
            ok "Установлены версии: panel=${PV:-N/A} node=${NV:-N/A}"
            ;;
        0) return;;
    esac
}

# === МИГРАЦИЯ ===
migrate() {
    while true; do
        clear
        echo -e "${PUR}=== Миграция ===${R}"
        echo "1. Бэкап (с этого сервера)"
        echo "2. Бэкап только базы данных"
        echo "3. Восстановление (на этот сервер)"
        echo "4. Перенос на другой сервер (rsync)"
        echo "0. Назад"
        read -rp "> " c
        case $c in
            1) backup;;
            2) backup_db;;
            3) restore;;
            4) transfer_remote;;
            0) break;;
        esac
    done
}

# === БЭКАП ВСЕГО ===
backup() {
    step "Бэкап панели"
    
    local PDIR=$(find_panel_dir)
    [[ -z "$PDIR" ]] && { err "Панель не найдена"; return; }
    ok "Панель найдена: $PDIR"
    
    local NAME="remnawave_backup_$(date +%Y-%m-%d_%H_%M_%S)"
    local OUT="/tmp/$NAME.tar.gz"
    
    info "Остановка панели..."
    cd "$PDIR" && docker compose down
    
    info "Архивация..."
    tar czf "$OUT" -C "$(dirname "$PDIR")" "$(basename "$PDIR")"
    
    cd "$PDIR" && docker compose up -d
    
    ok "Бэкап: $OUT ($(du -h "$OUT" | cut -f1))"
    echo -e "${YEL}Для переноса на новый сервер:${R}"
    echo "  rsync -avz --progress -e ssh $OUT root@NEW_SERVER_IP:/tmp/"
}

# === БЭКАП ТОЛЬКО БАЗЫ ===
backup_db() {
    step "Бэкап базы данных"
    
    local PDIR=$(find_panel_dir)
    [[ -z "$PDIR" ]] && { err "Панель не найдена"; return; }
    
    local DB_PASS=$(grep POSTGRES_PASSWORD "$PDIR/.env" | cut -d= -f2)
    local NAME="remnawave_db_$(date +%Y-%m-%d_%H_%M_%S).sql"
    local OUT="/tmp/$NAME"
    
    info "Дамп БД..."
    docker exec rw-db pg_dump -U postgres -d postgres > "$OUT"
    
    gzip "$OUT"
    ok "Бэкап БД: ${OUT}.gz ($(du -h "${OUT}.gz" | cut -f1))"
}

# === ВОССТАНОВЛЕНИЕ ===
restore() {
    step "Восстановление панели"
    
    # Поиск бэкапов
    local BACKUPS=()
    while IFS= read -r f; do BACKUPS+=("$f"); done < <(find /tmp /root /opt /home -maxdepth 2 -name "remnawave_backup_*.tar.gz" 2>/dev/null | sort -r)
    
    if [[ ${#BACKUPS[@]} -gt 0 ]]; then
        echo "Найдены бэкапы:"
        for i in "${!BACKUPS[@]}"; do
            echo "  $((i+1)). ${BACKUPS[$i]} ($(du -h "${BACKUPS[$i]}" | cut -f1))"
        done
        echo "  0. Указать путь вручную"
        read -rp "> " sel
        if [[ "$sel" =~ ^[1-9][0-9]*$ && "$sel" -le ${#BACKUPS[@]} ]]; then
            local F="${BACKUPS[$((sel-1))]}"
        else
            read -rp "Путь к файлу: " F
        fi
    else
        read -rp "Путь к файлу бэкапа: " F
    fi
    
    [[ ! -f "$F" ]] && { err "Файл не найден"; return; }
    ok "Файл: $F"
    
    install_docker
    
    # Распаковка во временную папку
    local TMP="/tmp/rw-restore-$$"
    rm -rf "$TMP"; mkdir -p "$TMP"
    tar xzf "$F" -C "$TMP"
    
    # Определение папки внутри
    local SRC="$TMP"
    local SUB=$(ls -1 "$TMP" 2>/dev/null | head -1)
    [[ -d "$TMP/$SUB" && $(ls -1 "$TMP" | wc -l) -eq 1 ]] && SRC="$TMP/$SUB"
    
    # Определение директории назначения
    local PDIR=$(find_panel_dir 2>/dev/null || true)
    if [[ -n "$PDIR" ]]; then
        warn "Найдена панель: $PDIR"
        read -rp "Восстановить в эту же папку? [Y/n]: " ans
        [[ "$ans" =~ ^[Nn]$ ]] && read -rp "Новая папка: " PDIR
    else
        read -rp "Папка для восстановления [/opt/remnawave]: " PDIR
        PDIR=${PDIR:-/opt/remnawave}
    fi
    
    # Остановка
    [[ -d "$PDIR" ]] && { cd "$PDIR" && docker compose down 2>/dev/null || true; }
    
    # Копирование
    mkdir -p "$PDIR"
    rsync -a --delete "$SRC/" "$PDIR/" 2>/dev/null || cp -r "$SRC/"* "$PDIR/"
    
    # Фикс версии
    local VER=$(get_latest_panel)
    sed -i "s|remnawave/backend:latest|remnawave/backend:$VER|g" "$PDIR/docker-compose.yml"
    sed -i "s|remnawave/backend:2$|remnawave/backend:$VER|" "$PDIR/docker-compose.yml"
    sed -i "s|remnawave/backend:2 |remnawave/backend:$VER |" "$PDIR/docker-compose.yml"
    
    # Запуск
    cd "$PDIR" && docker compose up -d
    
    rm -rf "$TMP"
    ok "Восстановлено в: $PDIR"
    echo -e "${YEL}Обновите DNS записи на IP этого сервера${R}"
}

# === ПЕРЕНОС НА ДРУГОЙ СЕРВЕР ===
transfer_remote() {
    step "Перенос на другой сервер через rsync"
    
    local PDIR=$(find_panel_dir)
    [[ -z "$PDIR" ]] && { err "Панель не найдена"; return; }
    
    read -rp "IP нового сервера: " NEW_IP
    [[ -z "$NEW_IP" ]] && { err "IP обязателен"; return; }
    
    read -rp "SSH порт нового сервера [22]: " SSH_PORT; SSH_PORT=${SSH_PORT:-22}
    read -rp "Пользователь на новом сервере [root]: " USER; USER=${USER:-root}
    
    # Проверка rsync
    if ! command -v rsync &>/dev/null; then
        info "Установка rsync..."
        apt-get install -y rsync
    fi
    
    # Бэкап БД отдельно
    local DB_PASS=$(grep POSTGRES_PASSWORD "$PDIR/.env" | cut -d= -f2)
    local DB_TMP="/tmp/rw_db_$(date +%s).sql.gz"
    info "Создание дампа БД..."
    docker exec rw-db pg_dump -U postgres -d postgres | gzip > "$DB_TMP"
    
    # Остановка
    info "Остановка панели..."
    cd "$PDIR" && docker compose down
    
    # Перенос через rsync
    info "Перенос файлов через rsync..."
    rsync -avz --progress -e "ssh -p $SSH_PORT" "$PDIR/" "$USER@$NEW_IP:$PDIR/"
    
    # Запуск на старом
    cd "$PDIR" && docker compose up -d
    
    # Перенос БД
    info "Перенос дампа БД..."
    rsync -avz --progress -e "ssh -p $SSH_PORT" "$DB_TMP" "$USER@$NEW_IP:/tmp/"
    
    rm -f "$DB_TMP"
    
    ok "Файлы перенесены!"
    echo -e "${YEL}Действия на новом сервере ($NEW_IP):${R}"
    echo "  1. Установите Docker: curl -fsSL https://get.docker.com | sh"
    echo "  2. Разверните БД: gunzip -c $DB_TMP | docker exec -i rw-db psql -U postgres"
    echo "  3. Запустите: cd $PDIR && docker compose up -d"
    echo "  4. Обновите DNS на $NEW_IP"
    echo "  5. Настройте Nginx + SSL (пункт 1 в меню скрипта)"
}

# === МЕНЮ ===
while true; do
    clear
    echo -e "${PUR}╔══════════════════════════════════════════╗${R}"
    echo -e "${PUR}║     Remnawave Utility v3.0               ║${R}"
    echo -e "${PUR}╚══════════════════════════════════════════╝${R}"
    echo ""
    echo " 1. Установить панель"
    echo " 2. Установить ноду"
    echo " 3. Настроить Hysteria2 (SSL + H2)"
    echo " 4. Обновить Xray ядро / ноду"
    echo " 5. Перезапустить ноду"
    echo " 6. Логи (панель/нода/nginx)"
    echo " 7. Обновить SSL (acme.sh)"
    echo " 8. Переключить ветку (stable/dev)"
    echo " 9. Миграция (Бэкап/Восстановление/Перенос)"
    echo " 0. Выход"
    echo ""
    read -rp "▶ " c
    case $c in
        1) install_panel;;
        2) install_node;;
        3) setup_hysteria2;;
        4) update_xray;;
        5) restart_node;;
        6) view_logs;;
        7) renew_ssl;;
        8) switch_branch;;
        9) migrate;;
        0) exit 0;;
    esac
    read -rp "Нажмите Enter..."
done
