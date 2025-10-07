#!/usr/bin/env bash
set -euo pipefail
exec > >(tee -a /root/install.log) 2>&1

bblue(){ echo -e "\e[1;34m$*\e[0m"; }
bgreen(){ echo -e "\e[1;32m$*\e[0m"; }
byellow(){ echo -e "\e[1;33m$*\e[0m"; }
bred(){ echo -e "\e[1;31m$*\e[0m"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    bred "Запустите от root: sudo bash install.sh"
    exit 1
  fi
}

detect_os() {
  if [[ -f /etc/debian_version ]]; then
    OS_FAMILY="debian"
  else
    bred "Поддерживаются только Debian/Ubuntu."
    exit 1
  fi
}

RW_LANG="${RW_LANG:-ru}"
RW_PANEL_BRANCH="${RW_PANEL_BRANCH:-}"
RW_INSTALLER_BRANCH="${RW_INSTALLER_BRANCH:-}"
RW_KEEP_CADDY_DATA="${RW_KEEP_CADDY_DATA:-}"

require_root
detect_os

bblue "1) Обновление пакетов и установка зависимостей..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates gnupg lsb-release jq qrencode nodejs npm cron
if ! command -v script >/dev/null 2>&1; then
  apt-get install -y util-linux || true
fi

bblue "2) Установка и автозапуск VK Tunnel (@vkontakte/vk-tunnel)..."
if ! command -v vk-tunnel >/dev/null 2>&1; then
  npm install -g @vkontakte/vk-tunnel
fi

SERVICE_USER="${SUDO_USER:-root}"
HOME_DIR="$(eval echo ~${SERVICE_USER})"

cat >/etc/systemd/system/vk-tunnel.service <<'EOF'
[Unit]
Description=VK Tunnel Service
After=network.target

[Service]
ExecStart=/usr/local/bin/vk-tunnel --server user607226349-oztvzefy.tunnel.vk-apps.com
Restart=always
User=root
WorkingDirectory=/root

[Install]
WantedBy=multi-user.target
EOF
sed -i "s|__SERVICE_USER__|${SERVICE_USER}|g" /etc/systemd/system/vk-tunnel.service
sed -i "s|__HOME_DIR__|${HOME_DIR}|g" /etc/systemd/system/vk-tunnel.service

cat >/usr/local/bin/vk-tunnel-healthcheck.sh <<'EOF'
#!/usr/bin/env bash
set -e
if ! systemctl is-active --quiet vk-tunnel.service; then
  systemctl restart vk-tunnel.service
fi
EOF
chmod +x /usr/local/bin/vk-tunnel-healthcheck.sh
if ! crontab -l 2>/dev/null | grep -q "vk-tunnel-healthcheck.sh"; then
  (crontab -l 2>/dev/null; echo "0 * * * * /usr/local/bin/vk-tunnel-healthcheck.sh") | crontab -
fi

VK_TUNNEL_BIN="/usr/local/bin/vk-tunnel"

byellow "СЕЙЧАС ВЫЙДЕТ ССЫЛКА ДЛЯ АВТОРИЗАЦИИ VK."
byellow "Откройте её в браузере, войдите в аккаунт и подтвердите вход (нажмите Enter)."
byellow "После завершения vk-tunnel сам закроется/или вы закроете его, и установка продолжится."

if "$VK_TUNNEL_BIN" --help 2>&1 | grep -q -- "--once"; then
  sudo -u "${SERVICE_USER}" HOME="${HOME_DIR}" "$VK_TUNNEL_BIN"
else
  byellow "⚠️ Ваша версия vk-tunnel не поддерживает --once."
  byellow "После подтверждения просто нажмите Ctrl+C в окне vk-tunnel."
  trap '' INT
  sudo -u "${SERVICE_USER}" HOME="${HOME_DIR}" "$VK_TUNNEL_BIN" || true
  trap - INT
fi

systemctl daemon-reload
systemctl enable --now vk-tunnel.service
bgreen "VK Tunnel готов (порт 10888). Крон следит и перезапускает при падении."

bblue "3) Установка Remnawave (интерактив)."
byellow "После появления 'Installation complete. Press Enter to continue...' можете нажать Enter или Ctrl+C — скрипт скрипт продолжит работу."
set +e
script -q -f -c 'bash <(curl -s https://raw.githubusercontent.com/xxphantom/remnawave-installer/main/install.sh)' /root/remnawave-installer.ttylog
RET=$?
set -e
bgreen "Remnawave-инсталлятор завершён (код ${RET}). Продолжаем..."

bblue "4) Сбор параметров Remnawave после установки..."
INSTALL_DIR="/opt/remnawave"
ENV_FILE="${INSTALL_DIR}/.env"
CRED_FILE="${INSTALL_DIR}/credentials.txt"

FRONTEND_DOMAIN=""; SUB_PUBLIC=""; DB_URL=""
if [[ -f "${ENV_FILE}" ]]; then
  FRONTEND_DOMAIN="$(grep -E '^FRONT_END_DOMAIN=' "${ENV_FILE}" | sed -E 's/^FRONT_END_DOMAIN=//; s/^"//; s/"$//')"
  SUB_PUBLIC="$(grep -E '^SUB_PUBLIC_DOMAIN=' "${ENV_FILE}" | sed -E 's/^SUB_PUBLIC_DOMAIN=//; s/^"//; s/"$//')"
  DB_URL="$(grep -E '^DATABASE_URL=' "${ENV_FILE}" | sed -E 's/^DATABASE_URL=//; s/^"//; s/"$//')"
fi

bblue "5) Замена Caddyfile для Remnawave..."

CADDY_FILE="/opt/remnawave/caddy/Caddyfile"
cat >"$CADDY_FILE" <<'EOF'
{
    admin off
    default_bind 0.0.0.0
    servers {
        listener_wrappers {
            proxy_protocol {
                allow 127.0.0.1/32
            }
            tls
        }
    }
    auto_https disable_redirects
    order authenticate before respond
    order authorize before respond

    security {
        local identity store localdb {
            realm local
            path /data/.local/caddy/users.json
        }

        authentication portal remnawaveportal {
            crypto default token lifetime {$AUTH_TOKEN_LIFETIME}
            enable identity store localdb
            cookie domain {$REMNAWAVE_PANEL_DOMAIN}
            ui {
                links {
                    "Remnawave" "/dashboard/home" icon "las la-tachometer-alt"
                    "My Identity" "/{$REMNAWAVE_CUSTOM_LOGIN_ROUTE}/whoami" icon "las la-user"
                    "API Keys" "/{$REMNAWAVE_CUSTOM_LOGIN_ROUTE}/settings/apikeys" icon "las la-key"
                    "MFA" "/{$REMNAWAVE_CUSTOM_LOGIN_ROUTE}/settings/mfa" icon "lab la-keycdn"
                }
            }
            transform user {
                match origin local
                require mfa
                action add role authp/admin
            }
        }

        authorization policy panelpolicy {
            set auth url /restricted
            disable auth redirect
            allow roles authp/admin
            with api key auth portal remnawaveportal realm local

            acl rule {
                comment "Accept"
                match role authp/admin
                allow stop log info
            }
            acl rule {
                comment "Deny"
                match any
                deny log warn
            }
        }
    }
}

http://{$REMNAWAVE_PANEL_DOMAIN} {
    bind 0.0.0.0
    redir https://{$REMNAWAVE_PANEL_DOMAIN}{uri} permanent
}

https://{$REMNAWAVE_PANEL_DOMAIN} {
    @login_path {
        path /{$REMNAWAVE_CUSTOM_LOGIN_ROUTE} /{$REMNAWAVE_CUSTOM_LOGIN_ROUTE}/ /{$REMNAWAVE_CUSTOM_LOGIN_ROUTE}/auth
    }
    handle @login_path {
        rewrite * /auth
        request_header +X-Forwarded-Prefix /{$REMNAWAVE_CUSTOM_LOGIN_ROUTE}
        authenticate with remnawaveportal
    }

    handle_path /restricted* {
        abort
    }

    route /api/* {
        authorize with panelpolicy
        reverse_proxy http://127.0.0.1:3000
    }

    route /{$REMNAWAVE_CUSTOM_LOGIN_ROUTE}* {
        authenticate with remnawaveportal
    }

    route /* {
        authorize with panelpolicy
        reverse_proxy http://127.0.0.1:3000
    }

    handle_errors {
        @unauth {
            expression {http.error.status_code} == 401
        }
        handle @unauth {
            respond * 204
        }
    }
}

http://{$CADDY_SELF_STEAL_DOMAIN} {
    bind 0.0.0.0
    redir https://{$CADDY_SELF_STEAL_DOMAIN}{uri} permanent
}

https://{$CADDY_SELF_STEAL_DOMAIN} {
    root * /var/www/html
    try_files {path} /index.html
    file_server
}

http://{$CADDY_SUB_DOMAIN} {
    bind 0.0.0.0
    redir https://{$CADDY_SUB_DOMAIN}{uri} permanent
}

https://{$CADDY_SUB_DOMAIN} {
    handle {
        reverse_proxy http://127.0.0.1:3010 {
            header_up X-Real-IP {remote}
            header_up Host {host}
        }
    }
    handle_errors {
        handle {
            respond * 204
        }
    }
}

:80 {
    bind 0.0.0.0
    respond 204
}
EOF

bgreen "Caddyfile обновлён. Перезапускаем контейнеры..."
docker restart remnawave-caddy
bblue "5) Установка апдейтера VK Host..."
UPDATER="/usr/local/bin/vk-host-updater.sh"
cat >"$UPDATER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOGFILE="/var/log/vk_host_update.log"
ENV_FILE="/opt/remnawave/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "$(date) ❌ .env Remnawave не найден" >> "$LOGFILE"
  exit 1
fi

DB_URL=$(grep -E '^DATABASE_URL=' "$ENV_FILE" | sed -E 's/^DATABASE_URL=//; s/^"//; s/"$//')
if [[ -z "$DB_URL" ]]; then
  echo "$(date) ❌ DATABASE_URL не найден в .env" >> "$LOGFILE"
  exit 1
fi

PROTO=${DB_URL%%://*}
CLEAN=${DB_URL#*://}
USERPASS=${CLEAN%%@*}
HOSTPORTDB=${CLEAN#*@}
DB_USER=${USERPASS%%:*}
DB_PASS=${USERPASS#*:}
DB_HOSTPORT=${HOSTPORTDB%%/*}
DB_NAME=${HOSTPORTDB#*/}
DB_HOST=${DB_HOSTPORT%%:*}
DB_PORT=${DB_HOSTPORT#*:}

CURRENT_HOST=$(docker exec -e PGPASSWORD="$DB_PASS" -i "$DB_HOST" \
  psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT host FROM hosts WHERE remark='BadBypass';" | xargs)

if [[ -z "$CURRENT_HOST" ]]; then
  echo "$(date) ❌ Не удалось получить текущий хост из БД" >> "$LOGFILE"
  exit 1
fi

STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://${CURRENT_HOST}/")

if [[ "$STATUS_CODE" -eq 400 ]]; then
  echo "$(date) ⚠️ Хост $CURRENT_HOST недоступен (400), перезапуск vk-tunnel..." >> "$LOGFILE"

  systemctl stop vk-tunnel.service
  sleep 3
  systemctl start vk-tunnel.service
  sleep 5

  NEW_HOST=$(journalctl -u vk-tunnel.service -n 50 --no-pager | grep -oP 'https://\K[^/]+' | tail -n1)

  if [[ -z "$NEW_HOST" ]]; then
    echo "$(date) ❌ Не удалось получить новый хост из логов vk-tunnel" >> "$LOGFILE"
    exit 1
  fi

  docker exec -e PGPASSWORD="$DB_PASS" -i "$DB_HOST" \
    psql -U "$DB_USER" -d "$DB_NAME" -c "UPDATE hosts SET host='${NEW_HOST}' WHERE remark='BadBypass';"

  if [[ $? -eq 0 ]]; then
    echo "$(date) ✅ Хост обновлён: ${NEW_HOST}" >> "$LOGFILE"
  else
    echo "$(date) ❌ Ошибка при обновлении БД" >> "$LOGFILE"
  fi
else
  echo "$(date) ✅ Хост $CURRENT_HOST отвечает кодом $STATUS_CODE, всё ок" >> "$LOGFILE"
fi
EOF

chmod +x "$UPDATER"
if ! crontab -l 2>/dev/null | grep -q "vk-host-updater.sh"; then
  (crontab -l 2>/dev/null; echo "* * * * * $UPDATER") | crontab -
fi
bgreen "VK Host Updater установлен и добавлен в cron (каждую минуту). Лог: /var/log/vk_host_update.log"

bgreen "\n=== ГОТОВО: Сводка ==="
echo
bblue "VK Tunnel:"
echo "  • systemd: vk-tunnel.service (порт локально: 10888)"
echo "  • Статус:  systemctl status vk-tunnel.service"
echo "  • Крон:    ежечасный healthcheck (vk-tunnel-healthcheck.sh)"
echo
bblue "Remnawave:"
echo "  • Каталог:        ${INSTALL_DIR}"
[[ -n "${FRONTEND_DOMAIN}" ]] && echo "  • FRONT_END_DOMAIN: ${FRONTEND_DOMAIN}"
[[ -n "${SUB_PUBLIC}" ]]      && echo "  • SUB_PUBLIC_DOMAIN: ${SUB_PUBLIC}"
[[ -n "${DB_URL}" ]]          && echo "  • DATABASE_URL:      ${DB_URL}"
[[ -f "${CRED_FILE}" ]] && { echo "  • Данные/пароли записаны в: ${CRED_FILE}"; tail -n +1 "${CRED_FILE}" | sed 's/^/     > /'; }
echo
echo "Управление контейнерами:  cd ${INSTALL_DIR} && docker compose ps"
echo "Перезапуск панели:        cd ${INSTALL_DIR} && docker compose down && docker compose up -d"
echo
bgreen "Всё установлено. Панель доступна по вашему домену."
