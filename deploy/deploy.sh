#!/usr/bin/env bash
# Деплой на сервере. Запускать из папки с проектом, от root:
#
#   sudo ./deploy/deploy.sh <домен> <email>
#
# Можно запускать сколько угодно раз: каждый этап сначала проверяет, не сделан ли он уже, и пропускает себя.
# Обновление приложения: git pull → снова запустить скрипт (пересоберётся, только если изменился код).
#   - .env в /opt/iikoweb: при первом запуске спросит ключи iiko, ключ бариста и мастер-пароль сгенерирует сам
#   - пакеты, Docker, ufw (снаружи только SSH, 80, 443), приложение в Docker на 127.0.0.1:8000, nginx + certbot
#
# Перед запуском A-запись домена должна указывать на этот сервер. Ubuntu 22.04+ или Debian 12+.
set -euo pipefail

[ $# -eq 2 ] || { sed -n '2,11p' "$0"; exit 1; }
DOMAIN=$1
EMAIL=$2

SRC=$(cd "$(dirname "$0")/.." && pwd)
APP_DIR=/opt/iikoweb
ENV_FILE=$APP_DIR/.env
APP_UID=10001 # пользователь внутри контейнера, см. Dockerfile
PACKAGES=(ca-certificates curl gnupg rsync nginx certbot python3-certbot-nginx ufw)

step() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
skip() { printf '\033[2m    уже сделано: %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!! %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mxxx %s\033[0m\n' "$*" >&2; exit 1; }
# Никаких молчаливых выходов: при любой ошибке показываем строку и команду
set -E
trap 'printf "\033[1;31mxxx Ошибка в строке %s: %s\033[0m\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

[ "$(id -u)" -eq 0 ] || die "Нужен root: sudo $0 $DOMAIN $EMAIL"
[ -f "$SRC/docker-compose.yml" ] || die "Запускайте скрипт из папки проекта ($SRC — не она)"
. /etc/os-release
case "$ID" in ubuntu | debian) ;; *) die "Поддерживаются Ubuntu и Debian, а здесь $ID" ;; esac
export DEBIAN_FRONTEND=noninteractive

# Записывает файл, только если содержимое изменилось. Код возврата 0 — файл изменён
write_if_changed() {
    local file=$1 tmp
    tmp=$(mktemp)
    cat >"$tmp"
    if [ -f "$file" ] && cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$file"
    chmod 644 "$file"
}

# ---------- .env ----------

env_get() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
env_set() {
    [ "$(env_get "$1")" = "$2" ] && return 0
    local tmp
    tmp=$(mktemp)
    grep -vE "^$1=" "$ENV_FILE" >"$tmp" 2>/dev/null || true
    echo "$1=$2" >>"$tmp"
    install -m 600 "$tmp" "$ENV_FILE"
    rm -f "$tmp"
    echo "    $1 записан"
}
random() { head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-"$1"; }
ask() {
    local name=$1 prompt=$2 secret=${3:-} value=""
    [ -t 0 ] || die "Не задан $name, а спросить не у кого (нет терминала). Впишите его в $ENV_FILE"
    while [ -z "$value" ]; do
        if [ -n "$secret" ]; then read -rsp "$prompt: " value; echo; else read -rp "$prompt: " value; fi
    done
    env_set "$name" "$value"
}

step "Настройки: $ENV_FILE"
mkdir -p "$APP_DIR"
if [ -f "$ENV_FILE" ]; then
    skip "файл есть, дописываю только недостающее"
else
    install -m 600 /dev/null "$ENV_FILE"
    # Ключи iiko можно взять из .env рядом с кодом, если вы его скопировали
    if [ -f "$SRC/.env" ] && [ "$SRC/.env" != "$ENV_FILE" ]; then
        grep -E '^(TOKEN|IIKO_APP_ID|IIKO_CLIENT_SECRET)=' "$SRC/.env" >>"$ENV_FILE" || true
    fi
    echo "    создан"
fi
[ -n "$(env_get TOKEN)" ] || ask TOKEN "API-ключ iiko (apiKey)" secret
[ -n "$(env_get IIKO_APP_ID)" ] || ask IIKO_APP_ID "appId приложения iiko"
[ -n "$(env_get IIKO_CLIENT_SECRET)" ] || ask IIKO_CLIENT_SECRET "clientSecret приложения iiko" secret
# Ключ бариста и мастер-пароль — новые, а не те, что светились при разработке
[ -n "$(env_get BAR_KEY)" ] || env_set BAR_KEY "$(random 32)"
[ -n "$(env_get MASTER_PASSWORD)" ] || env_set MASTER_PASSWORD "$(random 16)"
env_set BASE_URL "https://$DOMAIN"
env_set IIKO_SEND_ORDERS true

# ---------- пакеты ----------

step "Пакеты: ${PACKAGES[*]}"
MISSING=()
for pkg in "${PACKAGES[@]}"; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" || MISSING+=("$pkg")
done
if [ ${#MISSING[@]} -eq 0 ]; then
    skip "всё установлено"
else
    echo "    ставлю: ${MISSING[*]}"
    apt-get update -q
    apt-get install -y -q "${MISSING[@]}"
fi

step "Docker"
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    skip "$(docker --version)"
else
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
        >/etc/apt/sources.list.d/docker.list
    apt-get update -q
    apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl is-active --quiet docker || systemctl enable --now docker

# ---------- файрвол ----------

step "Файрвол: снаружи только SSH, 80 и 443"
# Порты SSH: из конфига sshd и те, на которых sshd слушает прямо сейчас. Закрыть SSH = потерять сервер
SSH_PORTS=$(
    {
        cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk 'tolower($1) == "port" { print $2 }'
        ss -H -tlnp 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); print a[n] }'
    } | sort -un | tr '\n' ' '
)
SSH_PORTS=${SSH_PORTS:-22}
echo "    порты SSH: $SSH_PORTS"
UFW_STATUS=$(ufw status 2>/dev/null || true)
has_rule() { echo "$UFW_STATUS" | grep -qE "^$1/tcp +ALLOW"; }
UFW_OK=1
echo "$UFW_STATUS" | grep -q "^Status: active" || UFW_OK=0
for port in $SSH_PORTS 80 443; do has_rule "$port" || UFW_OK=0; done
if [ "$UFW_OK" -eq 1 ]; then
    skip "ufw включён, порты $SSH_PORTS 80 443 открыты"
else
    ufw default deny incoming
    ufw default allow outgoing
    for port in $SSH_PORTS; do ufw allow "$port/tcp" comment 'SSH'; done
    ufw allow 80/tcp comment 'nginx http'
    ufw allow 443/tcp comment 'nginx https'
    ufw --force enable
fi

# ---------- приложение ----------

step "Приложение в $APP_DIR"
RSYNC=(rsync -a --delete
    --exclude data/ --exclude .env --exclude '.env.*' --exclude .git/ --exclude .venv/
    --exclude '__pycache__/' --exclude 'app.db*' --exclude dumps/ --exclude qr/ --exclude static/)
CODE_CHANGED=0
if [ "$SRC" != "$APP_DIR" ]; then
    # Только код: база, фото и .env живут в $APP_DIR и при обновлении не трогаются
    if [ -n "$("${RSYNC[@]}" --dry-run -i "$SRC/" "$APP_DIR/")" ]; then
        "${RSYNC[@]}" "$SRC/" "$APP_DIR/"
        CODE_CHANGED=1
        echo "    код обновлён"
    fi
fi
mkdir -p "$APP_DIR/data/menu"
chown -R "$APP_UID:$APP_UID" "$APP_DIR/data"
cd "$APP_DIR"
RUNNING=$(docker compose ps --status running -q 2>/dev/null || true)
if [ "$CODE_CHANGED" -eq 1 ] || [ -z "$RUNNING" ] || [ -z "$(docker compose images -q 2>/dev/null || true)" ]; then
    docker compose up -d --build --remove-orphans
else
    # Код тот же — без пересборки; compose сам перезапустит контейнер, если поменялся .env
    skip "код не менялся, контейнер запущен"
    docker compose up -d --remove-orphans
fi

printf '    жду ответа приложения'
for _ in $(seq 1 60); do
    if curl -fsS -o /dev/null http://127.0.0.1:8000/api/menu; then echo " — ок"; break; fi
    printf '.'
    sleep 2
done
curl -fsS -o /dev/null http://127.0.0.1:8000/api/menu || die "Приложение не отвечает: docker compose -f $APP_DIR/docker-compose.yml logs"

# ---------- nginx и HTTPS ----------

step "nginx"
NGINX_CHANGED=0
write_if_changed /etc/nginx/iikoweb_proxy.conf <<'EOF' && NGINX_CHANGED=1
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_http_version 1.1;
proxy_read_timeout 60s;
EOF
SITE=/etc/nginx/sites-available/iikoweb
# certbot дописывает в конфиг HTTPS — не затираем его при повторном деплое
if [ ! -f "$SITE" ] || ! grep -q "server_name $DOMAIN;" "$SITE"; then
    sed "s/__DOMAIN__/$DOMAIN/g" "$APP_DIR/deploy/nginx.conf" >"$SITE"
    NGINX_CHANGED=1
fi
if [ "$(readlink /etc/nginx/sites-enabled/iikoweb 2>/dev/null)" != "$SITE" ]; then
    ln -sf "$SITE" /etc/nginx/sites-enabled/iikoweb
    NGINX_CHANGED=1
fi
if [ -e /etc/nginx/sites-enabled/default ]; then
    rm -f /etc/nginx/sites-enabled/default
    NGINX_CHANGED=1
fi
systemctl is-enabled --quiet nginx || systemctl enable nginx
if [ "$NGINX_CHANGED" -eq 1 ]; then
    nginx -t
    systemctl reload nginx || systemctl restart nginx
    echo "    конфиг обновлён"
else
    skip "конфиг для $DOMAIN на месте"
fi
systemctl is-active --quiet nginx || systemctl start nginx

step "HTTPS-сертификат"
if [ -d "/etc/letsencrypt/live/$DOMAIN" ] && grep -q "ssl_certificate" "$SITE"; then
    skip "сертификат есть и подключён, продлевается сам (certbot.timer)"
else
    certbot --nginx -d "$DOMAIN" -m "$EMAIL" --agree-tos --non-interactive --redirect --keep-until-expiring \
        || die "certbot не смог получить сертификат: проверьте, что A-запись $DOMAIN указывает на этот сервер"
    nginx -t && systemctl reload nginx
fi

# ---------- проверка (всегда) ----------

step "Проверка: что слушает снаружи"
# Всё, что слушает не на localhost, кроме SSH и nginx, — повод разобраться
ALLOWED_RE=":($(echo "$SSH_PORTS" | xargs | tr ' ' '|')|80|443)\$"
EXPOSED=$(ss -H -tlnp | awk -v allowed="$ALLOWED_RE" '
    { addr = $4 }
    addr ~ /^(127\.|\[::1\]|\[::ffff:127\.)/ { next }
    addr ~ allowed { next }
    { print "    " addr "  " $6 }')
if [ -n "$EXPOSED" ]; then
    warn "Наружу слушает что-то лишнее (файрвол это закрывает, но лучше проверить):"
    echo "$EXPOSED"
else
    echo "    снаружи слушают только SSH ($SSH_PORTS) и nginx (80, 443)"
fi
# Опубликованные порты выглядят как «127.0.0.1:8000->8000/tcp»; всё, что без 127.0.0.1, торчит наружу
PUBLISHED=$(docker ps --format '{{.Names}} {{.Ports}}' | tr ',' '\n' | grep -- '->' | grep -v '127\.0\.0\.1:' || true)
if [ -n "$PUBLISHED" ]; then
    warn "Контейнер публикует порт не на 127.0.0.1 — Docker обходит ufw, порт открыт в интернет:"
    echo "$PUBLISHED"
else
    echo "    Docker публикует порты только на 127.0.0.1"
fi
curl -fsS -o /dev/null -w "    https://$DOMAIN/api/menu -> %{http_code}\n" "https://$DOMAIN/api/menu" \
    || warn "https://$DOMAIN пока не открывается — проверьте DNS"

step "Готово"
echo "Бариста (стоп-лист, касса, QR): https://$DOMAIN/bar?key=$(env_get BAR_KEY)"
echo "Мастер-пароль для печати QR:     $(env_get MASTER_PASSWORD)"
echo "Логи:                            docker compose -f $APP_DIR/docker-compose.yml logs -f"
echo "Обновление: git pull и снова sudo ./deploy/deploy.sh $DOMAIN $EMAIL"
