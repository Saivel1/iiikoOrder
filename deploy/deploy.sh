#!/usr/bin/env bash
# Деплой на сервере. Запускать из папки с проектом, от root:
#
#   sudo ./deploy/deploy.sh <домен> <email> [--ssh-key "ssh-ed25519 AAAA… you@laptop" | --ssh-key ~/key.pub]
#
# Первый запуск настраивает сервер с нуля, следующие — обновляют приложение (подтянули код → запустили снова).
#   - SSH: добавляет ключ в authorized_keys и выключает вход по паролю (только если ключ на месте)
#   - ufw: снаружи открыты только SSH, 80 и 443
#   - Docker: приложение публикуется только на 127.0.0.1:8000
#   - nginx + certbot: HTTPS для домена
#   - .env в /opt/iikoweb: при первом запуске спросит ключи iiko, ключ бариста и мастер-пароль сгенерирует сам
#
# Перед запуском A-запись домена должна указывать на этот сервер. Ubuntu 22.04+ или Debian 12+.
set -euo pipefail

usage() { sed -n '2,13p' "$0"; exit 1; }
[ $# -ge 2 ] || usage
DOMAIN=$1
EMAIL=$2
shift 2
SSH_KEY=""
KEEP_PASSWORD_LOGIN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --ssh-key) SSH_KEY=${2:-}; shift 2 ;;
        --keep-password-login) KEEP_PASSWORD_LOGIN=1; shift ;;
        *) usage ;;
    esac
done

SRC=$(cd "$(dirname "$0")/.." && pwd)
APP_DIR=/opt/iikoweb
ENV_FILE=$APP_DIR/.env
APP_UID=10001 # пользователь внутри контейнера, см. Dockerfile
LOGIN_USER=${SUDO_USER:-root}

step() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
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

# ---------- .env ----------

env_get() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
env_set() {
    local tmp
    tmp=$(mktemp)
    grep -vE "^$1=" "$ENV_FILE" >"$tmp" 2>/dev/null || true
    echo "$1=$2" >>"$tmp"
    install -m 600 "$tmp" "$ENV_FILE"
    rm -f "$tmp"
}
random() { head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-"$1"; }
ask() {
    local name=$1 prompt=$2 secret=${3:-} value
    [ -t 0 ] || die "Не задан $name, а спросить не у кого (нет терминала). Впишите его в $ENV_FILE"
    while [ -z "${value:-}" ]; do
        if [ -n "$secret" ]; then read -rsp "$prompt: " value; echo; else read -rp "$prompt: " value; fi
    done
    env_set "$name" "$value"
}

step "Настройки: $ENV_FILE"
mkdir -p "$APP_DIR"
if [ ! -f "$ENV_FILE" ]; then
    touch "$ENV_FILE" && chmod 600 "$ENV_FILE"
    # Ключи iiko можно взять из .env рядом с кодом, если вы его скопировали
    if [ -f "$SRC/.env" ] && [ "$SRC/.env" != "$ENV_FILE" ]; then
        grep -E '^(TOKEN|IIKO_APP_ID|IIKO_CLIENT_SECRET)=' "$SRC/.env" >>"$ENV_FILE" || true
    fi
    # Ключ бариста и мастер-пароль — всегда новые, а не те, что светились при разработке
    env_set BAR_KEY "$(random 32)"
    env_set MASTER_PASSWORD "$(random 16)"
    echo "Создан $ENV_FILE"
fi
[ -n "$(env_get TOKEN)" ] || ask TOKEN "API-ключ iiko (apiKey)" secret
[ -n "$(env_get IIKO_APP_ID)" ] || ask IIKO_APP_ID "appId приложения iiko"
[ -n "$(env_get IIKO_CLIENT_SECRET)" ] || ask IIKO_CLIENT_SECRET "clientSecret приложения iiko" secret
[ -n "$(env_get BAR_KEY)" ] || env_set BAR_KEY "$(random 32)"
[ -n "$(env_get MASTER_PASSWORD)" ] || env_set MASTER_PASSWORD "$(random 16)"
env_set BASE_URL "https://$DOMAIN"
env_set IIKO_SEND_ORDERS true

# ---------- пакеты ----------

step "Пакеты: nginx, certbot, ufw"
apt-get update -q
apt-get install -y -q ca-certificates curl gnupg rsync nginx certbot python3-certbot-nginx ufw

step "Docker"
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
        >/etc/apt/sources.list.d/docker.list
    apt-get update -q
    apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

# ---------- SSH ----------

step "SSH: ключ и вход только по ключу"
LOGIN_HOME=$(getent passwd "$LOGIN_USER" | cut -d: -f6)
# На Ubuntu с ssh.socket этой папки нет, пока никто не подключился, и `sshd -t/-T` без неё падает
mkdir -p /run/sshd && chmod 755 /run/sshd
AUTH_KEYS=$LOGIN_HOME/.ssh/authorized_keys
if [ -n "$SSH_KEY" ]; then
    [ -f "$SSH_KEY" ] && SSH_KEY=$(cat "$SSH_KEY")
    [[ "$SSH_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh.com)\ [A-Za-z0-9+/=]+ ]] \
        || die "--ssh-key: это не похоже на публичный ключ (ожидается строка из файла .pub)"
    install -d -m 700 -o "$LOGIN_USER" -g "$(id -gn "$LOGIN_USER")" "$LOGIN_HOME/.ssh"
    touch "$AUTH_KEYS"
    if grep -qF "$(echo "$SSH_KEY" | awk '{print $2}')" "$AUTH_KEYS"; then
        echo "Ключ уже добавлен для $LOGIN_USER"
    else
        echo "$SSH_KEY" >>"$AUTH_KEYS"
        echo "Ключ добавлен для $LOGIN_USER"
    fi
    chown "$LOGIN_USER:$(id -gn "$LOGIN_USER")" "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
fi
if [ "$KEEP_PASSWORD_LOGIN" -eq 1 ]; then
    warn "--keep-password-login: вход по паролю не трогаю"
elif [ -s "$AUTH_KEYS" ]; then
    cat >/etc/ssh/sshd_config.d/10-iikoweb.conf <<'EOF'
# iikoweb: вход только по SSH-ключу
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
    sshd -t || die "Конфиг sshd не прошёл проверку — ничего не перезапускаю"
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
    warn "Вход по паролю выключен. НЕ закрывайте эту сессию, пока не проверите вход по ключу в новом окне: ssh $LOGIN_USER@<сервер>"
else
    # Иначе можно потерять доступ к серверу
    warn "У $LOGIN_USER нет SSH-ключей — вход по паролю НЕ выключаю. Передайте ключ: --ssh-key \"\$(cat ~/.ssh/id_ed25519.pub)\""
fi

# ---------- файрвол ----------

step "Файрвол: снаружи только SSH, 80 и 443"
SSH_PORT=$( (sshd -T 2>/dev/null || true) | awk '/^port /{print $2; exit}')
SSH_PORT=${SSH_PORT:-22}
echo "Порт SSH: $SSH_PORT"
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp" comment 'SSH'
ufw allow 80/tcp comment 'nginx http'
ufw allow 443/tcp comment 'nginx https'
ufw --force enable

# ---------- приложение ----------

step "Приложение в $APP_DIR"
if [ "$SRC" != "$APP_DIR" ]; then
    # Только код: база, фото и .env живут в $APP_DIR и при обновлении не трогаются
    rsync -a --delete \
        --exclude data/ --exclude .env --exclude '.env.*' --exclude .git/ --exclude .venv/ \
        --exclude '__pycache__/' --exclude 'app.db*' --exclude dumps/ --exclude qr/ --exclude static/ \
        "$SRC/" "$APP_DIR/"
fi
mkdir -p "$APP_DIR/data/menu"
chown -R "$APP_UID:$APP_UID" "$APP_DIR/data"
cd "$APP_DIR"
docker compose up -d --build --remove-orphans

printf 'Жду, пока приложение поднимется'
for _ in $(seq 1 60); do
    if curl -fsS -o /dev/null http://127.0.0.1:8000/api/menu; then echo " — ок"; break; fi
    printf '.'
    sleep 2
done
curl -fsS -o /dev/null http://127.0.0.1:8000/api/menu || die "Приложение не отвечает: docker compose -f $APP_DIR/docker-compose.yml logs"

# ---------- nginx и HTTPS ----------

step "nginx"
cat >/etc/nginx/iikoweb_proxy.conf <<'EOF'
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
fi
ln -sf "$SITE" /etc/nginx/sites-enabled/iikoweb
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx
systemctl reload nginx || systemctl restart nginx

step "HTTPS-сертификат"
if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    echo "Сертификат уже есть, продлевается автоматически (certbot.timer)"
else
    certbot --nginx -d "$DOMAIN" -m "$EMAIL" --agree-tos --non-interactive --redirect \
        || die "certbot не смог получить сертификат: проверьте, что A-запись $DOMAIN указывает на этот сервер"
fi
nginx -t && systemctl reload nginx

# ---------- проверка ----------

step "Проверка: что слушает снаружи"
# Всё, что слушает не на localhost, кроме SSH и nginx, — повод разобраться
EXPOSED=$(ss -H -tlnp | awk -v ssh=":$SSH_PORT\$" '
    { addr = $4 }
    addr ~ /^(127\.|\[::1\]|\[::ffff:127\.)/ { next }
    addr ~ ssh || addr ~ /:(80|443)$/ { next }
    { print "  " addr "  " $6 }')
if [ -n "$EXPOSED" ]; then
    warn "Наружу слушает что-то лишнее (файрвол это закрывает, но лучше проверить):"
    echo "$EXPOSED"
else
    echo "Снаружи слушают только SSH ($SSH_PORT) и nginx (80, 443)"
fi
# Опубликованные порты выглядят как «127.0.0.1:8000->8000/tcp»; всё, что без 127.0.0.1, торчит наружу
PUBLISHED=$(docker ps --format '{{.Names}} {{.Ports}}' | tr ',' '\n' | grep -- '->' | grep -v '127\.0\.0\.1:' || true)
if [ -n "$PUBLISHED" ]; then
    warn "Контейнер публикует порт не на 127.0.0.1 — Docker обходит ufw, порт открыт в интернет:"
    echo "$PUBLISHED"
else
    echo "Docker публикует порты только на 127.0.0.1"
fi
ufw status verbose | sed -n '1,20p'
curl -fsS -o /dev/null -w "https://$DOMAIN/api/menu -> %{http_code}\n" "https://$DOMAIN/api/menu" \
    || warn "https://$DOMAIN пока не открывается — проверьте DNS"

step "Готово"
echo "Бариста (стоп-лист, касса, QR): https://$DOMAIN/bar?key=$(env_get BAR_KEY)"
echo "Мастер-пароль для печати QR:     $(env_get MASTER_PASSWORD)"
echo "Логи:                            docker compose -f $APP_DIR/docker-compose.yml logs -f"
echo "Обновление: подтяните код и снова запустите sudo ./deploy/deploy.sh $DOMAIN $EMAIL"
