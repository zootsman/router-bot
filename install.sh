#!/bin/sh
set -e

REPO_RAW_URL="https://raw.githubusercontent.com/zootsman/router-bot/master"

echo "============================================"
echo "  Router Bot - Установка с GitHub"
echo "============================================"

INSTALL_DIR="/opt/router_bot"
mkdir -p "$INSTALL_DIR"

echo "Скачивание файлов бота..."
if command -v curl >/dev/null 2>&1; then
    curl -sSL "$REPO_RAW_URL/router_bot_setup.sh" -o "$INSTALL_DIR/router_bot_setup.sh"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$INSTALL_DIR/router_bot_setup.sh" "$REPO_RAW_URL/router_bot_setup.sh"
else
    echo "Ошибка: не найдены curl или wget." >&2
    exit 1
fi

sh "$INSTALL_DIR/router_bot_setup.sh"
