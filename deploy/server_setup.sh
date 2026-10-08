#!/usr/bin/env bash
# Настройка сервера и запуск приложения. Запускается от root (через sudo) из deploy.sh,
# можно перезапускать: каждый шаг проверяет, не сделан ли он уже.
#
#   server_setup.sh <домен> <email для Let's Encrypt> <папка с релизом>
#
# Ubuntu 22.04+ или Debian 12+.
set -euo pipefail

DOMAIN=$1
EMAIL=$2
RELEASE=$3
APP_DIR=/opt/iikoweb
APP_UID=10001 # пользователь внутри контейнера, см. Dockerfile
LOGIN_USER=${SUDO_USER:-root}

step() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!! %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mxxx %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Нужен root: запустите через sudo"
[ -f "$RELEASE/docker-compose.yml" ] || die "В $RELEASE нет релиза"
. /etc/os-release
case "$ID" in ubuntu | debian) ;; *) die "Поддерживаются Ubuntu и Debian, а здесь $ID" ;; esac

export DEBIAN_FRONTEND=noninteractive

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

step "SSH: вход только по ключу"
LOGIN_HOME=$(getent passwd "$LOGIN_USER" | cut -d: -f6)
# Пароли выключаем, только если ключ точно на месте — иначе можно потерять доступ к серверу
if [ -s "$LOGIN_HOME/.ssh/authorized_keys" ]; then
    cat >/etc/ssh/sshd_config.d/10-iikoweb.conf <<'EOF'
# iikoweb: вход только по SSH-ключу
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
    sshd -t || die "Конфиг sshd не прошёл проверку — ничего не перезапускаю"
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
else
    warn "У $LOGIN_USER нет authorized_keys — вход по паролю НЕ выключаю"
fi

step "Файрвол: снаружи только SSH, 80 и 443"
SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
SSH_PORT=${SSH_PORT:-22}
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp" comment 'SSH'
ufw allow 80/tcp comment 'nginx http'
ufw allow 443/tcp comment 'nginx https'
ufw --force enable

step "Приложение в $APP_DIR"
mkdir -p "$APP_DIR"
rsync -a --delete --exclude data/ --exclude .env "$RELEASE/" "$APP_DIR/"
install -m 600 "$RELEASE/.env" "$APP_DIR/.env"
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
    echo "Снаружи слушают только SSH ($SSH_PORT), nginx (80, 443)"
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

step "Готово"
BAR_KEY=$(grep '^BAR_KEY=' "$APP_DIR/.env" | cut -d= -f2-)
echo "Гостям:   https://$DOMAIN/t/<токен стола> (QR печатаются со страницы бариста)"
echo "Бариста:  https://$DOMAIN/bar?key=$BAR_KEY"
echo "Логи:     docker compose -f $APP_DIR/docker-compose.yml logs -f"
