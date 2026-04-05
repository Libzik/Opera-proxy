#!/bin/sh
# ================================================================
#  opera-proxy installer for Keenetic / Entware
#  Режим: SOCKS5 (-socks-mode)
#  Параметры вынесены в /opt/etc/operaproxy.conf
# ================================================================

set -e

CONF_FILE="/opt/etc/operaproxy.conf"
INIT_SCRIPT="/opt/etc/init.d/S99opera-proxy"
CRONTAB_FILE="/opt/var/spool/cron/crontabs/root"
REPO_CONF="/opt/etc/opkg/sw.ext.io.conf"
IFACE="Proxy0"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
info() { printf "${C}[INFO]${N}  %s\n" "$*"; }
ok()   { printf "${G}[ OK ]${N}  %s\n" "$*"; }
warn() { printf "${Y}[WARN]${N}  %s\n" "$*"; }
die()  { printf "${R}[ERR ]${N}  %s\n" "$*"; exit 1; }

# ── 1. Архитектура ────────────────────────────────────────────
info "Определяем архитектуру..."
A=$(opkg print-architecture 2>/dev/null \
  | awk '/^arch/ && $2~/^(mips|mipsel|aarch64)/{sub(/[-_].*/,"",$2); print $2; exit}')
[ -z "$A" ] && die "Не удалось определить архитектуру"
ok "Архитектура: $A"

# ── 2. Репозиторий ────────────────────────────────────────────
info "Прописываем репозиторий sw.ext.io..."
mkdir -p /opt/etc/opkg
printf 'src/gz sw http://sw.ext.io/ent/%s\n' "$A" > "$REPO_CONF"
ok "Репо: http://sw.ext.io/ent/$A"

# ── 3. opkg update + curl ─────────────────────────────────────
info "opkg update..."
opkg update 2>&1 | tail -3
opkg list-installed | grep -q "^curl " || opkg install curl

# ── 4. Установка opera-proxy ──────────────────────────────────
if opkg list-installed | grep -q "^opera-proxy "; then
  warn "opera-proxy уже установлен — пропускаем"
else
  info "Ищем актуальный пакет..."
  U="http://sw.ext.io/ent/$A"
  PKG=$(curl -fsSL "$U/" \
    | grep -o "opera-proxy_[^\"]*_${A}[^\"]*\.ipk" \
    | sort -V | tail -1)
  [ -z "$PKG" ] && die "Пакет не найден в $U/"
  info "Скачиваем: $PKG"
  curl -fsSL "$U/$PKG" -o /tmp/opera-proxy.ipk
  opkg install /tmp/opera-proxy.ipk
  rm -f /tmp/opera-proxy.ipk
fi

command -v opera-proxy > /dev/null 2>&1 || die "opera-proxy не найден в PATH"
ok "Установлен: $(command -v opera-proxy)"

# ── 5. Конфиг-файл ────────────────────────────────────────────
info "Создаём конфиг $CONF_FILE..."

if [ -f "$CONF_FILE" ]; then
  warn "Конфиг уже существует — оставляем как есть:"
  cat "$CONF_FILE"
else
  cat > "$CONF_FILE" << 'EOF'
# ─────────────────────────────────────────────────────
#  Конфиг opera-proxy
#  После изменений: /opt/etc/init.d/S99opera-proxy restart
# ─────────────────────────────────────────────────────

# Регион: EU | AS | AM
COUNTRY="EU"

# Адрес прослушивания:
# 127.0.0.1 — только роутер (для интерфейса Proxy0)
# 0.0.0.0   — роутер + все устройства в LAN
BIND_ADDR="127.0.0.1"

# Порт SOCKS5
BIND_PORT="1080"

# Уровень логов: 10=debug 20=info 30=warn 40=error
VERBOSITY="20"
EOF
  ok "Конфиг создан: $CONF_FILE"
fi

# ── 6. Init-скрипт ────────────────────────────────────────────
info "Создаём init-скрипт $INIT_SCRIPT..."
cat > "$INIT_SCRIPT" << 'INITEOF'
#!/bin/sh
# Читаем конфиг
[ -f /opt/etc/operaproxy.conf ] && . /opt/etc/operaproxy.conf

ENABLED=yes
PROCS=opera-proxy
ARGS="-socks-mode -country ${COUNTRY:-EU} -bind-address ${BIND_ADDR:-127.0.0.1}:${BIND_PORT:-1080} -verbosity ${VERBOSITY:-40}"
PRECMD=
POSTCMD=
DESC="Opera Proxy SOCKS5"
PATH=/opt/sbin:/opt/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

. /opt/etc/init.d/rc.func
INITEOF
chmod 755 "$INIT_SCRIPT"
ok "Init-скрипт создан"

# ── 7. Запуск ─────────────────────────────────────────────────
info "Запускаем opera-proxy..."
"$INIT_SCRIPT" start
sleep 3
if "$INIT_SCRIPT" check > /dev/null 2>&1; then
  ok "Запущен (PID: $(pgrep opera-proxy | head -1))"
else
  die "Не запустился. Проверь: logread | grep opera"
fi

# ── 8. Watchdog cron ──────────────────────────────────────────
info "Добавляем watchdog в cron..."
mkdir -p "$(dirname "$CRONTAB_FILE")"
touch "$CRONTAB_FILE"
chmod 600 "$CRONTAB_FILE"
CRON_JOB="* * * * * $INIT_SCRIPT check >/dev/null 2>&1 || $INIT_SCRIPT start >/dev/null 2>&1"
if grep -qF "opera-proxy" "$CRONTAB_FILE" 2>/dev/null; then
  warn "Запись cron уже есть — пропускаем"
else
  printf '%s\n' "$CRON_JOB" >> "$CRONTAB_FILE"
  ok "Watchdog добавлен"
fi
[ -x /opt/etc/init.d/S98crond ] && \
  /opt/etc/init.d/S98crond restart > /dev/null 2>&1 && ok "crond перезапущен"

# ── 9. Интерфейс Proxy0 в Keenetic OS (SOCKS5) ───────────────
info "Создаём SOCKS5-интерфейс $IFACE в Keenetic OS..."
[ -f "$CONF_FILE" ] && . "$CONF_FILE"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
BIND_PORT="${BIND_PORT:-1080}"

if ! command -v ndmc > /dev/null 2>&1; then
  warn "ndmc не найден — настрой вручную:"
  warn "  Протокол: SOCKS5 | Адрес: $BIND_ADDR | Порт: $BIND_PORT"
else
  ndmc -c "interface $IFACE"
  ndmc -c "interface $IFACE proxy protocol socks5"
  ndmc -c "interface $IFACE proxy socks5-udp"
  ndmc -c "interface $IFACE proxy upstream $BIND_ADDR $BIND_PORT"
  ndmc -c "interface $IFACE description opera-proxy"
  ndmc -c "interface $IFACE ip global auto"
  ndmc -c "interface $IFACE up"
  ndmc -c "system configuration save"
  ok "Интерфейс $IFACE создан (SOCKS5)"
fi

# ── 10. Проверка ──────────────────────────────────────────────
info "Проверяем прокси..."
sleep 2
REAL_IP=$(curl -fsSL --max-time 10 https://ifconfig.me 2>/dev/null || echo "н/д")
PROXY_IP=$(curl -fsSL --max-time 10 \
  --socks5 "${BIND_ADDR}:${BIND_PORT}" \
  https://ifconfig.me 2>/dev/null || echo "н/д")

echo ""
printf "${G}══════════════════════════════════════════${N}\n"
printf "${G}  Готово!${N}\n"
printf "${G}══════════════════════════════════════════${N}\n"
printf "\n"
printf "  Прямой IP:       %s\n" "$REAL_IP"
printf "  IP через прокси: %s\n" "$PROXY_IP"
printf "\n"
printf "  Конфиг:    %s\n" "$CONF_FILE"
printf "  Режим:     SOCKS5\n"
printf "  Регион:    %s\n" "${COUNTRY:-EU}"
printf "  Прокси:    socks5://%s:%s\n" "$BIND_ADDR" "$BIND_PORT"
printf "\n"
printf "  Поменять настройки:\n"
printf "    vi %s\n" "$CONF_FILE"
printf "    %s restart\n" "$INIT_SCRIPT"
printf "\n"
printf "  Проверка вручную:\n"
printf "    curl --socks5 %s:%s https://ifconfig.me\n" "$BIND_ADDR" "$BIND_PORT"
printf "\n"
printf "  Логи:\n"
printf "    logread | grep -i opera\n"
printf "\n"
