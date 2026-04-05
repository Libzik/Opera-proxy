#!/bin/sh
# ================================================================
#  opera-proxy installer for Keenetic / Entware
#  - Автоопределение архитектуры
#  - Установка opera-proxy
#  - Init-скрипт + watchdog cron
#  - Создание HTTP proxy-интерфейса Proxy0 в Keenetic OS
# ================================================================

set -e

COUNTRY="EU"
BIND_PORT="18080"
BIND_ADDR="127.0.0.1"
IFACE="Proxy0"
INIT_SCRIPT="/opt/etc/init.d/S99opera-proxy"
CRONTAB_FILE="/opt/var/spool/cron/crontabs/root"
REPO_CONF="/opt/etc/opkg/sw.ext.io.conf"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
info() { printf "${C}[INFO]${N}  %s\n" "$*"; }
ok()   { printf "${G}[ OK ]${N}  %s\n" "$*"; }
warn() { printf "${Y}[WARN]${N}  %s\n" "$*"; }
die()  { printf "${R}[ERR ]${N}  %s\n" "$*"; exit 1; }

# ── 1. Архитектура ────────────────────────────────────────────
info "Определяем архитектуру..."
A=$(opkg print-architecture 2>/dev/null \
  | awk '/^arch/ && $2~/^(mips|mipsel|aarch64)/{sub(/[-_].*/,"",$2); print $2; exit}')
[ -z "$A" ] && die "Не удалось определить архитектуру. Проверь: opkg print-architecture"
ok "Архитектура: $A"

# ── 2. Репозиторий ────────────────────────────────────────────
info "Прописываем репозиторий sw.ext.io..."
mkdir -p /opt/etc/opkg
printf 'src/gz sw http://sw.ext.io/ent/%s\n' "$A" > "$REPO_CONF"
ok "Репо: http://sw.ext.io/ent/$A"

# ── 3. Обновление + curl ──────────────────────────────────────
info "opkg update..."
opkg update 2>&1 | tail -3
opkg list-installed | grep -q "^curl " || opkg install curl

# ── 4. Установка opera-proxy ──────────────────────────────────
if opkg list-installed | grep -q "^opera-proxy "; then
  warn "opera-proxy уже установлен — пропускаем"
else
  info "Ищем актуальный пакет opera-proxy..."
  U="http://sw.ext.io/ent/$A"
  PKG=$(curl -fsSL "$U/" \
    | grep -o "opera-proxy_[^\"]*_${A}[^\"]*\.ipk" \
    | sort -V | tail -1)
  [ -z "$PKG" ] && die "Пакет opera-proxy не найден в $U/"
  info "Скачиваем: $U/$PKG"
  curl -fsSL "$U/$PKG" -o /tmp/opera-proxy.ipk
  opkg install /tmp/opera-proxy.ipk
  rm -f /tmp/opera-proxy.ipk
fi

command -v opera-proxy > /dev/null 2>&1 || die "opera-proxy не найден в PATH после установки"
ok "opera-proxy установлен: $(command -v opera-proxy)"

# ── 5. Init-скрипт ────────────────────────────────────────────
info "Создаём init-скрипт $INIT_SCRIPT..."
cat > "$INIT_SCRIPT" << INITEOF
#!/bin/sh
ENABLED=yes
PROCS=opera-proxy
ARGS="-country ${COUNTRY} -bind-address ${BIND_ADDR}:${BIND_PORT} -verbosity 20"
PRECMD=
POSTCMD=
DESC="Opera Proxy (${COUNTRY})"
PATH=/opt/sbin:/opt/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
. /opt/etc/init.d/rc.func
INITEOF
chmod 755 "$INIT_SCRIPT"
ok "Init-скрипт создан"

# ── 6. Запуск ─────────────────────────────────────────────────
info "Запускаем opera-proxy..."
"$INIT_SCRIPT" start
sleep 3
if "$INIT_SCRIPT" check > /dev/null 2>&1; then
  ok "opera-proxy запущен (PID: $(pgrep opera-proxy | head -1))"
else
  die "opera-proxy не запустился. Проверь: logread | grep opera"
fi

# ── 7. Watchdog cron ──────────────────────────────────────────
info "Добавляем watchdog в cron..."
mkdir -p "$(dirname "$CRONTAB_FILE")"
touch "$CRONTAB_FILE"
chmod 600 "$CRONTAB_FILE"

CRON_JOB="* * * * * $INIT_SCRIPT check >/dev/null 2>&1 || $INIT_SCRIPT start >/dev/null 2>&1"
if grep -qF "opera-proxy" "$CRONTAB_FILE" 2>/dev/null; then
  warn "Запись cron уже есть — не дублируем"
else
  printf '%s\n' "$CRON_JOB" >> "$CRONTAB_FILE"
  ok "Watchdog добавлен в $CRONTAB_FILE"
fi

if [ -x /opt/etc/init.d/S98crond ]; then
  /opt/etc/init.d/S98crond restart > /dev/null 2>&1 && ok "crond перезапущен"
fi

# ── 8. Proxy-интерфейс в Keenetic OS ─────────────────────────
info "Создаём HTTP proxy-интерфейс $IFACE в Keenetic OS..."

if ! command -v ndmc > /dev/null 2>&1; then
  warn "ndmc не найден — создай интерфейс вручную в веб-интерфейсе:"
  warn "  Сеть → Интерфейсы → Добавить → Proxy"
  warn "  Протокол: HTTP  Адрес: 127.0.0.1  Порт: $BIND_PORT"
else
  IFACE_CFG="interface $IFACE"
  ndmc -c "$IFACE_CFG"
  ndmc -c "$IFACE_CFG proxy protocol http"
  ndmc -c "$IFACE_CFG proxy upstream ${BIND_ADDR} ${BIND_PORT}"
  ndmc -c "$IFACE_CFG description opera-proxy"
  ndmc -c "$IFACE_CFG ip global auto"
  ndmc -c "$IFACE_CFG up"
  ndmc -c "system configuration save"
  ok "Интерфейс $IFACE создан и поднят"
fi

# ── 9. Проверка прокси ────────────────────────────────────────
info "Проверяем прокси..."
sleep 2
REAL_IP=$(curl -fsSL --max-time 10 https://ifconfig.me 2>/dev/null || echo "недоступен")
PROXY_IP=$(curl -fsSL --max-time 10 -x "http://${BIND_ADDR}:${BIND_PORT}" \
  https://ifconfig.me 2>/dev/null || echo "недоступен")

echo ""
printf "${G}══════════════════════════════════════════════${N}\n"
printf "${G}  Установка завершена!${N}\n"
printf "${G}══════════════════════════════════════════════${N}\n"
echo ""
printf "  Прямой IP:       %s\n" "$REAL_IP"
printf "  IP через прокси: %s\n" "$PROXY_IP"
echo ""
echo "  Интерфейс Keenetic: $IFACE"
echo "  Протокол:           HTTP"
echo "  Upstream:           ${BIND_ADDR}:${BIND_PORT}"
echo "  Регион Opera:       $COUNTRY"
echo ""
echo "  Управление:"
echo "    $INIT_SCRIPT start|stop|restart|check"
echo ""
echo "  Проверка вручную:"
echo "    curl -x http://${BIND_ADDR}:${BIND_PORT} https://ifconfig.me"
echo ""
echo "  Логи:"
echo "    logread | grep -i opera"
echo ""
