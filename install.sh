#!/bin/sh
set -e

BASE_DIR="/opt/router_bot"
LOG_DIR="/opt/var/log"
INIT_DIR="/opt/etc/init.d"

MODE="${RB_MODE:-auto}"
NEW_VERSION="${RB_VERSION:-}"
if [ "$MODE" = "auto" ]; then
    if [ -f "$BASE_DIR/config.env" ]; then
        MODE="upgrade"
    else
        MODE="install"
    fi
fi

# ---- всегда копируем helper-скрипты в /opt/bin ----
# (работает в любом режиме — install, upgrade, reinstall)
mkdir -p /opt/bin
if [ -f "$BASE_DIR/core/wrapper.sh" ]; then
    cp -f "$BASE_DIR/core/wrapper.sh" /opt/bin/routerbot_wrapper.sh
    chmod +x /opt/bin/routerbot_wrapper.sh
fi
if [ -f "$BASE_DIR/core/rb" ]; then
    cp -f "$BASE_DIR/core/rb" /opt/bin/rb
    chmod +x /opt/bin/rb
fi

echo ""
echo "════════════════════════════════════════════"
echo "  Router Bot — Установщик"
echo "════════════════════════════════════════════"
echo ""

# ---------- 1. Проверка и установка зависимостей ----------
echo "→ Проверяю зависимости..."
echo ""

MISSING_OPKG=""
MISSING_PIP=""

for pkg_bin in \
    "python3:/opt/bin/python3" \
    "python3-pip:/opt/bin/pip3" \
    "curl:/opt/bin/curl" \
    "ca-certificates:/opt/etc/ssl/certs/ca-certificates.crt"
do
    pkg="${pkg_bin%%:*}"
    bin="${pkg_bin#*:}"
    if [ ! -e "$bin" ]; then
        MISSING_OPKG="$MISSING_OPKG $pkg"
    fi
done

# OpenSSH-пакеты проверяем через opkg, а НЕ по пути:
# dropbear создаёт симлинк /opt/bin/ssh -> /opt/sbin/dropbear,
# из-за чего проверка "-e /opt/bin/ssh" обманывается.
for pkg in openssh-client openssh-keygen; do
    if ! opkg list-installed 2>/dev/null | grep -q "^${pkg} "; then
        MISSING_OPKG="$MISSING_OPKG $pkg"
    fi
done

# Финальная валидация: /opt/bin/ssh должен быть реально OpenSSH
if [ -x /opt/bin/ssh ]; then
    if ! /opt/bin/ssh -V 2>&1 | grep -q OpenSSH; then
        case " $MISSING_OPKG " in
            *" openssh-client "*) ;;
            *) MISSING_OPKG="$MISSING_OPKG openssh-client" ;;
        esac
    fi
fi

if [ ! -x /bin/ndmc ]; then
    echo "❌ /bin/ndmc не найден. Это не Keenetic?"
    exit 1
fi

# Системные утилиты, нужные для работы init-скриптов и сети
for tool in ip start-stop-daemon; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "  [WARN] Не найдена утилита: $tool — установка может не сработать"
    fi
done
echo "  ✅ /bin/ndmc"

# python-telegram-bot: проверяем вне зависимости от того, есть ли python3
if [ ! -x /opt/bin/python3 ]; then
    case " $MISSING_OPKG " in
        *" python3 "*) ;;
        *) MISSING_OPKG="$MISSING_OPKG python3" ;;
    esac
    MISSING_PIP="python-telegram-bot[job-queue]"
elif ! /opt/bin/python3 -c "import telegram" 2>/dev/null; then
    MISSING_PIP="python-telegram-bot[job-queue]"
else
    echo "  python-telegram-bot: OK"
fi

# python3 -m pip должен быть доступен, иначе установка упадёт
if [ -x /opt/bin/python3 ] && ! /opt/bin/python3 -m pip --version >/dev/null 2>&1; then
    case " $MISSING_OPKG " in
        *" python3-pip "*) ;;
        *) MISSING_OPKG="$MISSING_OPKG python3-pip" ;;
    esac
fi

echo ""
if [ -z "$MISSING_OPKG" ] && [ -z "$MISSING_PIP" ]; then
    echo "✅ Все зависимости на месте"
else
    echo "────────────────────────────────────────────"
    echo "  Не хватает:"
    [ -n "$MISSING_OPKG" ] && echo "    • opkg:$MISSING_OPKG"
    [ -n "$MISSING_PIP"  ] && echo "    • pip: $MISSING_PIP"
    echo "────────────────────────────────────────────"
    echo ""
    printf "Установить сейчас? (~60 сек) (y/N): "
    read DO_INSTALL
    if [ "$DO_INSTALL" != "y" ] && [ "$DO_INSTALL" != "Y" ]; then
        echo "Отмена. Установите вручную:"
        [ -n "$MISSING_OPKG" ] && echo "  opkg install$MISSING_OPKG"
        [ -n "$MISSING_PIP"  ] && echo "  pip3 install \"$MISSING_PIP\""
        exit 1
    fi

    if [ -n "$MISSING_OPKG" ]; then
        echo ""
        echo "→ opkg update..."
        opkg update >/dev/null 2>&1 || true
        echo "→ opkg install$MISSING_OPKG"
        opkg install $MISSING_OPKG || { echo "❌ opkg install не удался"; exit 1; }
    fi

    if [ -n "$MISSING_PIP" ]; then
        echo ""
        echo "→ pip3 install (может занять ~30 сек)"
        /opt/bin/python3 -m pip install --quiet --upgrade "$MISSING_PIP" || {
            echo "❌ pip3 install не удался"; exit 1;
        }
    fi
    echo ""
    echo "✅ Зависимости установлены"
fi
echo ""

# ---------- 2. Проверка файлов фреймворка ----------
REQUIRED="
$BASE_DIR/main.py
$BASE_DIR/core/__init__.py
$BASE_DIR/core/main.py
$BASE_DIR/core/config.py
$BASE_DIR/core/router.py
$BASE_DIR/core/utils.py
$BASE_DIR/modules/__init__.py
$BASE_DIR/modules/net_watch/__init__.py
$BASE_DIR/modules/net_watch/module.py
$BASE_DIR/modules/ssh_control/__init__.py
$BASE_DIR/modules/ssh_control/module.py
$BASE_DIR/modules/ssh_control/ssh_client.py
$BASE_DIR/modules/ssh_control/storage.py
$BASE_DIR/modules/system/__init__.py
$BASE_DIR/modules/system/module.py
$BASE_DIR/modules/hydraroute/__init__.py
$BASE_DIR/modules/hydraroute/module.py
$BASE_DIR/modules/hydraroute/actions.py
$BASE_DIR/modules/flashkeen/__init__.py
$BASE_DIR/modules/flashkeen/module.py
$BASE_DIR/modules/flashkeen/actions.py
$BASE_DIR/modules/xkeen/__init__.py
$BASE_DIR/modules/xkeen/module.py
$BASE_DIR/modules/xkeen/actions.py
$BASE_DIR/modules/bird/__init__.py
$BASE_DIR/modules/bird/module.py
$BASE_DIR/modules/bird/actions.py
$BASE_DIR/modules/mtproxy/__init__.py
$BASE_DIR/modules/mtproxy/module.py
$BASE_DIR/modules/mtproxy/actions.py
"
MISSING_FILES=""
for f in $REQUIRED; do
    [ -f "$f" ] || MISSING_FILES="$MISSING_FILES $f"
done

if [ -n "$MISSING_FILES" ]; then
    echo "❌ Не хватает файлов:"
    for f in $MISSING_FILES; do echo "   $f"; done
    exit 1
fi
echo "✅ Все файлы фреймворка на месте"
echo ""

# ---------- 2a. Запись версии ----------
if [ -n "$NEW_VERSION" ]; then
    printf '%s\n' "$NEW_VERSION" > "$BASE_DIR/VERSION"
    echo "  → Версия: $NEW_VERSION"
    echo ""
fi

# ---------- 2b. Режим обновления ----------
if [ "$MODE" != "install" ]; then
    echo "────────────────────────────────────────────"
    echo "  Режим: $MODE"
    echo "────────────────────────────────────────────"
    echo ""
    echo "→ Перезапускаю бота..."
    /opt/etc/init.d/S98routerbot restart 2>/dev/null || true
    echo ""
    echo "════════════════════════════════════════════"
    echo "  ✅ Обновление завершено"
    echo "════════════════════════════════════════════"
    echo ""
    echo "  Логи:  tail -f $LOG_DIR/router_bot.log"
    echo ""
    exit 0
fi

# ---------- 3. Автоопределение сети ----------
echo "→ Определение параметров сети..."

WAN_IF=$(ip route show default | awk '{
    for(i=1;i<=NF;i++) if ($i=="dev") iface=$(i+1);
    if (iface !~ /^(opkgtun|tun|wg|tap|ppp)/) { print iface; exit }
}')
if [ -z "$WAN_IF" ]; then
    printf "  Не удалось определить WAN. Введите вручную: "
    read WAN_IF
fi

WAN_SRC=$(ip -4 -o addr show dev "$WAN_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
if [ -z "$WAN_SRC" ]; then
    printf "  Не удалось определить IP роутера. Введите вручную: "
    read WAN_SRC
fi

WAN_TABLE=$(ip rule show 2>/dev/null | awk -v src="$WAN_SRC" '
    $0 ~ "from " src " " { for(i=1;i<=NF;i++) if($i=="lookup") { print $(i+1); exit } }
')
[ -z "$WAN_TABLE" ] && WAN_TABLE="main"

echo "  WAN-интерфейс: $WAN_IF"
echo "  IP роутера:    $WAN_SRC"
echo "  Таблица:       $WAN_TABLE"
echo ""

# =================== продолжение в следующей части ===================

# ---------- 4. Доступ к Telegram ----------
echo "────────────────────────────────────────────"
echo "  Доступ к Telegram"
echo "────────────────────────────────────────────"
echo ""

printf "→ Проверяю доступность Telegram напрямую... "
if /opt/bin/curl -sf --max-time 8 "https://api.telegram.org" >/dev/null 2>&1; then
    echo "✅ доступен"
    echo "  VPN не нужен."
    USE_VPN="no"
    VPN_IF=""
    VPN_SRC=""
else
    echo "❌ недоступен"
    echo "  Похоже, Telegram блокируется. Настроим VPN."
    echo ""

    # Поиск туннелей (без tunl0, PPP, Tap и т.п.)
    TUNABLES=$(ip -o link show 2>/dev/null \
        | sed 's/@[^ :]*//g' \
        | awk -F': ' '$2 ~ /^(opkgtun[0-9]+|nwg[0-9]+|wg[0-9]+|ppp[0-9]+|tap[0-9]+)$/ { print $2 }')

    if [ -z "$TUNABLES" ]; then
        echo "  Туннелей не найдено."
        printf "  Введите имя туннеля вручную или Enter для отмены: "
        read VPN_IF
        [ -z "$VPN_IF" ] && { echo "  Отмена."; exit 1; }
    else
        UP_LIST=""
        DOWN_LIST=""
        for t in $TUNABLES; do
            tip=$(ip -4 -o addr show dev "$t" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
            # UP определяется по флагу <...,UP,...>, а не по 'state' (у WG он UNKNOWN)
            if ip -o link show dev "$t" 2>/dev/null | grep -q '<[^>]*UP[^>]*>'; then
                state="UP"
            else
                state="DOWN"
            fi
            line="    • $t  ${tip:-no-IP}  [$state]"
            if [ "$state" = "UP" ]; then
                UP_LIST="${UP_LIST}${line}\n"
            else
                DOWN_LIST="${DOWN_LIST}${line}\n"
            fi
        done

        echo "  Доступные туннели:"
        [ -n "$UP_LIST" ] && printf "$UP_LIST"
        [ -n "$DOWN_LIST" ] && printf "$DOWN_LIST"
        echo ""
        printf "  Выберите туннель для Telegram (Enter = первый UP): "
        read VPN_IF
        if [ -z "$VPN_IF" ]; then
            VPN_IF=$(echo "$UP_LIST" | head -1 | awk '{print $2}')
            [ -z "$VPN_IF" ] && VPN_IF=$(echo "$TUNABLES" | head -1)
            echo "  Беру по умолчанию: $VPN_IF"
        fi
    fi

    VPN_SRC=$(ip -4 -o addr show dev "$VPN_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    if [ -z "$VPN_SRC" ]; then
        printf "  Введите IP туннеля $VPN_IF: "
        read VPN_SRC
    fi

    echo ""
    printf "→ Проверяю доступ к Telegram через $VPN_IF ($VPN_SRC)... "
    ip route add 149.154.166.110 dev "$VPN_IF" src "$VPN_SRC" table "$WAN_TABLE" 2>/dev/null

    if /opt/bin/curl -sf --max-time 8 "https://api.telegram.org" >/dev/null 2>&1; then
        echo "✅ работает"
        USE_VPN="yes"
    else
        echo "❌ не проходит"
        printf "  Продолжить установку всё равно? (y/N): "
        read ANS
        if [ "$ANS" = "y" ] || [ "$ANS" = "Y" ]; then
            USE_VPN="yes"
            echo "  ⚠️  VPN настроен, но пока не работает."
        else
            echo "  Отмена."
            exit 1
        fi
    fi
    ip route del 149.154.166.110 table "$WAN_TABLE" 2>/dev/null
fi
echo ""

# ---------- 5. Выбор модулей ----------
echo "────────────────────────────────────────────"
echo "  Выбор модулей"
echo "────────────────────────────────────────────"
echo ""
echo "По умолчанию все модули будут установлены."
echo "Введите 'n' чтобы пропустить любой из них."
echo ""

ENABLED=""

printf "Установить все модули без вопросов? (y/N): "
read ANS_ALL
echo ""
if [ "$ANS_ALL" = "y" ] || [ "$ANS_ALL" = "Y" ]; then
    ENABLED=",net_watch,ssh_control,system,hydraroute,flashkeen,xkeen,bird,mtproxy,keen_pbr,neofit,usque_keenetic"
    echo "════════════════════════════════════════════"
    echo "  ✅ Выбрано: установка ВСЕХ модулей"
    echo "════════════════════════════════════════════"
    echo ""
    echo "Модули:"
    echo "  📡 Net Watch    — мониторинг сетевых клиентов"
    echo "  💻 SSH Control  — управление по SSH"
    echo "  🖥  System       — состояние роутера + обновления KeeneticOS"
    echo "  🐍 HydraRoute   — HR Neo + Web + hrdns, watchlist, match"
    echo "  💾 Flashkeen    — менеджер дисков и Entware"
    echo "  🐾 XKeen        — Xray/Mihomo маршрутизация"
    echo "  🐦 BIRD         — BGP/OSPF"
    echo "  🌐 MTProxy      — MTProto-прокси для Telegram"
    echo "  🛤  Keen-PBR     — policy-based routing"
    echo "  🔀 NeoFit       — веб-панель Xray/Sing-Box"
    echo "  🌐 Usque WARP   — Cloudflare MASQUE"
    echo ""
    echo "Зависимости: python3, python-telegram-bot, curl, openssh-client, openssh-keygen"
    echo ""
    SKIP_DIALOGS=1
else
    echo "По умолчанию все модули будут установлены."
    echo "Введите 'n' чтобы пропустить любой из них."
    echo ""
    SKIP_DIALOGS=0
fi

if [ "$SKIP_DIALOGS" != "1" ]; then
# --- Net Watch ---
echo "📡 Net Watch"
echo "   Мониторинг сетевых клиентов: список подключённых"
echo "   устройств, история, блокировка по MAC, статистика,"
echo "   определение моделей по SSDP."
echo ""
printf "   Установить? (Y/n): "
read ANS_NW
if [ "$ANS_NW" != "n" ] && [ "$ANS_NW" != "N" ]; then
    ENABLED="$ENABLED,net_watch"
    echo "   ✅ Net Watch будет установлен"
else
    echo "   ⏭  Net Watch пропущен"
fi
echo ""

# --- SSH Control ---
echo "💻 SSH Control"
echo "   Управление устройствами по SSH: подключение к роутеру"
echo "   или другим хостам, выполнение команд и скриптов,"
echo "   интерактивные ответы (y/n) через кнопки Telegram."
echo ""
printf "   Установить? (Y/n): "
read ANS_SSH
if [ "$ANS_SSH" != "n" ] && [ "$ANS_SSH" != "N" ]; then
    ENABLED="$ENABLED,ssh_control"
    echo "   ✅ SSH Control будет установлен"
else
    echo "   ⏭  SSH Control пропущен"
fi
echo ""

# --- System ---
echo "🖥 System"
echo "   Состояние роутера: CPU, RAM, Swap, место на диске,"
echo "   информация о модели и прошивке. Проверка и установка"
echo "   обновлений KeeneticOS прямо из Telegram."
echo ""
printf "   Установить? (Y/n): "
read ANS_SYS
if [ "$ANS_SYS" != "n" ] && [ "$ANS_SYS" != "N" ]; then
    ENABLED="$ENABLED,system"
    echo "   ✅ System будет установлен"
else
    echo "   ⏭  System пропущен"
fi
echo ""

# --- HydraRoute ---
echo "🐍 HydraRoute"
echo "   Установка и управление HydraRoute: установка"
echo "   веб-интерфейса HRweb, обновление пакетов,"
echo "   стандартное и полное удаление."
echo ""
printf "   Установить? (Y/n): "
read ANS_HR
if [ "$ANS_HR" != "n" ] && [ "$ANS_HR" != "N" ]; then
    ENABLED="$ENABLED,hydraroute"
    echo "   ✅ HydraRoute будет установлен"
else
    echo "   ⏭  HydraRoute пропущен"
fi
echo ""

# --- Flashkeen ---
echo "💾 Flashkeen"
echo "   Менеджер дисков и Entware: разметка разделов,"
echo "   бэкапы Entware, установка с нуля, обновление."
echo "   Полноценный интерактивный терминал в Telegram."
echo ""
printf "   Установить? (Y/n): "
read ANS_FK
if [ "$ANS_FK" != "n" ] && [ "$ANS_FK" != "N" ]; then
    ENABLED="$ENABLED,flashkeen"
    echo "   ✅ Flashkeen будет установлен"
else
    echo "   ⏭  Flashkeen пропущен"
fi
echo ""

# --- XKeen ---
echo "🐾 XKeen"
echo "   Маршрутизация через Xray/Mihomo: выборочное"
echo "   проксирование трафика TCP/UDP для выбранных клиентов."
echo "   Управление через веб-панель."
echo ""
printf "   Установить? (Y/n): "
read ANS_XK
if [ "$ANS_XK" != "n" ] && [ "$ANS_XK" != "N" ]; then
    ENABLED="$ENABLED,xkeen"
    echo "   ✅ XKeen будет установлен"
else
    echo "   ⏭  XKeen пропущен"
fi
echo ""

# --- BIRD ---
echo "🐦 BIRD"
echo "   Демон динамической маршрутизации (BGP/OSPF)."
echo "   Для соединения с другими роутерами, офисами"
echo "   или провайдером по BGP/OSPF."
echo ""
printf "   Установить? (Y/n): "
read ANS_BIRD
if [ "$ANS_BIRD" != "n" ] && [ "$ANS_BIRD" != "N" ]; then
    ENABLED="$ENABLED,bird"
    echo "   ✅ BIRD будет установлен"
else
    echo "   ⏭  BIRD пропущен"
fi
echo ""

# --- MTProxy ---
echo "🌐 MTProxy"
echo "   MTProto-прокси для Telegram. Обход блокировок"
echo "   провайдера, локальный прокси на роутере."
echo "   Ссылка подключения показывается в Telegram."
echo ""
printf "   Установить? (Y/n): "
read ANS_MT
if [ "$ANS_MT" != "n" ] && [ "$ANS_MT" != "N" ]; then
    ENABLED="$ENABLED,mtproxy"
    echo "   ✅ MTProxy будет установлен"
else
    echo "   ⏭  MTProxy пропущен"
fi
echo ""

# --- MTProxy ---
echo "🌐 MTProxy"
echo "   MTProto-прокси для Telegram. Установка и"
echo "   управление, получение ссылки tg:// для клиентов."
echo ""
printf "   Установить? (Y/n): "
read ANS_MT
if [ "$ANS_MT" != "n" ] && [ "$ANS_MT" != "N" ]; then
    ENABLED="$ENABLED,mtproxy"
    echo "   ✅ MTProxy будет установлен"
else
    echo "   ⏭  MTProxy пропущен"
fi
echo ""

# --- Keen-PBR ---
echo "🛤 Keen-PBR"
echo "   Policy-based routing для Keenetic."
echo "   Установка, статус, управление сервисом."
echo ""
printf "   Установить? (Y/n): "
read ANS_KP
if [ "$ANS_KP" != "n" ] && [ "$ANS_KP" != "N" ]; then
    ENABLED="$ENABLED,keen_pbr"
    echo "   ✅ Keen-PBR будет установлен"
else
    echo "   ⏭  Keen-PBR пропущен"
fi
echo ""

# --- NeoFit ---
echo "🔀 NeoFit"
echo "   Веб-панель управления прокси (Xray/Sing-Box)."
echo "   Установка из opkg, управление через Web UI :92."
echo ""
printf "   Установить? (Y/n): "
read ANS_NF
if [ "$ANS_NF" != "n" ] && [ "$ANS_NF" != "N" ]; then
    ENABLED="$ENABLED,neofit"
    echo "   ✅ NeoFit будет установлен"
else
    echo "   ⏭  NeoFit пропущен"
fi
echo ""

# --- Usque WARP ---
echo "🌐 Usque WARP"
echo "   Cloudflare WARP (MASQUE) клиент для Keenetic."
echo "   Работает через /opt/etc/init.d/S51usque."
echo ""
printf "   Установить? (Y/n): "
read ANS_USQUE
if [ "$ANS_USQUE" != "n" ] && [ "$ANS_USQUE" != "N" ]; then
    ENABLED="$ENABLED,usque_keenetic"
    echo "   ✅ Usque WARP будет установлен"
else
    echo "   ⏭  Usque WARP пропущен"
fi
echo ""

# убираем ведущую запятую
fi

ENABLED=$(echo "$ENABLED" | sed 's/^,//')

if [ -z "$ENABLED" ]; then
    echo "❌ Не выбран ни один модуль. Установка отменена."
    exit 1
fi

echo "────────────────────────────────────────────"
echo "✅ Итоговый список модулей: $ENABLED"
echo "────────────────────────────────────────────"
echo ""

# =================== продолжение в следующей части ===================

# ---------- 6. Токен + Chat ID ----------
echo "────────────────────────────────────────────"
echo "  Настройка бота"
echo "────────────────────────────────────────────"
echo ""

while true; do
    printf "Токен бота (от @BotFather): "
    read TOKEN
    TOKEN=$(echo "$TOKEN" | tr -d ' ')
    [ -z "$TOKEN" ] && echo "  Пусто. Попробуйте ещё раз." && continue

    RES=$(TG_TOKEN="$TOKEN" /opt/bin/python3 - << 'PYEOF'
import os, json, urllib.request
tok = os.environ.get('TG_TOKEN', '')
try:
    r = urllib.request.urlopen(f'https://api.telegram.org/bot{tok}/getMe', timeout=10)
    d = json.loads(r.read())
    print('OK:' + d['result'].get('username', '') if d.get('ok') else 'FAIL:bad response')
except Exception as e:
    print('FAIL:' + str(e)[:100])
PYEOF
)
    case "$RES" in
        OK:*) BOT_USERNAME="${RES#OK:}"; echo "  ✅ Токен валиден. Бот: @${BOT_USERNAME}"; break ;;
        *) echo "  ❌ Невалидный токен: $RES" ;;
    esac
done

echo ""
printf "Ваш Chat ID (узнать у @userinfobot): "
read CHAT_ID
CHAT_ID=$(echo "$CHAT_ID" | tr -d ' ')
[ -z "$CHAT_ID" ] && echo "❌ Пустой Chat ID. Выход." && exit 1
echo "  ✅ Chat ID: $CHAT_ID"

# удаляем возможный вебхук
TG_TOKEN="$TOKEN" /opt/bin/python3 - << 'PYEOF' 2>/dev/null || true
import os, urllib.request
tok = os.environ['TG_TOKEN']
urllib.request.urlopen(f'https://api.telegram.org/bot{tok}/deleteWebhook', timeout=10)
PYEOF

echo ""
printf "→ Отправляю тестовое сообщение в чат... "
TEST_RES=$(TG_TOKEN="$TOKEN" TG_CHAT="$CHAT_ID" /opt/bin/python3 - << 'PYEOF'
import os, json, urllib.request, urllib.parse
tok = os.environ['TG_TOKEN']
chat = os.environ['TG_CHAT']
try:
    data = urllib.parse.urlencode({
        'chat_id': chat,
        'text': '✅ Router Bot: тестовое сообщение. Chat ID указан верно.',
    }).encode()
    r = urllib.request.urlopen(
        f'https://api.telegram.org/bot{tok}/sendMessage',
        data=data, timeout=10,
    )
    d = json.loads(r.read())
    print('OK' if d.get('ok') else 'FAIL:' + d.get('description', ''))
except Exception as e:
    print('FAIL:' + str(e)[:100])
PYEOF
)
case "$TEST_RES" in
    OK) echo "✅ доставлено" ;;
    *)
        echo "❌ $TEST_RES"
        echo "  Причины: неверный Chat ID, или вы не нажали /start у бота @${BOT_USERNAME}"
        printf "  Продолжить всё равно? (y/N): "
        read ANS
        [ "$ANS" = "y" ] || [ "$ANS" = "Y" ] || exit 1
        ;;
esac

# ---------- 7. Доп. параметры ----------
echo ""
echo "────────────────────────────────────────────"
echo "  Дополнительно (Enter = по умолчанию)"
echo "────────────────────────────────────────────"

printf "Интервал опроса ndmc, сек [5]: "; read POLL
[ -z "$POLL" ] && POLL=5

printf "Heartbeat, сек (0 = выкл) [3600]: "; read HB
[ -z "$HB" ] && HB=3600

printf "Искать вендора по MAC (on/off) [on]: "; read VENDOR
[ -z "$VENDOR" ] && VENDOR=on

# ---------- 8. Запись config.env ----------
mkdir -p "$BASE_DIR" "$LOG_DIR" "$INIT_DIR" "$BASE_DIR/data" "$BASE_DIR/data/net_watch" "$BASE_DIR/data/ssh_control" "$BASE_DIR/data/xkeen" "$BASE_DIR/data/bird" "$BASE_DIR/data/hydraroute" "$BASE_DIR/data/mtproxy" "$BASE_DIR/data/keen_pbr" "$BASE_DIR/data/neofit" "$BASE_DIR/data/usque_keenetic" "$BASE_DIR/data/mtproxy"

cat > "$BASE_DIR/config.env" << EOF
# Router Bot — конфиг
# Сгенерирован $(date '+%Y-%m-%d %H:%M:%S')

TG_BOT_TOKEN='$TOKEN'
TG_CHAT_ID='$CHAT_ID'

# Модули (через запятую)
ENABLED_MODULES='$ENABLED'

# Net Watch
POLL_INTERVAL=$POLL
HEARTBEAT_INTERVAL=$HB
VENDOR_LOOKUP=$VENDOR
NDMC_PATH=/bin/ndmc

# Сеть
WAN_IF='$WAN_IF'
WAN_SRC='$WAN_SRC'
ROUTE_TABLE='$WAN_TABLE'

# VPN для Telegram
USE_VPN='$USE_VPN'
VPN_IF='$VPN_IF'
VPN_SRC='$VPN_SRC'
EOF
chmod 600 "$BASE_DIR/config.env"
echo "✅ config.env"

# =================== продолжение в следующей части ===================

# ---------- 9. init: S97tgroutes ----------
if [ "$USE_VPN" = "yes" ]; then
    cat > "$INIT_DIR/S97tgroutes" << 'EOF97'
#!/bin/sh
# Маршруты Telegram через VPN-туннель.
# WAN_IF и WAN_SRC определяются автоматически.
. /opt/router_bot/config.env

[ "$USE_VPN" = "yes" ] || exit 0
[ -n "$VPN_IF" ] || exit 0
[ -n "$VPN_SRC" ] || exit 0
[ -n "$ROUTE_TABLE" ] || ROUTE_TABLE="16385"
WAN_IF_CFG="${WAN_IF:-}"

TG_NETS="149.154.160.0/20 91.108.4.0/22"

# Определяет активный WAN-интерфейс: сначала из config.env,
# потом из default route (исключая VPN-туннели).
get_wan_if() {
    # 1. Из config.env — если интерфейс есть и имеет IPv4
    if [ -n "$WAN_IF_CFG" ] && \
       ip link show "$WAN_IF_CFG" >/dev/null 2>&1 && \
       ip -4 -o addr show dev "$WAN_IF_CFG" 2>/dev/null | grep -q ' inet '; then
        echo "$WAN_IF_CFG"
        return 0
    fi
    # 2. Из default route — первый, не туннель
    local ifc
    ifc=$(ip route show default 2>/dev/null \
        | awk '/^default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    if [ -n "$ifc" ] && [ "$ifc" != "$VPN_IF" ] \
       && ! echo "$ifc" | grep -qE '^(opkgtun|nwg|wg|tun)'; then
        echo "$ifc"
        return 0
    fi
    # 3. Через route get — обходит default
    ifc=$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    if [ -n "$ifc" ] && [ "$ifc" != "$VPN_IF" ] \
       && ! echo "$ifc" | grep -qE '^(opkgtun|nwg|wg|tun)'; then
        echo "$ifc"
        return 0
    fi
    return 1
}

get_wan_src() {
    local iface="$1"
    [ -n "$iface" ] || return 1
    ip -4 -o addr show dev "$iface" 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 | head -1
}

rebuild_rules() {
    local WAN_IF_NOW WAN_SRC_NOW

    WAN_IF_NOW=$(get_wan_if) || return 1
    WAN_SRC_NOW=$(get_wan_src "$WAN_IF_NOW")
    [ -n "$WAN_SRC_NOW" ] || return 1

    # обновляем config.env если WAN_IF/ WAN_SRC изменились
    if [ "$WAN_IF_NOW" != "$WAN_IF_CFG" ] || [ "$WAN_SRC_NOW" != "$WAN_SRC" ]; then
        sed -i "s|^WAN_IF=.*|WAN_IF='$WAN_IF_NOW'|" /opt/router_bot/config.env 2>/dev/null || true
        sed -i "s|^WAN_SRC=.*|WAN_SRC='$WAN_SRC_NOW'|" /opt/router_bot/config.env 2>/dev/null || true
        echo "WAN detected: $WAN_IF_NOW ($WAN_SRC_NOW)"
    fi

    # чистка старых правил
    for src in $(ip rule show | awk '/lookup 16385/ {for(i=1;i<=NF;i++) if($i=="from") print $(i+1)}'); do
        case "$src" in
            [0-9]*) ip rule del from "$src" lookup "$ROUTE_TABLE" 2>/dev/null || true ;;
        esac
    done
    for net in $TG_NETS; do
        ip rule del to "$net" lookup "$ROUTE_TABLE" 2>/dev/null || true
        ip route del "$net" table "$ROUTE_TABLE" 2>/dev/null || true
    done

    # source-based
    ip rule add from "$WAN_SRC_NOW" lookup "$ROUTE_TABLE" priority 1152 2>/dev/null || true

    # to-based (независимо от source)
    p=1100
    for net in $TG_NETS; do
        ip rule add to "$net" lookup "$ROUTE_TABLE" priority $p 2>/dev/null || true
        p=$((p+1))
    done

    # маршруты
    for net in $TG_NETS; do
        ip route add "$net" dev "$VPN_IF" src "$VPN_SRC" table "$ROUTE_TABLE" 2>/dev/null || true
    done
}

case "$1" in
  start)   sleep 20; rebuild_rules || exit 0 ;;
  stop)
    for net in $TG_NETS; do
        ip rule del to "$net" lookup "$ROUTE_TABLE" 2>/dev/null || true
        ip route del "$net" table "$ROUTE_TABLE" 2>/dev/null || true
    done
    for src in $(ip rule show | awk '/lookup 16385/ {for(i=1;i<=NF;i++) if($i=="from") print $(i+1)}'); do
        case "$src" in
            [0-9]*) ip rule del from "$src" lookup "$ROUTE_TABLE" 2>/dev/null || true ;;
        esac
    done
    ;;
  rebuild) rebuild_rules ;;
  *) echo "Usage: $0 {start|stop|rebuild}"; exit 1 ;;
esac
EOF97
    chmod +x "$INIT_DIR/S97tgroutes"
    echo "✅ S97tgroutes"
fi

# ---------- 10. wrapper в /opt/bin ----------
echo "→ Устанавливаю routerbot_wrapper.sh..."
if [ -f "$BASE_DIR/core/wrapper.sh" ]; then
    cp -f "$BASE_DIR/core/wrapper.sh" /opt/bin/routerbot_wrapper.sh
    chmod +x /opt/bin/routerbot_wrapper.sh
    echo "✅ /opt/bin/routerbot_wrapper.sh"
else
    echo "⚠️  wrapper.sh не найден в $BASE_DIR/core/ — использую python напрямую"
fi
echo ""

# ---------- 10b. init: S98routerbot ----------
cat > "$INIT_DIR/S98routerbot" << 'EOF98'
#!/bin/sh
PROG=/opt/bin/routerbot_wrapper.sh
ARGS=""
PIDFILE=/var/run/routerbot.pid

kill_all_routerbot() {
    PIDS=$(ps w | grep -E "routerbot_wrapper|router_bot/main.py" | grep -v grep | awk '{print $1}')
    for p in $PIDS; do
        kill "$p" 2>/dev/null
    done
    sleep 1
    PIDS=$(ps w | grep "router_bot/main.py" | grep -v grep | awk '{print $1}')
    for p in $PIDS; do
        kill -9 "$p" 2>/dev/null
    done
    # Зачищаем осиротевшие Flashkeen (pty-сессии)
    PIDS=$(ps w | grep "/opt/bin/sh /opt/bin/flashkeen" | grep -v grep | awk '{print $1}')
    for p in $PIDS; do
        kill -9 "$p" 2>/dev/null
    done
    # И другие flashkeen-процессы, если остались
    PIDS=$(ps w | grep "flashkeen" | grep -v grep | grep -v "S98routerbot" | awk '{print $1}')
    for p in $PIDS; do
        kill -9 "$p" 2>/dev/null
    done
}

# S98 auto-copy wrapper: если исходник в /opt/router_bot/core/wrapper.sh
# новее рабочей копии в /opt/bin/routerbot_wrapper.sh — обновить.
if [ -f /opt/router_bot/core/wrapper.sh ] && [ -x /opt/bin/routerbot_wrapper.sh ]; then
    if [ /opt/router_bot/core/wrapper.sh -nt /opt/bin/routerbot_wrapper.sh ]; then
        cp -f /opt/router_bot/core/wrapper.sh /opt/bin/routerbot_wrapper.sh
        chmod +x /opt/bin/routerbot_wrapper.sh
        echo "wrapper.sh updated from /opt/router_bot/core/"
    fi
fi

case "$1" in
  start)
    if [ -f /var/run/routerbot.giveup ]; then
      echo "Router Bot is in GIVEUP state (too many failures)."
      echo "  Reset: rm /var/run/routerbot.giveup && $0 restart"
      exit 1
    fi
    if [ -f "$PIDFILE" ] && kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
      echo "Already running (PID $(cat $PIDFILE))"; exit 0
    fi
    kill_all_routerbot
    sleep 1
    echo "Starting Router Bot..."
    start-stop-daemon -S -b -m -p "$PIDFILE" -x "$PROG" -- $ARGS
    ;;
  stop)
    echo "Stopping Router Bot..."
    start-stop-daemon -K -p "$PIDFILE" 2>/dev/null
    kill_all_routerbot
    rm -f "$PIDFILE"
    ;;
  restart) $0 stop; sleep 3; $0 start ;;
  reset)
    rm -f /var/run/routerbot.giveup
    echo "Giveup marker removed. Now run: $0 start"
    ;;
  *) echo "Usage: $0 {start|stop|restart|reset}"; exit 1 ;;
esac
EOF98
chmod +x "$INIT_DIR/S98routerbot"
echo "✅ S98routerbot"

# ---------- 11. init: S99routerbot_health ----------
cat > "$INIT_DIR/S99routerbot_health" << 'EOF99'
#!/bin/sh
. /opt/router_bot/config.env

# Если wrapper сдался (много падений подряд) — не пинать
[ -f /var/run/routerbot.giveup ] && exit 0

PIDFILE=/var/run/routerbot.pid
STATE=/var/run/routerbot.fail

# 0. Автодетект WAN IP
if [ "$USE_VPN" = "yes" ] && [ -n "$VPN_IF" ]; then
    # автодетект WAN-интерфейса
    WAN_IF_NOW=""
    if [ -n "$WAN_IF" ] && ip -4 -o addr show dev "$WAN_IF" 2>/dev/null | grep -q ' inet '; then
        WAN_IF_NOW="$WAN_IF"
    else
        WAN_IF_NOW=$(ip route show default 2>/dev/null \
            | awk '/^default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
        [ -n "$WAN_IF_NOW" ] && [ "$WAN_IF_NOW" = "$VPN_IF" ] && WAN_IF_NOW=""
        echo "$WAN_IF_NOW" | grep -qE '^(opkgtun|nwg|wg|tun)' && WAN_IF_NOW=""
    fi
    WAN_SRC_NOW=""
    [ -n "$WAN_IF_NOW" ] && WAN_SRC_NOW=$(ip -4 -o addr show dev "$WAN_IF_NOW" 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 | head -1)
    if [ -n "$WAN_SRC_NOW" ] && [ "$WAN_SRC_NOW" != "$WAN_SRC" ]; then
        echo "WAN IP changed: $WAN_SRC -> $WAN_SRC_NOW"
        sed -i "s|^WAN_SRC=.*|WAN_SRC='$WAN_SRC_NOW'|" /opt/router_bot/config.env 2>/dev/null || true
        sed -i "s|^WAN_IF=.*|WAN_IF='$WAN_IF_NOW'|" /opt/router_bot/config.env 2>/dev/null || true
        WAN_SRC="$WAN_SRC_NOW"
        /opt/etc/init.d/S97tgroutes rebuild >/dev/null 2>&1 || true
    fi
fi

# 1. Маршруты Telegram
if [ "$USE_VPN" = "yes" ] && [ -n "$VPN_IF" ] && [ -n "$WAN_SRC" ]; then
    if ! ip route get 149.154.166.110 from "$WAN_SRC" 2>/dev/null | grep -q "$VPN_IF"; then
        echo "Restoring Telegram routes via $VPN_IF..."
        /opt/etc/init.d/S97tgroutes rebuild >/dev/null 2>&1 || true
    fi
fi

# 2. resolv.conf
if ! grep -q nameserver /etc/resolv.conf 2>/dev/null; then
    printf 'nameserver 127.0.0.1\nnameserver 8.8.8.8\noptions timeout:1 attempts:1 rotate\n' > /etc/resolv.conf
fi

# 3. Проверка связи с Telegram
TG=$(sed -n "s/^TG_BOT_TOKEN='\(.*\)'/\1/p" /opt/router_bot/config.env)
if /opt/bin/curl -sf --max-time 10 "https://api.telegram.org/bot${TG}/getMe" >/dev/null 2>&1; then
    rm -f "$STATE"
else
    COUNT=$(cat "$STATE" 2>/dev/null || echo 0)
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$STATE"
    echo "Telegram unreachable (failure $COUNT)"
    if [ "$COUNT" -ge 3 ]; then
        rm -f "$STATE"
        /opt/etc/init.d/S98routerbot restart
    fi
    exit 0
fi

# 4. Процесс мёртв — перезапустить
if [ -f "$PIDFILE" ] && kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
    exit 0
fi

echo "Bot process is dead, restarting..."
/opt/etc/init.d/S98routerbot restart
EOF99
chmod +x "$INIT_DIR/S99routerbot_health"
echo "✅ S99routerbot_health"

# ---------- 12. logrotate ----------
mkdir -p /opt/etc/logrotate.d
cat > /opt/etc/logrotate.d/router_bot << EOF
$LOG_DIR/router_bot.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
echo "✅ logrotate"

# ---------- 13. cron ----------
CRON_FILE="/opt/etc/crontab"
if [ -f "$CRON_FILE" ]; then
    grep -v "S99routerbot_health" "$CRON_FILE" > "$CRON_FILE.tmp" 2>/dev/null || true
    mv "$CRON_FILE.tmp" "$CRON_FILE" 2>/dev/null || true
    echo "*/1 * * * * /opt/etc/init.d/S99routerbot_health" >> "$CRON_FILE"
    echo "✅ cron: healthcheck раз в минуту"
fi

# ---------- 15. Запуск ----------
echo ""
echo "→ Запускаю Router Bot..."

if [ "$USE_VPN" = "yes" ]; then
    /opt/etc/init.d/S97tgroutes start >/dev/null 2>&1 || true
fi

/opt/etc/init.d/S98routerbot start
sleep 5

# ---------- 16. Итог ----------
echo ""
echo "════════════════════════════════════════════"
echo "  ✅ Установка завершена"
echo "════════════════════════════════════════════"
echo ""
echo "  Модули:     $ENABLED"
echo "  WAN:        $WAN_IF ($WAN_SRC)"
if [ "$USE_VPN" = "yes" ]; then
    echo "  VPN:        $VPN_IF ($VPN_SRC) → table $WAN_TABLE"
else
    echo "  VPN:        не используется"
fi
echo ""
echo "  Проверьте Telegram — бот должен прислать приветствие."
echo "  Если нет — напишите боту /start."
echo ""
echo "  Управление:  /opt/etc/init.d/S98routerbot {start|stop|restart}"
echo "  Логи:        tail -f $LOG_DIR/router_bot.log"
echo "  Удаление:    $BASE_DIR/uninstall.sh"
echo ""