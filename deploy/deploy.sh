#!/usr/bin/env bash
# Деплой с ноутбука на сервер. Первый запуск настраивает сервер с нуля, следующие — обновляют приложение.
#
#   ./deploy/deploy.sh root@203.0.113.10 order.example.ru admin@example.ru
#
# Что делает:
#   1. Подключает SSH-ключ (ssh-copy-id спросит пароль сервера один раз), дальше вход только по ключу.
#   2. Готовит .env.production: боевой BASE_URL, новый ключ бариста и мастер-пароль для QR.
#   3. Отправляет код на сервер и запускает deploy/server_setup.sh: Docker, nginx, certbot, ufw.
#
# Перед запуском: A-запись домена должна указывать на IP сервера (иначе certbot не выдаст сертификат).
set -euo pipefail

[ $# -eq 3 ] || { sed -n '2,12p' "$0"; exit 1; }
SERVER=$1
DOMAIN=$2
EMAIL=$3
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}
ENV_PROD=.env.production
RELEASE=iikoweb-release # папка в домашнем каталоге пользователя на сервере

cd "$(dirname "$0")/.."
step() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mxxx %s\033[0m\n' "$*" >&2; exit 1; }
[ -f .env ] || die "Нет .env с ключами iiko"

step "SSH-ключ"
if [ ! -f "$SSH_KEY" ]; then
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "iikoweb-deploy"
fi
SSH=(ssh -i "$SSH_KEY" -o IdentitiesOnly=yes)
if ! "${SSH[@]}" -o BatchMode=yes -o ConnectTimeout=10 "$SERVER" true 2>/dev/null; then
    echo "Ключа на сервере ещё нет — добавляю (спросит пароль сервера)"
    ssh-copy-id -i "$SSH_KEY.pub" "$SERVER"
fi
"${SSH[@]}" -o BatchMode=yes "$SERVER" true || die "Вход по ключу не работает — дальше не иду, чтобы не закрыть себе доступ"
echo "Вход по ключу работает"

step "Настройки для продакшена: $ENV_PROD"
rand() { openssl rand -base64 32 | tr -d '/+=' | cut -c1-"$1"; }
if [ ! -f "$ENV_PROD" ]; then
    # Ключи iiko — из локального .env. Ключ бариста и мастер-пароль — новые: локальные уже светились при разработке
    grep -vE '^(BASE_URL|IIKO_SEND_ORDERS|DB_PATH|MASTER_PASSWORD|BAR_KEY)=' .env | grep -v '^$' >"$ENV_PROD"
    {
        echo "BAR_KEY=$(rand 32)"
        echo "MASTER_PASSWORD=$(rand 16)"
        echo "IIKO_SEND_ORDERS=true"
        echo "BASE_URL=https://$DOMAIN"
    } >>"$ENV_PROD"
    chmod 600 "$ENV_PROD"
    echo "Создан $ENV_PROD — храните его, в нём мастер-пароль и ключ бариста"
fi
# Домен мог смениться — BASE_URL всегда по текущему
grep -v '^BASE_URL=' "$ENV_PROD" >"$ENV_PROD.tmp" && echo "BASE_URL=https://$DOMAIN" >>"$ENV_PROD.tmp" && mv "$ENV_PROD.tmp" "$ENV_PROD"
chmod 600 "$ENV_PROD"
for key in TOKEN IIKO_APP_ID IIKO_CLIENT_SECRET BAR_KEY MASTER_PASSWORD; do
    grep -q "^$key=." "$ENV_PROD" || die "В $ENV_PROD не заполнен $key"
done

step "Отправляю код на сервер"
# Только код и конфиги: без базы, локальных дампов, QR и .venv
COPYFILE_DISABLE=1 tar czf - pyproject.toml uv.lock ./*.py templates Dockerfile docker-compose.yml .dockerignore deploy \
    | "${SSH[@]}" "$SERVER" "rm -rf ~/$RELEASE && mkdir -p ~/$RELEASE && tar xzf - -C ~/$RELEASE 2>/dev/null"
"${SSH[@]}" "$SERVER" "umask 077 && cat > ~/$RELEASE/.env" <"$ENV_PROD"

step "Настраиваю сервер и запускаю приложение"
# -t: если зашли не под root, sudo сможет спросить пароль
"${SSH[@]}" -t "$SERVER" "
    set -e
    cd ~/$RELEASE
    if [ \"\$(id -u)\" -eq 0 ]; then bash deploy/server_setup.sh '$DOMAIN' '$EMAIL' \"\$PWD\"
    else sudo bash deploy/server_setup.sh '$DOMAIN' '$EMAIL' \"\$PWD\"; fi
    rm -f ~/$RELEASE/.env
"

step "Готово"
echo "Мастер-пароль для печати QR: $(grep '^MASTER_PASSWORD=' "$ENV_PROD" | cut -d= -f2-)"
echo "Проверка снаружи:"
curl -sS -o /dev/null -w "  https://$DOMAIN/api/menu -> %{http_code}\n" "https://$DOMAIN/api/menu" || true
curl -sS -o /dev/null -m 5 -w "  http://$DOMAIN:8000 (должен быть недоступен) -> %{http_code}\n" "http://$DOMAIN:8000/" 2>/dev/null \
    || echo "  порт 8000 снаружи закрыт — так и надо"
