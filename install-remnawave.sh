#!/bin/bash
# Remnawave Panel 2.8.0 + Subscription Page
# Чистая установка — только панель и сабка

set -e

R='\033[0m'; RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[0;34m'; CYN='\033[0;36m'; BOLD='\033[1m'
info() { echo -e "${BLU}[*]${R} $1"; }
ok()   { echo -e "${GRN}[OK]${R} $1"; }
err()  { echo -e "${RED}[ERR]${R} $1"; }
step() { echo -e "\n${CYN}▶${R} ${BOLD}$1${R}"; }

# === ПАРАМЕТРЫ ===
read -rp "Домен панели (например panel.example.com): " PANEL_DOMAIN
read -rp "Домен подписок (например sub.example.com): " SUB_DOMAIN
[[ -z "$PANEL_DOMAIN" || -z "$SUB_DOMAIN" ]] && { err "Домены обязательны"; exit 1; }

PDIR="/opt/remnawave"
require_root() { [[ $EUID -ne 0 ]] && { err "Нужен root"; exit 1; }; }
require_root

# === DOCKER ===
step "Установка Docker"
if ! command -v docker &>/dev/null; then
    info "Скачиваем Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker --now
fi
ok "Docker: $(docker --version | awk '{print $3}' | tr -d ',')"

# === SSL (acme.sh) ===
step "SSL сертификаты (acme.sh)"
apt-get install -y -qq nginx socat cron

if [[ ! -d "$HOME/.acme.sh" ]]; then
    curl https://get.acme.sh | sh -s email="admin@$PANEL_DOMAIN"
fi
export PATH="$HOME/.acme.sh:$PATH"

mkdir -p "$PDIR/nginx"

# Получаем сертификаты
info "Получение сертификата для $PANEL_DOMAIN..."
acme.sh --issue --standalone -d "$PANEL_DOMAIN" --key-file "$PDIR/nginx/privkey.pem" --fullchain-file "$PDIR/nginx/fullchain.pem" --alpn --tlsport 8443

if [[ "$SUB_DOMAIN" != "$PANEL_DOMAIN" ]]; then
    info "Получение сертификата для $SUB_DOMAIN..."
    acme.sh --issue --standalone -d "$SUB_DOMAIN" --key-file "$PDIR/nginx/privkey-sub.pem" --fullchain-file "$PDIR/nginx/fullchain-sub.pem" --alpn --tlsport 8443
fi

ok "SSL готов"

# === NGINX ===
step "Nginx конфиг"
cat > "$PDIR/nginx/nginx.conf" << EOF
server {
    listen 443 ssl http2;
    server_name $PANEL_DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
    ssl_certificate /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
}
EOF

if [[ "$SUB_DOMAIN" != "$PANEL_DOMAIN" ]]; then
    cat >> "$PDIR/nginx/nginx.conf" << EOF
server {
    listen 443 ssl http2;
    server_name $SUB_DOMAIN;
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

cat > "$PDIR/nginx/docker-compose.yml" << EOF
services:
  nginx:
    image: nginx:alpine
    container_name: rw-nginx
    volumes:
      - $PDIR/nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - $PDIR/nginx/fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro
      - $PDIR/nginx/privkey.pem:/etc/nginx/ssl/privkey.pem:ro
EOF

if [[ "$SUB_DOMAIN" != "$PANEL_DOMAIN" ]]; then
    cat >> "$PDIR/nginx/docker-compose.yml" << EOF
      - $PDIR/nginx/fullchain-sub.pem:/etc/nginx/ssl-sub/fullchain.pem:ro
      - $PDIR/nginx/privkey-sub.pem:/etc/nginx/ssl-sub/privkey.pem:ro
EOF
fi

cat >> "$PDIR/nginx/docker-compose.yml" << EOF
    ports:
      - "0.0.0.0:443:443"
      - "0.0.0.0:80:80"
    network_mode: host
    restart: always
EOF

docker compose -f "$PDIR/nginx/docker-compose.yml" up -d
ok "Nginx запущен"

# === PANEL ===
step "Установка Remnawave Panel 2.8.0"
mkdir -p "$PDIR" && cd "$PDIR"

curl -fsSL -o docker-compose.yml https://raw.githubusercontent.com/remnawave/backend/main/docker-compose-prod.yml
curl -fsSL -o .env https://raw.githubusercontent.com/remnawave/backend/main/.env.sample

# Генерация секретов
J1=$(openssl rand -hex 64)
J2=$(openssl rand -hex 64)
PP=$(openssl rand -hex 24)

sed -i \
    -e "s|^JWT_AUTH_SECRET=.*|JWT_AUTH_SECRET=$J1|" \
    -e "s|^JWT_API_TOKENS_SECRET=.*|JWT_API_TOKENS_SECRET=$J2|" \
    -e "s|^#\?APP_SECRET=.*|APP_SECRET=$(openssl rand -hex 64)|" \
    -e "s|^METRICS_PASS=.*|METRICS_PASS=$(openssl rand -hex 64)|" \
    -e "s|^WEBHOOK_SECRET_HEADER=.*|WEBHOOK_SECRET_HEADER=$(openssl rand -hex 64)|" \
    -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$PP|" \
    -e "s|postgresql://postgres:[^@]*@|postgresql://postgres:$PP@|" \
    -e "s|^FRONT_END_DOMAIN=.*|FRONT_END_DOMAIN=$PANEL_DOMAIN|" \
    -e "s|^SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=$SUB_DOMAIN|" \
    -e "s|^PANEL_DOMAIN=.*|PANEL_DOMAIN=$PANEL_DOMAIN|" \
    -e "s|^IS_TELEGRAM_NOTIFICATIONS_ENABLED=.*|IS_TELEGRAM_NOTIFICATIONS_ENABLED=false" \
    .env

# Фикс версии 2.8.0
sed -i 's|remnawave/backend:latest|remnawave/backend:2.8.0|g' docker-compose.yml
sed -i 's|remnawave/backend:2$|remnawave/backend:2.8.0|' docker-compose.yml

docker compose up -d

info "Ожидание запуска..."
for i in {1..60}; do
    curl -fs http://127.0.0.1:3001/health &>/dev/null && break
    sleep 1
done
ok "Панель запущена"

# === SUBSCRIPTION PAGE ===
step "Subscription Page"
mkdir -p "$PDIR/subscription" && cd "$PDIR/subscription"

cat > docker-compose.yml << 'EOF'
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
EOF

cat > .env << EOF
APP_PORT=3010
REMNAWAVE_PANEL_URL=http://127.0.0.1:3000
REMNAWAVE_API_TOKEN=ВАШ_API_ТОКЕН
TRUST_PROXY=true
SUB_PUBLIC_DOMAIN=$SUB_DOMAIN
EOF

docker compose up -d
ok "Subscription Page запущен"

# === CREDENTIALS ===
cat > "$PDIR/.credentials" << EOF
Панель:   https://$PANEL_DOMAIN
Подписки: https://$SUB_DOMAIN
Папка:    $PDIR

1. Открой https://$PANEL_DOMAIN в браузере
2. Создай superadmin: docker exec -it remnawave npx remnanode@latest add-superadmin
3. Получи API токен в панели (Settings → API Tokens)
4. Обнови токен: sed -i 's/REMNAWAVE_API_TOKEN=.*/REMNAWAVE_API_TOKEN=ТВОЙ_ТОКЕN/' $PDIR/subscription/.env
5. Перезапусти сабку: cd $PDIR/subscription && docker compose restart
EOF
chmod 600 "$PDIR/.credentials"

echo -e "\n${GRN}=== ГОТОВО ===${R}"
echo -e "Панель:   ${GRN}https://$PANEL_DOMAIN${R}"
echo -e "Подписки: ${GRN}https://$SUB_DOMAIN${R}"
echo -e "\n${YEL}Данные сохранены в: $PDIR/.credentials${R}"
