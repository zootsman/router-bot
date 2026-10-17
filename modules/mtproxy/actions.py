"""Действия модуля MTProxy."""
import os
import subprocess

# --- Установка / удаление ---
INSTALL_CMD = (
    'curl -fsSL https://raw.githubusercontent.com/spatiumstas/feedly/main/add-repo.sh | sh && '
    'opkg update && opkg install tg-ws-proxy'
)
UNINSTALL_CMD = (
    'opkg remove --force-removal-of-dependent-packages --autoremove tg-ws-proxy 2>&1 || true'
)

# --- Управление сервисом ---
# setsid отвязывает от pty — иначе при закрытии pty дочерний демон
# получает SIGHUP и умирает сразу после старта.
_S99 = '/opt/etc/init.d/S99tg-ws-proxy'
SERVICE_START = f'/opt/sbin/start-stop-daemon -S -b -x {_S99} -- start; sleep 2; {_S99} status'
SERVICE_STOP = f'{_S99} stop'
SERVICE_RESTART = f'{_S99} stop; sleep 1; /opt/sbin/start-stop-daemon -S -b -x {_S99} -- start; sleep 2; {_S99} status'
SERVICE_STATUS = f'{_S99} status'

# --- Ссылка подключения ---
GET_LINK = 'grep -o "tg://proxy[^ \\"]*" /opt/var/log/tg-ws-proxy.log | tail -1'

# Пути
PROXY_BIN = '/opt/bin/tg-ws-proxy'
PROXY_INIT = '/opt/etc/init.d/S99tg-ws-proxy'
PROXY_CONF_DIR = '/opt/etc/tg-ws-proxy'
PROXY_CONF = '/opt/etc/tg-ws-proxy/config.conf'
PROXY_SECRET = '/opt/etc/tg-ws-proxy/secret.conf'
PROXY_LOG = '/opt/var/log/tg-ws-proxy.log'


def is_installed() -> bool:
    try:
        r = subprocess.run(
            ['sh', '-c', 'opkg list-installed 2>/dev/null | grep -q "^tg-ws-proxy "'],
            timeout=5,
        )
        if r.returncode == 0:
            return True
    except Exception:
        pass
    return os.path.exists(PROXY_INIT)


def is_running() -> bool:
    try:
        r = subprocess.run(
            ['sh', '-c', 'ps w | grep -E "[t]g-ws-proxy" | grep -v grep | wc -l'],
            capture_output=True, text=True, timeout=5,
        )
        return int((r.stdout or '0').strip()) > 0
    except Exception:
        return False


def get_version() -> str:
    try:
        r = subprocess.run(
            ['sh', '-c',
             'opkg list-installed 2>/dev/null | grep "^tg-ws-proxy "'],
            capture_output=True, text=True, timeout=5,
        )
        for line in (r.stdout or '').splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[0] == 'tg-ws-proxy':
                return parts[2]
    except Exception:
        pass
    return ''


def get_status_short() -> str:
    if not is_installed():
        return '❌'
    if is_running():
        return '🟢'
    return '🔴'


def get_link() -> str:
    """Читает tg:// ссылку из лога."""
    try:
        r = subprocess.run(
            ['sh', '-c', GET_LINK],
            capture_output=True, text=True, timeout=5,
        )
        return (r.stdout or '').strip()
    except Exception:
        return ''


def get_secret() -> str:
    """Читает SECRET из secret.conf."""
    if not os.path.exists(PROXY_SECRET):
        return ''
    try:
        with open(PROXY_SECRET) as f:
            for line in f:
                if line.startswith('SECRET='):
                    return line.split('=', 1)[1].strip()
    except Exception:
        pass
    return ''


def build_tg_link(host: str = '', port: str = '', secret: str = '') -> str:
    """Собирает tg:// ссылку, если её нет в логе."""
    if not secret:
        return ''
    cfg = get_config()
    if not host:
        host = cfg.get('HOST', '')
    if not port:
        port = cfg.get('PORT', '')
    if not host or not port or host in ('0.0.0.0', '127.0.0.1'):
        return ''
    # Для MTProto ссылки нужен внешний IP/домен. HOST из конфига обычно 0.0.0.0
    # — тогда ссылку собрать нельзя, вернём пусто.
    return f'tg://proxy?server={host}&port={port}&secret={secret}'


def get_external_host() -> str:
    """Пытается получить внешний IP через сервис ifconfig.me."""
    try:
        r = subprocess.run(
            ['/opt/bin/curl', '-s', '--max-time', '5',
             'https://ifconfig.me/ip'],
            capture_output=True, text=True, timeout=7,
        )
        ip = (r.stdout or '').strip()
        if ip and len(ip) <= 45:
            return ip
    except Exception:
        pass
    return ''


def get_config() -> dict:
    """Читает config.conf в виде словаря."""
    result = {}
    if not os.path.exists(PROXY_CONF):
        return result
    try:
        with open(PROXY_CONF) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                k, v = line.split('=', 1)
                result[k.strip()] = v.strip().strip('"').strip("'")
    except Exception:
        pass
    return result


# --- Действия для UI ---
ACTIONS = {
    'install': {
        'title': 'Установка MTProxy',
        'icon': '\u2b07\ufe0f',
        'desc': (
            'Установит локальный MTProto-прокси для Telegram.\n\n'
            'Пакет: <code>tg-ws-proxy</code> (Go-версия).\n'
            'Конфиг: <code>/opt/etc/tg-ws-proxy/config.conf</code>.\n'
            'Ссылка подключения появится в логе после запуска.'
        ),
        'cmd': INSTALL_CMD,
    },
    'uninstall': {
        'title': 'Удаление MTProxy',
        'icon': '\U0001f5d1',
        'desc': (
            'Будут удалены пакет <code>tg-ws-proxy</code>, '
            'бинарник и init-скрипт.\n\n'
            '⚠️ Конфиги в <code>/opt/etc/tg-ws-proxy/</code> '
            'останутся — удалите вручную, если не нужны.'
        ),
        'cmd': UNINSTALL_CMD,
        'danger': True,
    },
    'start': {
        'title': 'Запуск MTProxy',
        'icon': '\u25b6\ufe0f',
        'desc': 'Команда: <code>S99tg-ws-proxy start</code>',
        'cmd': SERVICE_START,
    },
    'stop': {
        'title': 'Остановка MTProxy',
        'icon': '\u23f9',
        'desc': 'Команда: <code>S99tg-ws-proxy stop</code>',
        'cmd': SERVICE_STOP,
    },
    'restart': {
        'title': 'Перезапуск MTProxy',
        'icon': '\U0001f504',
        'desc': 'Команда: <code>S99tg-ws-proxy restart</code>',
        'cmd': SERVICE_RESTART,
    },
    'status': {
        'title': 'Статус MTProxy',
        'icon': '\U0001f4ca',
        'desc': 'Команда: <code>S99tg-ws-proxy status</code>',
        'cmd': SERVICE_STATUS,
    },
    'show_link': {
        'title': 'Показать ссылку подключения',
        'icon': '\U0001f517',
        'desc': 'Извлекает <code>tg://</code> ссылку из лога прокси',
        'cmd': GET_LINK,
    },
}

# ================= Описание целей удаления =================

UNINSTALL_TARGETS = [
    {
        'key': 'bin',
        'desc': 'Бинарник /opt/bin/tg-ws-proxy',
        'paths': ['/opt/bin/tg-ws-proxy'],
        'cmd': 'rm -f /opt/bin/tg-ws-proxy',
    },
    {
        'key': 'init',
        'desc': 'Init-скрипт S99tg-ws-proxy',
        'paths': ['/opt/etc/init.d/S99tg-ws-proxy'],
        'cmd': 'rm -f /opt/etc/init.d/S99tg-ws-proxy',
    },
    {
        'key': 'configs',
        'desc': 'Конфиги /opt/etc/tg-ws-proxy',
        'paths': ['/opt/etc/tg-ws-proxy'],
        'cmd': 'rm -rf /opt/etc/tg-ws-proxy',
    },
    {
        'key': 'logs',
        'desc': 'Логи и runtime',
        'paths': ['/opt/var/log/tg-ws-proxy.log', '/opt/var/run/tg-ws-proxy*'],
        'cmd': 'rm -rf /opt/var/log/tg-ws-proxy.log /opt/var/run/tg-ws-proxy*',
    },
]

# ================= Маски для поиска остатков ==================

SCAN_PATTERNS = [
    '*tg-ws-proxy*',
]