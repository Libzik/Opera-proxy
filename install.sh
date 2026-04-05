#!/bin/sh
# =============================================================
#  opera-proxy installer for Keenetic / Entware
#  Автоопределение архитектуры, установка, автозапуск, watchdog
# =============================================================

set -e

COUNTRY="EU"                          # EU | AS | AM
BIND_ADDR="127.0.0.1"                  # 0.0.0.0 = доступен клиентам в LAN
BIND_PORT="18080"
INIT_SCRIPT="/opt/etc/init.d/S99opera-proxy"
CRONTAB_FILE="/opt/var/spool/cron/crontabs/root"
REPO_CONF="/opt/etc/opkg/sw.ext.io.conf"

# ── цвета ─────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
info()  { printf "${C}[INFO]${N}  %s\n" "$*"; }
ok()    { printf "${G}[ OK ]${N}  %s\n" "$*"; }
warn()  { printf "${Y}[WARN]${N}  %s\n" "$*"; }
die()   { printf "${R}[ERR ]${N}  %s\n" "$*"; exit 1; }

# ── 1. Определение архитектуры ────────────────────────────────
info "Определяем архитектуру..."

ARCH_RAW="$(uname -m 2>/dev/null || echo unknown)"
case "$ARCH_RAW" in
  aarch64)          ARCH="aarch64" ;;
  mips)             ARCH="mips"    ;;
  mipsel|mips64el)  ARCH="mipsel"  ;;
  *)
    # Запасной вариант — через opkg
    OPKG_ARCH="$(opkg print-architecture 2>/dev/null | awk '/^arch/{print $2}' | grep -v all | tail -1)"
    case "$OPKG_ARCH" in
      aarch64*)  ARCH="aarch64" ;;
      mipsel*)   ARCH="mipsel"  ;;
      mips*)     ARCH="mips"    ;;
      *)         die "Неизвестная архитектура: $ARCH_RAW / $OPKG_ARCH. Укажи вручную." ;;
    esac
    ;;
esac

REPO_URL="http://sw.ext.io/ent/${ARCH}"
ok "Архитектура: ${ARCH}  →  репо: ${REPO_URL}"

# ── 2. Добавление репозитория ─────────────────────────────────
info "Добавляем репозиторий sw.ext.io..."
mkdir -p /opt/etc/opkg
printf 'src/gz sw %s\n' "$REPO_URL" > "$REPO_CONF"
ok "Записан: $REPO_CONF"

# ── 3. Обновление списков пакетов ─────────────────────────────
info "opkg update..."
opkg update || warn "opkg update вернул ненулевой код — возможно, часть репо недоступна, продолжаем"

# ── 4. Установка opera-proxy ──────────────────────────────────
if opkg list-installed | grep -q "^opera-proxy "; then
  warn "opera-proxy уже установлен, пропускаем установку"
else
  info "Устанавливаем opera-proxy..."
  opkg install opera-proxy || die "Не удалось установить opera-proxy"
  ok "opera-proxy установлен"
fi

PROXY_BIN="$(command -v opera-proxy 2>/dev/null || echo /opt/bin/opera-proxy)"
[ -x "$PROXY_BIN" ] || die "Бинарь opera-proxy не найден в PATH"
ok "Бинарь: $PROXY_BIN"

# ── 5. Init-скрипт Entware (SysV + rc.func) ──────────────────
info "Создаём init-скрипт ${INIT_SCRIPT}..."

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

# ── 6. Запуск сервиса ─────────────────────────────────────────
info "Запускаем opera-proxy..."
"$INIT_SCRIPT" start
sleep 2

if "$INIT_SCRIPT" check > /dev/null 2>&1; then
  ok "opera-proxy запущен (PID: $(pgrep opera-proxy | head -1))"
else
  warn "Сервис не запустился — проверь логи: logread | grep opera"
fi

# ── 7. Watchdog через cron (без crontab -e) ───────────────────
info "Настраиваем watchdog в cron..."

mkdir -p "$(dirname "$CRONTAB_FILE")"
touch "$CRONTAB_FILE"
chmod 600 "$CRONTAB_FILE"

CRON_JOB="* * * * * $INIT_SCRIPT check > /dev/null 2>&1 || $INIT_SCRIPT start > /dev/null 2>&1"

if grep -qF "opera-proxy" "$CRONTAB_FILE" 2>/dev/null; then
  warn "Запись cron для opera-proxy уже существует, не дублируем"
else
  printf '%s\n' "$CRON_JOB" >> "$CRONTAB_FILE"
  ok "Добавлено в $CRONTAB_FILE"
fi

# Перезапуск cron-демона Entware
if [ -x /opt/etc/init.d/S98crond ]; then
  /opt/etc/init.d/S98crond restart > /dev/null 2>&1 && ok "crond перезапущен"
else
  warn "/opt/etc/init.d/S98crond не найден — перезапусти crond вручную"
fi

# ── 8. Настройка прокси на самом Keenetic (трафик роутера) ────
#
#  Keenetic CLI позволяет задать HTTP-прокси для системных нужд роутера.
#  Команда ниже выполняется через ndmc и применяется без перезагрузки.
#
info "Настраиваем прокси в Keenetic OS (системный трафик роутера)..."

ROUTER_IP="127.0.0.1"   # для трафика самого роутера — loopback

if command -v ndmc > /dev/null 2>&1; then
  ndmc -c "no proxy" > /dev/null 2>&1 || true
  ndmc -c "proxy http ${ROUTER_IP} ${BIND_PORT}" \
    && ok "Keenetic: системный прокси → http://${ROUTER_IP}:${BIND_PORT}" \
    || warn "ndmc: не удалось применить proxy — сделай вручную в веб-интерфейсе"
else
  warn "ndmc не найден — прокси для роутера задай вручную:"
  warn "  Веб-интерфейс → Общие настройки → Прокси-сервер"
  warn "  Адрес: 127.0.0.1  Порт: ${BIND_PORT}"
fi

# ── 9. Итог ───────────────────────────────────────────────────
echo ""
printf "${G}══════════════════════════════════════════════${N}\n"
printf "${G}  opera-proxy установлен и запущен!${N}\n"
printf "${G}══════════════════════════════════════════════${N}\n"
echo ""
echo "  Прокси-адрес для клиентов в LAN:"

# Получаем IP LAN-интерфейса
LAN_IP="$(ip -4 addr show br0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
[ -z "$LAN_IP" ] && LAN_IP="<IP_роутера>"
echo "    http://${LAN_IP}:${BIND_PORT}"
echo ""
echo "  Регион:  ${COUNTRY}"
echo "  Репо:    ${REPO_URL}"
echo ""
echo "  Управление:"
echo "    ${INIT_SCRIPT} start|stop|restart|check"
echo ""
echo "  Проверка прокси:"
echo "    curl -x http://127.0.0.1:${BIND_PORT} https://ifconfig.me"
echo ""
echo "  Логи:"
echo "    logread | grep -i opera"
echo ""
