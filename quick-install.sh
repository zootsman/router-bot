#!/bin/sh
# Router Bot — быстрый установщик.
# Использование:
#   curl -fsSL https://raw.githubusercontent.com/zootsman/router-bot/master/quick-install.sh | sh
#   или
#   wget -qO- https://raw.githubusercontent.com/zootsman/router-bot/master/quick-install.sh | sh
set -e

REPO="zootsman/router-bot"
BRANCH="master"
URLS="
https://raw.githubusercontent.com/${REPO}/${BRANCH}/router_bot_setup.sh
https://cdn.jsdelivr.net/gh/${REPO}@${BRANCH}/router_bot_setup.sh
"
TMP="/tmp/router_bot_setup.sh"

echo ""
echo "════════════════════════════════════════════"
echo "  Router Bot — загрузка установщика"
echo "════════════════════════════════════════════"
echo ""

# Определяем загрузчик
_download() {
    _url="$1"
    _out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 30 "$_url" -o "$_out"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=30 "$_url" -O "$_out"
    else
        echo "❌ Нужен curl или wget" >&2
        return 1
    fi
}

# Пробуем по очереди
_ok=no
for u in $URLS; do
    echo "→ Пробую: $u"
    if _download "$u" "$TMP"; then
        if [ -s "$TMP" ] && head -1 "$TMP" | grep -q '^#!/bin/sh'; then
            echo "  ✅ Скачано ($(wc -c < "$TMP") байт)"
            _ok=yes
            break
        else
            echo "  ⚠️  Файл скачан, но выглядит повреждённым"
        fi
    else
        echo "  ⚠️  Не удалось"
    fi
done

if [ "$_ok" != "yes" ]; then
    echo ""
    echo "❌ Не удалось скачать установщик ни с одного зеркала."
    echo "   Скачайте вручную и запустите:"
    echo "   wget https://raw.githubusercontent.com/${REPO}/${BRANCH}/router_bot_setup.sh"
    echo "   sh router_bot_setup.sh"
    exit 1
fi

chmod +x "$TMP"
echo ""
echo "→ Запускаю установщик..."
echo ""
exec sh "$TMP" "$@"
