#!/bin/bash
# ============================================================
#  Remnawave — Универсальный инструмент
#  Установка панели, ноды, миграция, бэкап
#  https://github.com/masterRaizer/toolforpanel
# ============================================================

set -e

# Цвета для вывода
CLR='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'

# Папки установки
INSTALL_DIR="/opt/remnawave"          # Папка панели
NGINX_DIR="$INSTALL_DIR/nginx"         # Папка nginx
SUB_DIR="$INSTALL_DIR/subscription"    # Папка подписок
NODE_DIR="/opt/remnanode"             # Папка ноды
LOG_FILE="/var/log/remnawave-install.log"

# Домены (будут запрошены у пользователя)
PANEL_DOMAIN=""
SUB_DOMAIN=""

# ============================================================
# Вспомогательные функции
# ============================================================
info()    { echo -e "${BLUE}[*]${CLR} $1"; }
ok()      { echo -e "${GREEN}[OK]${CLR} $1"; }
warn()    { echo -e "${YELLOW}[!]${CLR} $1"; }
err()     { echo -e "${RED}[ОШИБКА]${CLR} $1"; }
step()    { echo -e "\n${CYAN}==>${CLR} ${BOLD}$1${CLR}"; }

# Проверка root-прав
require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Скрипт нужно запускать от root. Используйте: ${YELLOW}sudo su -${CLR}"
        exit 1
    fi
}

# Заголовок
header() {
    echo ""
    echo -e "${PURPLE}    ╔══════════════════════════════════════════════════════════╗${CLR}"
    echo -e "${PURPLE}    ║         Remnawave — Универсальный инструмент             ║${CLR}"
    echo -e "${PURPLE}    ║         Панель + Нода + Миграция + Бэкап               ║${CLR}"
    echo -e "${PURPLE}    ╚══════════════════════════════════════════════════════════╝${CLR}"
    echo ""
}

# Безопасная установка пакетов
safe_apt_install() {
    info "Установка пакетов: $@"
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
# Установка Docker
# ============================================================
install_docker() {
    step "Проверка Docker"
    if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
        ok "Docker уже установлен: $(docker --version | awk '{print $3}' | tr -d ',')"
        return 0
    fi
    info "Установка Docker..."
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
    systemctl enable docker --now >/dev/null 2>&1
    ok "Docker установлен!"
}

# ============================================================
# Генерация секретных ключей
# ============================================================
generate_secrets() {
    step "Генерация секретных ключей"
    JWT_AUTH_SECRET=$(openssl rand -hex 64)
    JWT_API_TOKENS_SECRET=$(openssl rand -hex 64)
    APP_SECRET=$(openssl rand -hex 64)
    METRICS_PASS=$(openssl rand -hex 64)
    WEBHOOK_SECRET=$(openssl rand -hex 64 | head -c 64)
    POSTGRES_PASSWORD=$(openssl rand -hex 24)
    ok "Ключи сгенерированы"
}

# ============================================================
# Запрос доменов у пользователя
# ============================================================
ask_domains() {
    step "Настройка доменов"
    if [[ -z "$PANEL_DOMAIN" ]]; then
        read -rp "Введите домен панели (например: panel.example.com): " PANEL_DOMAIN
    fi
    if [[ -z "$SUB_DOMAIN" ]]; then
        read -rp "Введите домен подписок (например: sub.example.com): " SUB_DOMAIN
    fi
    ok "Домен панели:    ${GREEN}$PANEL_DOMAIN${CLR}"
    ok "Домен подписок:  ${GREEN}$SUB_DOMAIN${CLR}"
}

# ============================================================
# 1. УСТАНОВКА ПАНЕЛИ
# ============================================================
install_panel() {
    header
    require_root
    
    # Проверка существующей установки
    if [[ -d "$INSTALL_DIR" ]] && docker ps --format '{{.Names}}' | grep -q "remnawave"; then
        warn "Панель уже установлена!"
        read -rp "Продолжить и перезаписать? [y/N]: " overwrite
        [[ "$overwrite" =~ ^[Yy]$ ]] || { return; }
    fi
    
    ask_domains
    install_docker
    generate_secrets
    
    # Скачивание конфигов
    step "Скачивание файлов конфигурации"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    info "Скачивание docker-compose.yml..."
    curl -fsSL -o docker-compose.yml \
        "https://raw.githubusercontent.com/remnawave/backend/main/docker-compose-prod.yml" 2>/dev/null
    sed -i 's|remnawave/backend:2$|remnawave/backend:2.8.0|' docker-compose.yml
    sed -i 's|remnawave/backend:2 |remnawave/backend:2.8.0 |' docker-compose.yml
    
    info "Скачивание .env..."
    curl -fsSL -o .env \
        "https://raw.githubusercontent.com/remnawave/backend/main/.env.sample" 2>/dev/null
    
    # Настройка .env
    step "Настройка переменных окружения"
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
    
    # Запуск панели
    step "Запуск Remnawave Panel 2.8.0"
    docker compose up -d
    
    info "Ожидание запуска сервисов..."
    for i in {1..60}; do
        if curl -fs http://127.0.0.1:3001/health &>/dev/null; then
            ok "Панель запущена и работает!"
            break
        fi
        sleep 1
    done
    
    # Установка Nginx + SSL
    setup_nginx
    
    # Установка страницы подписок
    setup_subscription
    
    # Сохранение данных
    save_credentials
    show_summary
}

# ============================================================
# Nginx + SSL (автоматические сертификаты)
# ============================================================
setup_nginx() {
    step "Настройка Nginx с SSL"
    mkdir -p "$NGINX_DIR"
    cd "$NGINX_DIR"
    
    apt-get install -y -qq cron socat
    
    # Установка acme.sh для SSL
    if [[ ! -d "$HOME/.acme.sh" ]]; then
        curl https://get.acme.sh | sh -s email="admin@$PANEL_DOMAIN" >/dev/null 2>&1
    fi
    export PATH="$HOME/.acme.sh:$PATH"
    
    # Получение сертификатов
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
    
    # Получение IP контейнеров
    REMNAWAVE_IP=$(docker network inspect remnawave-network --format "{{range .Containers}}{{if eq .Name \"remnawave\"}}{{.IPv4Address}}{{end}}{{end}}" | cut -d/ -f1)
    SUB_IP=$(docker network inspect remnawave-network --format "{{range .Containers}}{{if eq .Name \"remnawave-subscription-page\"}}{{.IPv4Address}}{{end}}{{end}}" | cut -d/ -f1)
    
    # Создание nginx.conf
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
    
    # Сервер для подписок (если домен отдельный)
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
    
    # Заглушка для неизвестных доменов
    cat >> "$NGINX_DIR/nginx.conf" << EOF
server { listen 443 ssl default_server; server_name _; ssl_reject_handshake on; }
EOF
    
    # Docker Compose для Nginx
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
    ok "Nginx запущен на порту 443"
}

# ============================================================
# Страница подписок
# ============================================================
setup_subscription() {
    step "Настройка страницы подписок"
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
REMNAWAVE_API_TOKEN=ВАШ_API_ТОКЕН
TRUST_PROXY=true
CUSTOM_SUB_PREFIX=
MARZBAN_LEGACY_LINK_ENABLED=false
SUB_PUBLIC_DOMAIN=\${SUB_DOMAIN}
EOF
    
    docker compose up -d
    ok "Страница подписок запущена на порту 3010"
    warn "ВАЖНО: Отредактируйте $SUB_DIR/.env и укажите ваш REMNAWAVE_API_TOKEN"
}

# ============================================================
# 2. УСТАНОВКА НОДЫ
# ============================================================
install_node() {
    step "Установка Remnawave Node"
    bash <(curl -Ls https://raw.githubusercontent.com/nerioff1337/remnawave-node-auto/refs/heads/main/install.sh)
    ok "Нода установлена!"
    read -rp "Нажмите Enter..."
}

# ============================================================
# 3. НАСТРОЙКА HYSTERIA2
# ============================================================
setup_hysteria2() {
    step "Настройка Hysteria2"
    read -rp "Папка ноды [/opt/remnanode]: " NODE_PATH
    NODE_PATH=${NODE_PATH:-/opt/remnanode}
    read -rp "Домен ноды (например: node.example.com): " DOMAIN
    
    safe_apt_install certbot
    
    CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    
    # Получение SSL если нет
    if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
        certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos \
            --register-unsafely-without-email \
            --deploy-hook "docker compose -f $NODE_PATH/docker-compose.yml restart remnanode"
    fi
    
    # Обновление docker-compose
    COMPOSE="$NODE_PATH/docker-compose.yml"
    cp "$COMPOSE" "${COMPOSE}.bak"
    
    sed -i -E 's|remnawave/node:[a-zA-Z0-9_.-]+|remnawave/node:latest|g' "$COMPOSE"
    sed -i '/\/var\/lib\/remnawave\/configs\/xray\/ssl/d' "$COMPOSE"
    
    # Добавление SSL в volumes
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
    
    ok "Hysteria2 настроен!"
    read -rp "Нажмите Enter..."
}

# ============================================================
# 4. ОБНОВЛЕНИЕ ЯДРА XRAY
# ============================================================
update_xray_core() {
    step "Обновление ядра Xray"
    read -rp "Папка custom-xray [/opt/remnanode/custom-xray]: " CX_DIR
    CX_DIR=${CX_DIR:-/opt/remnanode/custom-xray}
    read -rp "Папка ноды [/opt/remnanode]: " NODE_PATH
    NODE_PATH=${NODE_PATH:-/opt/remnanode}
    read -rp "Версия [latest]: " VER
    VER=${VER:-latest}
    
    safe_apt_install curl unzip
    mkdir -p "$CX_DIR"
    cd "$CX_DIR"
    
    # Определение версии
    if [[ "$VER" == "latest" ]]; then
        VER=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    fi
    
    info "Скачивание Xray $VER..."
    wget -qO Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/download/${VER}/Xray-linux-64.zip"
    unzip -o Xray-linux-64.zip >/dev/null
    chmod +x xray
    
    # Подключение к ноде
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
    
    ok "Xray обновлён до $VER!"
    read -rp "Нажмите Enter..."
}

# ============================================================
# 5. ПЕРЕЗАПУСК НОДЫ
# ============================================================
restart_node() {
    step "Перезапуск ноды"
    read -rp "Папка ноды [/opt/remnanode]: " NODE_PATH
    NODE_PATH=${NODE_PATH:-/opt/remnanode}
    docker compose -f "$NODE_PATH/docker-compose.yml" restart remnanode
    ok "Нода перезапущена!"
    read -rp "Нажмите Enter..."
}

# ============================================================
# 6. ПРОСМОТР ЛОГОВ
# ============================================================
view_logs() {
    step "Логи ноды"
    read -rp "Папка ноды [/opt/remnanode]: " NODE_PATH
    NODE_PATH=${NODE_PATH:-/opt/remnanode}
    echo -e "${YELLOW}Нажмите Ctrl+C для выхода${CLR}"
    docker compose -f "$NODE_PATH/docker-compose.yml" logs -f --tail 50 remnanode
}

# ============================================================
# 7. ОБНОВЛЕНИЕ SSL СЕРТИФИКАТОВ
# ============================================================
renew_certs() {
    step "Обновление SSL сертификатов"
    certbot renew --force-renewal
    ok "Сертификаты обновлены!"
    read -rp "Нажмите Enter..."
}

# ============================================================
# 8. ПЕРЕКЛЮЧЕНИЕ ВЕТКИ (stable/dev)
# ============================================================
switch_branch() {
    step "Переключение ветки"
    echo -e "  ${YELLOW}1.${CLR} Нода"
    echo -e "  ${YELLOW}2.${CLR} Панель"
    echo -e "  ${YELLOW}3.${CLR} Свой путь"
    read -rp "Выберите (1-3): " choice
    case $choice in
        1) DEFAULT="/opt/remnanode" ;;
        2) DEFAULT="/opt/remnawave" ;;
        3) DEFAULT="" ;;
        *) return ;;
    esac
    read -rp "Путь [$DEFAULT]: " PATH_DIR
    PATH_DIR=${PATH_DIR:-$DEFAULT}
    COMPOSE="$PATH_DIR/docker-compose.yml"
    
    [[ ! -f "$COMPOSE" ]] && { err "Файл не найден!"; read -rp "Нажмите Enter..."; return; }
    
    echo -e "  ${YELLOW}1.${CLR} DEV ветка (тестовая)"
    echo -e "  ${YELLOW}2.${CLR} STABLE ветка (стабильная)"
    read -rp "Выберите (1-2): " branch
    
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
    ok "Ветка переключена!"
    read -rp "Нажмите Enter..."
}

# ============================================================
# 9. МИГРАЦИЯ ПАНЕЛИ (Бэкап / Восстановление)
# ============================================================
migrate_panel() {
    while true; do
        clear
        header
        echo -e "  ${CYAN}1.${CLR} ${BOLD}Создать бэкап${CLR}       - Экспорт БД и конфигов"
        echo -e "  ${CYAN}2.${CLR} ${BOLD}Восстановить${CLR}       - Импорт на новый сервер"
        echo -e "  ${RED}0.${CLR} ${BOLD}Назад${CLR}"
        read -rp "Выберите (0-2): " choice
        case $choice in
            1) backup_panel ;;
            2) restore_panel ;;
            0) break ;;
        esac
    done
}

# ===== Создание бэкапа =====
backup_panel() {
    step "Создание бэкапа панели"
    
    # Имя файла с датой
    BACKUP_NAME="remnawave_backup_$(date +%Y-%m-%d_%H_%M_%S)"
    BACKUP_DIR="/opt/$BACKUP_NAME"
    mkdir -p "$BACKUP_DIR"
    
    info "Дамп базы данных..."
    DB_PASS=$(grep POSTGRES_PASSWORD "$INSTALL_DIR/.env" | cut -d= -f2)
    export PGPASSWORD=$DB_PASS
    pg_dump -h localhost -p 6767 -U postgres -d postgres --format=custom > "$BACKUP_DIR/db.dump"
    ok "База данных сохранена"
    
    info "Копирование конфигурационных файлов..."
    cp "$INSTALL_DIR/.env" "$BACKUP_DIR/"
    cp "$INSTALL_DIR/docker-compose.yml" "$BACKUP_DIR/"
    mkdir -p "$BACKUP_DIR/nginx"
    cp "$NGINX_DIR"/*.pem "$NGINX_DIR"/*.conf "$BACKUP_DIR/nginx/" 2>/dev/null || true
    
    # Копирование подписок если есть
    if [[ -d "$SUB_DIR" ]]; then
        cp -r "$SUB_DIR" "$BACKUP_DIR/" 2>/dev/null || true
    fi
    
    # Архивация
    tar czf "${BACKUP_DIR}.tar.gz" -C "$(dirname "$BACKUP_DIR")" "$(basename "$BACKUP_DIR")"
    rm -rf "$BACKUP_DIR"
    
    ok "Бэкап создан: ${BACKUP_DIR}.tar.gz"
    echo -e "${YELLOW}Скопируйте этот файл на новый сервер и запустите Восстановление.${CLR}"
    read -rp "Нажмите Enter..."
}

# ===== Восстановление из бэкапа =====
restore_panel() {
    step "Восстановление панели из бэкапа"
    
    # Авто-поиск файлов бэкапа
    echo -e "${CYAN}Поиск файлов бэкапа...${CLR}"
    mapfile -t BACKUPS < <(find / -maxdepth 3 \( -name "remnawave_backup_*.tar.gz" -o -name "remnawave-backup-*.tar.gz" \) 2>/dev/null | sort -r)
    
    if [[ ${#BACKUPS[@]} -gt 0 ]]; then
        echo -e "${GREEN}Найдены бэкапы:${CLR}"
        for i in "${!BACKUPS[@]}"; do
            size=$(du -h "${BACKUPS[$i]}" 2>/dev/null | cut -f1)
            echo -e "  ${YELLOW}$((i+1)).${CLR} ${BACKUPS[$i]} (${size})"
        done
        echo -e "  ${YELLOW}0.${CLR} Указать путь вручную"
        read -rp "Выберите бэкап [0-${#BACKUPS[@]}]: " sel
        
        if [[ "$sel" =~ ^[0-9]+$ && "$sel" -ge 1 && "$sel" -le ${#BACKUPS[@]} ]]; then
            BACKUP_TGZ="${BACKUPS[$((sel-1))]}"
        else
            read -rp "Введите путь к файлу бэкапа: " BACKUP_TGZ
        fi
    else
        echo -e "${YELLOW}Автоматически бэкапы не найдены.${CLR}"
        read -rp "Введите путь к файлу (например: /root/remnawave_backup_2026-07-16_00_00_07.tar.gz): " BACKUP_TGZ
    fi
    
    # Проверка файла
    [[ -z "$BACKUP_TGZ" ]] && { err "Файл не указан!"; read -rp "Нажмите Enter..."; return; }
    [[ ! -f "$BACKUP_TGZ" ]] && { err "Файл не найден: $BACKUP_TGZ"; read -rp "Нажмите Enter..."; return; }
    
    ok "Выбран: $BACKUP_TGZ"
    
    # Распаковка
    BACKUP_DIR="/opt/remnawave-restore-tmp"
    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    
    info "Распаковка бэкапа..."
    tar xzf "$BACKUP_TGZ" -C "$BACKUP_DIR"
    
    # Удаление верхней папки если есть
    if [[ $(ls -1 "$BACKUP_DIR" | wc -l) -eq 1 && -d "$BACKUP_DIR"/$(ls -1 "$BACKUP_DIR") ]]; then
        SUBDIR=$(ls -1 "$BACKUP_DIR")
        mv "$BACKUP_DIR/$SUBDIR"/* "$BACKUP_DIR/" 2>/dev/null || true
        rmdir "$BACKUP_DIR/$SUBDIR" 2>/dev/null || true
    fi
    
    # Проверка содержимого
    info "Проверка содержимого бэкапа..."
    [[ ! -f "$BACKUP_DIR/db.dump" ]] && { err "В бэкапе нет db.dump!"; rm -rf "$BACKUP_DIR"; read -rp "Нажмите Enter..."; return; }
    [[ ! -f "$BACKUP_DIR/.env" ]] && { err "В бэкапе нет .env!"; rm -rf "$BACKUP_DIR"; read -rp "Нажмите Enter..."; return; }
    [[ ! -f "$BACKUP_DIR/docker-compose.yml" ]] && { err "В бэкапе нет docker-compose.yml!"; rm -rf "$BACKUP_DIR"; read -rp "Нажмите Enter..."; return; }
    
    ok "Бэкап проверен (db.dump + .env + docker-compose.yml)"
    
    # Остановка существующей панели
    if [[ -d "$INSTALL_DIR" ]]; then
        warn "Найдена существующая панель. Остановка..."
        cd "$INSTALL_DIR"
        docker compose down 2>/dev/null || true
    fi
    
    # Установка Docker
    install_docker
    
    # Создание папок
    mkdir -p "$INSTALL_DIR" "$NGINX_DIR" "$SUB_DIR"
    
    # Копирование файлов
    cp "$BACKUP_DIR/.env" "$INSTALL_DIR/"
    cp "$BACKUP_DIR/docker-compose.yml" "$INSTALL_DIR/"
    cp "$BACKUP_DIR/nginx"/* "$NGINX_DIR/" 2>/dev/null || true
    
    # Копирование подписок если есть
    if [[ -d "$BACKUP_DIR/subscription" ]]; then
        cp -r "$BACKUP_DIR/subscription"/* "$SUB_DIR/" 2>/dev/null || true
        ok "Конфиг подписок восстановлен"
    fi
    
    # Фикс версии backend
    sed -i 's|remnawave/backend:latest|remnawave/backend:2.8.0|' "$INSTALL_DIR/docker-compose.yml"
    
    # Запуск только БД
    cd "$INSTALL_DIR"
    docker compose up -d remnawave-db
    
    info "Ожидание запуска PostgreSQL..."
    for i in {1..30}; do
        if docker exec remnawave-db pg_isready -U postgres &>/dev/null; then
            ok "База данных готова!"
            break
        fi
        sleep 1
    done
    
    # Восстановление базы данных
    DB_PASS=$(grep POSTGRES_PASSWORD "$INSTALL_DIR/.env" | cut -d= -f2)
    export PGPASSWORD=$DB_PASS
    docker exec -i remnawave-db pg_restore -U postgres -d postgres --clean --if-exists < "$BACKUP_DIR/db.dump"
    ok "База данных восстановлена!"
    
    # Фикс IP в nginx
    cd "$NGINX_DIR"
    sed -i 's|172\.18\.0\.[0-9]*:3000|remnawave:3000|g' nginx.conf 2>/dev/null || true
    sed -i 's|172\.18\.0\.[0-9]*:3010|remnawave-subscription-page:3010|g' nginx.conf 2>/dev/null || true
    
    # Запуск всех сервисов
    cd "$INSTALL_DIR"
    docker compose up -d
    cd "$NGINX_DIR"
    docker compose up -d
    
    # Получение реальных IP контейнеров
    REMNAWAVE_IP=$(docker network inspect remnawave-network --format "{{range .Containers}}{{if eq .Name \"remnawave\"}}{{.IPv4Address}}{{end}}{{end}}" | cut -d/ -f1)
    SUB_IP=$(docker network inspect remnawave-network --format "{{range .Containers}}{{if eq .Name \"remnawave-subscription-page\"}}{{.IPv4Address}}{{end}}{{end}}" | cut -d/ -f1)
    sed -i "s|proxy_pass http://remnawave:3000;|proxy_pass http://$REMNAWAVE_IP:3000;|" nginx.conf
    sed -i "s|proxy_pass http://remnawave-subscription-page:3010;|proxy_pass http://$SUB_IP:3010;|" nginx.conf
    docker compose restart
    
    rm -rf "$BACKUP_DIR"
    ok "Панель успешно восстановлена!"
    
    echo ""
    echo -e "${GREEN}========================================${CLR}"
    echo -e "${GREEN}  Восстановление завершено!${CLR}"
    echo -e "${GREEN}========================================${CLR}"
    echo -e "  ${YELLOW}Важно:${CLR} Обновите DNS записи на новый IP сервера!"
    read -rp "Нажмите Enter..."
}

# ============================================================
# Сохранение данных
# ============================================================
save_credentials() {
    cat > "$INSTALL_DIR/.credentials" << EOF
========================================
  REMNAWAVE PANEL 2.8.0
========================================
Панель:      https://${PANEL_DOMAIN}
Подписки:    https://${SUB_DOMAIN}

Папки:
  Панель:    ${INSTALL_DIR}
  Nginx:     ${NGINX_DIR}
  Нода:      ${NODE_DIR}

Команды:
  Логи:   cd ${INSTALL_DIR} && docker compose logs -f
  Стоп:   cd ${INSTALL_DIR} && docker compose down
========================================
EOF
    chmod 600 "$INSTALL_DIR/.credentials"
}

show_summary() {
    echo ""
    echo -e "${GREEN}========================================${CLR}"
    echo -e "${GREEN}  Установка завершена!${CLR}"
    echo -e "${GREEN}========================================${CLR}"
    echo -e "  ${BOLD}Панель:${CLR}      ${GREEN}https://${PANEL_DOMAIN}${CLR}"
    echo -e "  ${BOLD}Подписки:${CLR}    ${GREEN}https://${SUB_DOMAIN}${CLR}"
    echo -e "\n  ${YELLOW}Следующие шаги:${CLR}"
    echo -e "  1. Откройте https://${PANEL_DOMAIN}"
    echo -e "  2. Создайте superadmin аккаунт"
    echo -e "  3. Добавьте API токен в ${SUB_DIR}/.env"
}

# ============================================================
# ГЛАВНОЕ МЕНЮ
# ============================================================
show_menu() {
    while true; do
        clear
        header
        echo -e "  ${CYAN}1.${CLR} ${BOLD}Установить панель${CLR}      - Полная установка 2.8.0"
        echo -e "  ${CYAN}2.${CLR} ${BOLD}Установить ноду${CLR}        - Установка remnawave/node"
        echo -e "  ${CYAN}3.${CLR} ${BOLD}Настроить Hysteria2${CLR}   - H2 + SSL на ноде"
        echo -e "  ${CYAN}4.${CLR} ${BOLD}Обновить Xray${CLR}         - Обновление ядра"
        echo -e "  ${CYAN}5.${CLR} ${BOLD}Перезапустить ноду${CLR}   - Рестарт remnanode"
        echo -e "  ${CYAN}6.${CLR} ${BOLD}Просмотр логов${CLR}       - Логи ноды"
        echo -e "  ${CYAN}7.${CLR} ${BOLD}Обновить SSL${CLR}           - Обновление сертификатов"
        echo -e "  ${CYAN}8.${CLR} ${BOLD}Переключить ветку${CLR}    - stable / dev"
        echo -e "  ${CYAN}9.${CLR} ${BOLD}Миграция панели${CLR}      - Бэкап / Восстановление"
        echo -e "  ${RED}0.${CLR} ${BOLD}Выход${CLR}"
        echo ""
        read -rp "Выберите [0-9]: " choice
        
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
            0) echo -e "${GREEN}До свидания!${CLR}"; exit 0 ;;
            *) warn "Неверная опция"; sleep 1 ;;
        esac
    done
}

# Неинтерактивный режим
if [[ "${1:-}" == "install" ]]; then
    PANEL_DOMAIN="${2:-}"
    SUB_DOMAIN="${3:-}"
    [[ -z "$PANEL_DOMAIN" || -z "$SUB_DOMAIN" ]] && { err "Использование: $0 install <panel_domain> <sub_domain>"; exit 1; }
    install_panel
    exit 0
fi

# Интерактивное меню
show_menu
