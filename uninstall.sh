#!/bin/sh
BASE_DIR="/opt/router_bot"
LOG_DIR="/opt/var/log"
INIT_DIR="/opt/etc/init.d"
CROTAB="/opt/etc/crontab"

echo ""
echo "════════════════════════════════════════════"
echo "  Router Bot — удаление"
echo "════════════════════════════════════════════"
echo ""

# ---------- 1. Читаем config.env ----------
USE_VPN="no"
VPN_IF=""
VPN_SRC=""
ROUTE_TABLE="main"
WAN_SRC=""

if [ -f "$BASE_DIR/config.env" ]; then
    . "$BASE_DIR/config.env"
fi

# ---------- 2. Остановка бота ----------
echo "→ Останавливаю бота..."
/opt/etc/init.d/S98routerbot stop 2>/dev/null || true
for p in $(ps w | grep "router_bot/main.py" | grep -v grep | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null
done
# чистим осиротевшие flashkeen
for p in $(ps w | grep "flashkeen" | grep -v grep | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null
done
sleep 1

# ---------- 3. Cron ----------
echo "→ Отключаю cron healthcheck..."
if [ -f "$CROTAB" ]; then
    grep -v "S99routerbot_health" "$CROTAB" > "${CROTAB}.tmp" 2>/dev/null || true
    mv "${CROTAB}.tmp" "$CROTAB" 2>/dev/null || true
fi

# ---------- 4. Маршруты Telegram ----------
if [ "$USE_VPN" = "yes" ] && [ -n "$VPN_IF" ]; then
    echo "→ Удаляю маршруты Telegram из table $ROUTE_TABLE..."
    ip route del 149.154.160.0/20 table "$ROUTE_TABLE" 2>/dev/null || true
    ip route del 91.108.4.0/22   table "$ROUTE_TABLE" 2>/dev/null || true
    ip route del 149.154.166.110 table "$ROUTE_TABLE" 2>/dev/null || true
fi

# ---------- 5. init-скрипты ----------
echo "→ Удаляю init-скрипты..."
/opt/etc/init.d/S97tgroutes stop 2>/dev/null || true
rm -f "$INIT_DIR/S97tgroutes"
rm -f "$INIT_DIR/S98routerbot"
rm -f /opt/bin/routerbot_wrapper.sh
rm -f "$INIT_DIR/S99routerbot_health"

# ---------- 6. logrotate + PID ----------
rm -f /opt/etc/logrotate.d/router_bot
rm -f /var/run/routerbot.pid /var/run/routerbot.fail

# ---------- 7. Данные и логи ----------
echo ""
echo "Файлы программы:"
echo "  • $BASE_DIR (модули, конфиг, данные)"
echo "  • $LOG_DIR/router_bot.log"
# --- Чистка новых модулей ---
echo "→ Очищаю данные модулей BIRD и XKeen..."

# BIRD
if [ -f "/opt/etc/init.d/S70bird" ]; then
    /opt/etc/init.d/S70bird stop 2>/dev/null || true
fi
for p in $(ps w | grep -v grep | grep -E "[b]ird " | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null || true
done
rm -f /opt/etc/init.d/S70bird
rm -f /opt/sbin/bird /opt/sbin/birdc /opt/bin/bird /opt/bin/birdc
rm -f /opt/etc/bird.conf /opt/etc/bird.conf.bak
rm -rf /opt/var/run/bird* /opt/var/log/bird*

# XKeen
if [ -f "/opt/sbin/xkeen" ]; then
    xkeen -remove 2>/dev/null || true
fi
rm -f /opt/sbin/xkeen /opt/bin/xkeen
rm -rf /opt/sbin/.xkeen
rm -rf /opt/etc/xkeen
rm -rf /opt/var/log/xkeen* /opt/var/run/xkeen*

# MTProxy
if [ -f "/opt/etc/init.d/S99tg-ws-proxy" ]; then
    /opt/etc/init.d/S99tg-ws-proxy stop 2>/dev/null || true
fi
for p in $(ps w | grep -v grep | grep -E "[t]g-ws-proxy" | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null || true
done
rm -f /opt/etc/init.d/S99tg-ws-proxy
rm -f /opt/bin/tg-ws-proxy
rm -rf /opt/etc/tg-ws-proxy
rm -f /opt/var/log/tg-ws-proxy.log
rm -rf /opt/var/run/tg-ws-proxy*

# Данные модулей
rm -rf "$BASE_DIR/data/xkeen" "$BASE_DIR/data/bird" "$BASE_DIR/data/mtproxy"

echo "✅ Модули BIRD и XKeen очищены"
echo ""

echo ""
printf "Удалить эти файлы? (y/N): "
read ANS

if [ "$ANS" = "y" ] || [ "$ANS" = "Y" ]; then
    rm -rf "$BASE_DIR"
    rm -f "$LOG_DIR/router_bot.log"*
    echo "✅ Данные и логи удалены"
else
    echo "⚠️  Данные сохранены: $BASE_DIR"
fi

# =================== продолжение в следующей части ===================

# ---------- 8. Зависимости ----------
echo ""
echo "────────────────────────────────────────────"
echo "  Зависимости"
echo "────────────────────────────────────────────"
echo ""

INSTALLED=""

if [ -x /opt/bin/python3 ] && /opt/bin/python3 -c "import telegram" 2>/dev/null; then
    V=$(/opt/bin/python3 -c "import telegram; print(telegram.__version__)" 2>/dev/null)
    INSTALLED="$INSTALLED\n    • python-telegram-bot (v$V) — pip-пакет"
fi

for pkg_bin in \
    "python3:/opt/bin/python3" \
    "python3-pip:/opt/bin/pip3" \
    "curl:/opt/bin/curl" \
    "ca-certificates:/opt/etc/ssl/certs/ca-certificates.crt" \
    "openssh-client:/opt/bin/ssh" \
    "openssh-client-utils:/opt/bin/ssh-keyscan" \
    "openssh-keygen:/opt/bin/ssh-keygen"
do
    pkg="${pkg_bin%%:*}"
    bin="${pkg_bin#*:}"
    if [ -e "$bin" ]; then
        INSTALLED="$INSTALLED\n    • $pkg — opkg-пакет"
    fi
done

if [ -z "$INSTALLED" ]; then
    echo "Ничего из наших зависимостей не найдено."
else
    echo "Установлено:"
    printf "$INSTALLED\n"
    echo ""
    echo "⚠️  ВНИМАНИЕ: python3, curl, openssh могут использоваться"
    echo "    другими программами. Если не уверены — откажитесь."
    echo ""
    printf "Удалить их тоже? (y/N): "
    read DEL_DEPS

    if [ "$DEL_DEPS" = "y" ] || [ "$DEL_DEPS" = "Y" ]; then
        echo ""
        echo "→ Удаляю pip-пакет..."
        /opt/bin/pip3 uninstall -y python-telegram-bot 2>/dev/null || true

        echo "→ Удаляю opkg-пакеты..."
        opkg remove openssh-client-utils 2>/dev/null || true
        opkg remove openssh-keygen 2>/dev/null || true
        opkg remove openssh-client 2>/dev/null || true
        opkg remove python3-pip 2>/dev/null || true
        opkg remove curl 2>/dev/null || true
        opkg remove ca-certificates 2>/dev/null || true

        echo ""
        printf "Удалить python3? Может использоваться другими скриптами. (y/N): "
        read DEL_PY
        if [ "$DEL_PY" = "y" ] || [ "$DEL_PY" = "Y" ]; then
            opkg remove python3 2>/dev/null || true
        else
            echo "  python3 оставлен."
        fi
        echo "✅ Зависимости удалены (по выбору)"
    else
        echo "  Зависимости оставлены."
    fi
fi

# ---------- 9. resolv.conf ----------
if [ -f /etc/resolv.conf ]; then
    if grep -q "^nameserver 8.8.8.8" /etc/resolv.conf 2>/dev/null; then
        echo ""
        printf "Убрать nameserver 8.8.8.8 из /etc/resolv.conf? (y/N): "
        read DEL_DNS
        if [ "$DEL_DNS" = "y" ] || [ "$DEL_DNS" = "Y" ]; then
            grep -v "^nameserver 8.8.8.8" /etc/resolv.conf > /etc/resolv.conf.tmp 2>/dev/null || true
            mv /etc/resolv.conf.tmp /etc/resolv.conf 2>/dev/null || true
            echo "  ✅ DNS обновлён"
        fi
    fi
fi

# ---------- 10. Итог ----------
echo ""
echo "════════════════════════════════════════════"
echo "  ✅ Удаление завершено"
echo "════════════════════════════════════════════"
echo ""
echo "  Если отказались удалять зависимости —"
echo "  они остались в системе."
echo ""
# ---------- XX. Чистка новых модулей ----------
echo "→ Чищу данные новых модулей..."
rm -rf "$BASE_DIR/data/hydraroute"
rm -rf "$BASE_DIR/data/mtproxy"
rm -rf "$BASE_DIR/data/keen_pbr"
rm -rf "$BASE_DIR/data/neofit"
rm -rf "$BASE_DIR/data/usque_keenetic"

# ---------- XX. Чистка hrneo от наследия ----------
rm -f /opt/etc/HydraRoute/hrneo.conf.bak.*