"""Действия модуля NeoFit."""
import os
import subprocess

# --- Установка / удаление ---
INSTALL_CMD = (
    'opkg update && '
    'opkg install curl && '
    'curl -Ls "http://www.pegakmop.site/release/keenetic/opkg.sh" | sh && '
    'opkg install neofit'
)

UNINSTALL_CMD = (
    'opkg remove --force-removal-of-dependent-packages '
    '--autoremove neofit 2>&1 || true'
)

# --- Управление сервисом (nf {start|stop|restart|status}) ---
SERVICE_START   = 'nf start   2>&1'
SERVICE_STOP    = 'nf stop    2>&1'
SERVICE_RESTART = 'nf restart 2>&1'
SERVICE_STATUS  = 'nf status  2>&1'

# --- Диагностика ---
CMD_VERSION = 'neofit --version 2>&1 || nf --version 2>&1'
CMD_INFO    = 'nf status 2>&1'
CMD_LOGS    = 'tail -n 60 /opt/var/log/neofit.log 2>&1 || echo "лог не найден"'

# Пути
NEOFIT_BIN     = '/opt/sbin/neofit'
NEOFIT_BIN_ALT = '/opt/bin/neofit'
NEOFIT_INIT    = '/opt/etc/init.d/S99neofit'
NEOFIT_CONF_DIR = '/opt/etc/neofit'
NEOFIT_LOG     = '/opt/var/log/neofit.log'
NEOFIT_WEB_PORT = 92
NEOFIT_WEB_URL  = f'http://192.168.1.1:{NEOFIT_WEB_PORT}'


def find_bin() -> str:
    for p in (NEOFIT_BIN, NEOFIT_BIN_ALT):
        if os.path.exists(p):
            return p
    try:
        r = subprocess.run(
            ['sh', '-c', 'command -v neofit 2>/dev/null'],
            capture_output=True, text=True, timeout=3,
        )
        return (r.stdout or '').strip()
    except Exception:
        return ''


def is_installed() -> bool:
    try:
        r = subprocess.run(
            ['sh', '-c', 'opkg list-installed 2>/dev/null | grep -q "^neofit "'],
            timeout=5,
        )
        if r.returncode == 0:
            return True
    except Exception:
        pass
    return os.path.exists(NEOFIT_INIT) or bool(find_bin())


def is_running() -> bool:
    try:
        r = subprocess.run(
            ['sh', '-c', 'ps w | grep -E "[n]eofit" | grep -v grep | wc -l'],
            capture_output=True, text=True, timeout=5,
        )
        return int((r.stdout or '0').strip()) > 0
    except Exception:
        return False


def get_version() -> str:
    try:
        r = subprocess.run(
            ['sh', '-c', 'opkg list-installed 2>/dev/null | grep "^neofit "'],
            capture_output=True, text=True, timeout=5,
        )
        for line in (r.stdout or '').splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[0] == 'neofit':
                return parts[2]
    except Exception:
        pass
    try:
        r = subprocess.run(['sh', '-c', CMD_VERSION],
                           capture_output=True, text=True, timeout=5)
        out = (r.stdout or '').strip()
        return out[:40] if out else ''
    except Exception:
        return ''


def get_status_short() -> str:
    if not is_installed():
        return '❌'
    if is_running():
        return '🟢'
    return '🔴'


# --- Действия для UI ---
ACTIONS = {
    'install': {
        'title': 'Установка NeoFit',
        'icon': '\u2b07\ufe0f',
        'desc': (
            'Установит NeoFit — веб-панель управления прокси-службами '
            '(Xray/Sing-Box) на Keenetic.\n\n'
            'После установки веб-интерфейс: '
            '<code>http://&lt;router-ip&gt;:92</code>\n\n'
            '⚠️ <b>Не совместим с XKeen и HydraRoute</b> — '
            'они используют те же ядра/маршрутизацию.'
        ),
        'cmd': INSTALL_CMD,
    },
    'uninstall': {
        'title': 'Удаление NeoFit',
        'icon': '\U0001f5d1',
        'desc': (
            'Будет удалён пакет <code>neofit</code>.\n\n'
            '⚠️ Конфиги в <code>/opt/etc/neofit/</code> останутся, '
            'их можно удалить через скан остатков.'
        ),
        'cmd': UNINSTALL_CMD,
        'danger': True,
    },
    'start': {
        'title': 'Запуск NeoFit',
        'icon': '\u25b6\ufe0f',
        'desc': 'Команда: <code>nf start</code>',
        'cmd': SERVICE_START,
    },
    'stop': {
        'title': 'Остановка NeoFit',
        'icon': '\u23f9',
        'desc': 'Команда: <code>nf stop</code>',
        'cmd': SERVICE_STOP,
    },
    'restart': {
        'title': 'Перезапуск NeoFit',
        'icon': '\U0001f504',
        'desc': 'Команда: <code>nf restart</code>',
        'cmd': SERVICE_RESTART,
    },
    'status': {
        'title': 'Статус NeoFit',
        'icon': '\U0001f4ca',
        'desc': 'Команда: <code>nf status</code>',
        'cmd': SERVICE_STATUS,
    },
    'version': {
        'title': 'Версия NeoFit',
        'icon': '\U0001f4c4',
        'desc': 'Команда: <code>neofit --version</code>',
        'cmd': CMD_VERSION,
    },
    'info': {
        'title': 'Информация',
        'icon': '\u2139\ufe0f',
        'desc': 'Общее состояние NeoFit',
        'cmd': CMD_INFO,
    },
    'logs': {
        'title': 'Логи NeoFit',
        'icon': '\U0001f4dc',
        'desc': 'Последние 60 строк лога',
        'cmd': CMD_LOGS,
    },
}

# ================= Описание целей удаления =================

UNINSTALL_TARGETS = [
    {
        'key': 'bin',
        'desc': 'Бинарник /opt/sbin/neofit',
        'paths': ['/opt/sbin/neofit', '/opt/bin/neofit'],
        'cmd': 'rm -f /opt/sbin/neofit /opt/bin/neofit',
    },
    {
        'key': 'init',
        'desc': 'Init-скрипт S99neofit',
        'paths': ['/opt/etc/init.d/S99neofit'],
        'cmd': 'rm -f /opt/etc/init.d/S99neofit',
    },
    {
        'key': 'configs',
        'desc': 'Конфиги /opt/etc/neofit',
        'paths': ['/opt/etc/neofit'],
        'cmd': 'rm -rf /opt/etc/neofit',
    },
    {
        'key': 'logs',
        'desc': 'Логи и runtime',
        'paths': ['/opt/var/log/neofit*', '/opt/var/run/neofit*'],
        'cmd': 'rm -rf /opt/var/log/neofit* /opt/var/run/neofit*',
    },
    {
        'key': 'opkg',
        'desc': 'Метаданные opkg (neofit, pegakmop)',
        'paths': ['/opt/lib/opkg/info/neofit*', '/opt/var/opkg-lists/pegakmop*'],
        'cmd': 'rm -rf /opt/lib/opkg/info/neofit* /opt/var/opkg-lists/pegakmop*',
    },
]

# ================= Маски для поиска остатков ==================

SCAN_PATTERNS = [
    '*neofit*', '*NeoFit*',
]