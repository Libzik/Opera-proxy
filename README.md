# 🎭 Opera Proxy для Keenetic

Локальный HTTP-прокси через серверы **Opera VPN (SurfEasy)** — без регистрации, без приложений.  
Трафик идёт через **TLS/443** → выглядит как обычный HTTPS, обходит блокировки РКН.

```
Устройство → HTTP :18080 → opera-proxy → TLS 443 → *.sec-tunnel.com → 🌍
```

---

## ⚡ Установка

```
sh -c "$(curl -fsSL https://raw.githubusercontent.com/Libzik/Opera-proxy/refs/heads/main/install.sh)"

```

Скрипт сам определит архитектуру (`aarch64` / `mips` / `mipsel`), установит пакет,  
создаст автозапуск, watchdog и интерфейс **Proxy0** в Keenetic OS.

---

## 🌐 Регионы

| Код | Регион |
|-----|--------|
| `EU` | 🇪🇺 Европа (по умолчанию) |
| `AS` | 🌏 Азия |
| `AM` | 🌎 Америка |

Сменить регион:
```sh
# В /opt/etc/init.d/S99opera-proxy найди ARGS и измени -country
ARGS="-country AS -bind-address 127.0.0.1:18080 -verbosity 20"
/opt/etc/init.d/S99opera-proxy restart
```

---

## 🔧 Управление

```sh
/opt/etc/init.d/S99opera-proxy start    # запуск
/opt/etc/init.d/S99opera-proxy stop     # остановка
/opt/etc/init.d/S99opera-proxy restart  # перезапуск
/opt/etc/init.d/S99opera-proxy check    # жив ли процесс
```

---

## ✅ Проверка

```sh
# Должен вернуть европейский IP
curl -x http://127.0.0.1:18080 https://ifconfig.me

# Логи
logread | grep -i opera
```

---

## 📡 Использование на устройствах в LAN

**Через Keenetic** — в веб-интерфейсе появится интерфейс **Proxy0**,  
назначь его нужным устройствам через **Приоритет подключений**.

**Вручную на устройстве** — укажи прокси:
```
HTTP  192.168.1.1 : 18080
```
> Для этого в init-скрипте замени `127.0.0.1` → `0.0.0.0` в ARGS и перезапусти.

---

## 🗑️ Удаление

```sh
/opt/etc/init.d/S99opera-proxy stop
rm -f /opt/etc/init.d/S99opera-proxy
sed -i '/opera-proxy/d' /opt/var/spool/cron/crontabs/root
opkg remove opera-proxy
rm -f /opt/etc/opkg/sw.ext.io.conf
ndmc -c "no interface Proxy0"
ndmc -c "system configuration save"
```

---

## 🔗 Ссылки

- [opera-proxy (форк для роутеров)](https://github.com/Alexey71/opera-proxy)
