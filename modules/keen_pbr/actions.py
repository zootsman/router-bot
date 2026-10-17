"""Действия модуля keen-pbr."""
import os
import subprocess

# --- Установка / удаление ---
INSTALL_CMD = (
    'opkg update && '
    'opkg install curl jq && '
    'cd /tmp && '
    'curl -sOfL https://raw.githubusercontent.com/maksimkurb/keenetic-pbr/'
    'refs/heads/main/install.sh && '
    'sh install.sh'
)

UNINSTALL_CMD = (
    'opkg remove --force-removal-of-dependent-packages '
    '--autoremove keen-pbr 2>&1 || true'
)

# --- Управление сервисом ---
SERVICE_START = '/opt/etc/init.d/S99keen-pbr start'
SERVICE_STOP = '/opt/etc/init.d/S99keen-pbr stop'
SERVICE_RESTART = '/opt/etc/init.d/S99keen-pbr restart'
SERVICE_STATUS = '/opt/etc/init.d/S99keen-pbr status'

# --- Конфиг ---
CMD_CONFIG_PATH = 'ls -la /opt/etc/keen-pbr/ 2>/dev/null || ls -la /opt/keen-pbr/ 2>/dev/null'
CMD_TEST_CONFIG = 'keen-pbr --test 2>&1 || /opt/sbin/keen-pbr --test 2>&1'
CMD_RELOAD = 'keen-pbr reload 2>&1 || /opt/etc/init.d/S99keen-pbr restart'

# --- Диагностика ---
CMD_VERSION = 'keen-pbr --version 2>&1 || /opt/sbin/keen-pbr --version 2>&1'
CMD_INFO = 'keen-pbr info 2>&1 || keen-pbr status 2>&1'
CMD_CHECK_ROUTE = 'keen-pbr route check'

# Пути
PBR_BIN = '/opt/sbin/keen-pbr'
PBR_BIN_ALT = '/opt/bin/keen-pbr'
PBR_INIT = '/opt/etc/init.d/S99keen-pbr'
PBR_CONF_DIR = '/opt/etc/keen-pbr'
PBR_CONF = '/opt/etc/keen-pbr/config.yaml'
PBR_LOG = '/opt/var/log/keen-pbr.log'
PBR_WEB = 'http://127.0.0.1:8080'


def find_bin() -> str:
    for p in (PBR_BIN, PBR_BIN_ALT):
        if os.path.exists(p):
            return p
    try:
        r = subprocess.run(
            ['sh', '-c', 'command -v keen-pbr 2>/dev/null'],
            capture_output=True, text=True, timeout=3,
        )
        return (r.stdout or '').strip()
    except Exception:
        return ''


def is_installed() -> bool:
    try:
        r = subprocess.run(
            ['sh', '-c', 'opkg list-installed 2>/dev/null | grep -q "^keen-pbr "'],
            timeout=5,
        )
        if r.returncode == 0:
            return True
    except Exception:
        pass
    return os.path.exists(PBR_INIT) or bool(find_bin())


def is_running() -> bool:
    try:
        r = subprocess.run(
            ['sh', '-c', 'ps w | grep -E "[k]een-pbr" | grep -v grep | wc -l'],
            capture_output=True, text=True, timeout=5,
        )
        return int((r.stdout or '0').strip()) > 0
    except Exception:
        return False


def get_version() -> str:
    try:
        r = subprocess.run(
            ['sh', '-c', 'opkg list-installed 2>/dev/null | grep "^keen-pbr "'],
            capture_output=True, text=True, timeout=5,
        )
        for line in (r.stdout or '').splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[0] == 'keen-pbr':
                return parts[2]
    except Exception:
        pass
    try:
        r = subprocess.run(
            ['sh', '-c', CMD_VERSION],
            capture_output=True, text=True, timeout=5,
        )
        out = (r.stdout or '').strip()
        return out[:40] if out else ''
    except Exception:
        return ''


def get_config_path() -> str:
    """Возвращает реальный путь к конфигу."""
    for p in (PBR_CONF, '/opt/etc/keen-pbr/config.yml', '/opt/keen-pbr/config.yaml'):
        if os.path.exists(p):
            return p
    # поиск
    try:
        r = subprocess.run(
            ['sh', '-c', 'find /opt/etc -maxdepth 3 -name "*.yaml" -o -name "*.yml" 2>/dev/null | grep -i pbr | head -1'],
            capture_output=True, text=True, timeout=5,
        )
        p = (r.stdout or '').strip()
        if p:
            return p
    except Exception:
        pass
    return PBR_CONF


def get_status_short() -> str:
    if not is_installed():
        return '❌'
    if is_running():
        return '🟢'
    return '🔴'


# --- Действия для UI ---
ACTIONS = {
    'install': {
        'title': 'Установка keen-pbr',
        'icon': '\u2b07\ufe0f',
        'desc': (
            'Установит keen-pbr — policy-based routing для Keenetic.\n\n'
            'Скачивается официальный установщик с GitHub.\n'
            'Использует nftables и sing-box/xray ядра.\n\n'
            '⚠️ <b>Не совместим с XKeen и HydraRoute</b> — они '
            'занимают маршрутизацию эксклюзивно.'
        ),
        'cmd': INSTALL_CMD,
    },
    'uninstall': {
        'title': 'Удаление keen-pbr',
        'icon': '\U0001f5d1',
        'desc': (
            'Будет удалён пакет <code>keen-pbr</code>.\n\n'
            '⚠️ Конфиги в <code>/opt/etc/keen-pbr/</code> останутся.'
        ),
        'cmd': UNINSTALL_CMD,
        'danger': True,
    },
    'start': {
        'title': 'Запуск keen-pbr',
        'icon': '\u25b6\ufe0f',
        'desc': 'Команда: <code>S99keen-pbr start</code>',
        'cmd': SERVICE_START,
    },
    'stop': {
        'title': 'Остановка keen-pbr',
        'icon': '\u23f9',
        'desc': 'Команда: <code>S99keen-pbr stop</code>',
        'cmd': SERVICE_STOP,
    },
    'restart': {
        'title': 'Перезапуск keen-pbr',
        'icon': '\U0001f504',
        'desc': 'Команда: <code>S99keen-pbr restart</code>',
        'cmd': SERVICE_RESTART,
    },
    'status': {
        'title': 'Статус keen-pbr',
        'icon': '\U0001f4ca',
        'desc': 'Команда: <code>S99keen-pbr status</code>',
        'cmd': SERVICE_STATUS,
    },
    'version': {
        'title': 'Версия keen-pbr',
        'icon': '\U0001f4c4',
        'desc': 'Команда: <code>keen-pbr --version</code>',
        'cmd': CMD_VERSION,
    },
    'info': {
        'title': 'Информация о keen-pbr',
        'icon': '\u2139\ufe0f',
        'desc': 'Команда: <code>keen-pbr info</code> — общее состояние',
        'cmd': CMD_INFO,
    },
    'test_config': {
        'title': 'Проверить конфиг',
        'icon': '\u2705',
        'desc': 'Валидация YAML без применения',
        'cmd': CMD_TEST_CONFIG,
    },
    'reload': {
        'title': 'Перечитать конфиг',
        'icon': '\U0001f4c4',
        'desc': 'Перечитать YAML без перезапуска демона',
        'cmd': CMD_RELOAD,
    },
}

# ================= Описание целей удаления =================

UNINSTALL_TARGETS = [
    {
        'key': 'bin',
        'desc': 'Бинарник /opt/sbin/keen-pbr',
        'paths': ['/opt/sbin/keen-pbr', '/opt/bin/keen-pbr'],
        'cmd': 'rm -f /opt/sbin/keen-pbr /opt/bin/keen-pbr',
    },
    {
        'key': 'init',
        'desc': 'Init-скрипт S99keen-pbr',
        'paths': ['/opt/etc/init.d/S99keen-pbr'],
        'cmd': 'rm -f /opt/etc/init.d/S99keen-pbr',
    },
    {
        'key': 'configs',
        'desc': 'Конфиги /opt/etc/keen-pbr',
        'paths': ['/opt/etc/keen-pbr'],
        'cmd': 'rm -rf /opt/etc/keen-pbr',
    },
    {
        'key': 'logs',
        'desc': 'Логи и runtime',
        'paths': ['/opt/var/log/keen-pbr*', '/opt/var/run/keen-pbr*'],
        'cmd': 'rm -rf /opt/var/log/keen-pbr* /opt/var/run/keen-pbr*',
    },
]

# ================= Маски для поиска остатков ==================

SCAN_PATTERNS = [
    '*keen-pbr*', '*keen_pbr*',
]