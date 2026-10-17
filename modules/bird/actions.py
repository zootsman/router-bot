"""Действия модуля BIRD."""
import os
import subprocess

# --- Установка / удаление ---
INSTALL_CMD = 'opkg update && opkg install bird2 bird2c'
UNINSTALL_CMD = 'opkg remove --force-removal-of-dependent-packages --autoremove bird2c bird2 2>&1; rm -f /opt/sbin/bird /opt/sbin/birdc /opt/etc/init.d/S70bird'

# --- Управление сервисом ---
SERVICE_START = '/opt/etc/init.d/S70bird start'
SERVICE_STOP = '/opt/etc/init.d/S70bird stop'
SERVICE_RESTART = '/opt/etc/init.d/S70bird restart'

# --- birdc: чтение ---
BIRDC_STATUS = '/opt/sbin/birdc show status'
BIRDC_PROTOCOLS = '/opt/sbin/birdc show protocols'
BIRDC_ROUTES = '/opt/sbin/birdc show route'
BIRDC_INTERFACES = '/opt/sbin/birdc show interfaces'

# --- birdc: управление ---
BIRDC_CONFIGURE = '/opt/sbin/birdc configure'
BIRDC_ENABLE_ALL = '/opt/sbin/birdc enable all'
BIRDC_DISABLE_ALL = '/opt/sbin/birdc disable all'

# Пути
BIRD_CONF = '/opt/etc/bird.conf'
BIRD_BIN = '/opt/sbin/bird'
BIRDC_BIN = '/opt/sbin/birdc'
BIRD_INIT = '/opt/etc/init.d/S70bird'


def find_bird() -> str:
    for p in (BIRD_BIN, '/opt/bin/bird'):
        if os.path.exists(p):
            return p
    try:
        r = subprocess.run(
            ['sh', '-c', 'command -v bird 2>/dev/null'],
            capture_output=True, text=True, timeout=3,
        )
        return (r.stdout or '').strip()
    except Exception:
        return ''


def is_installed() -> bool:
    """Проверяет, установлен ли пакет bird2 через opkg (надёжнее)."""
    try:
        r = subprocess.run(
            ['sh', '-c', 'opkg list-installed 2>/dev/null | grep -q "^bird2 "'],
            timeout=5,
        )
        if r.returncode == 0:
            return True
    except Exception:
        pass
    # fallback — по файлам
    return os.path.exists(BIRD_INIT)


def is_running() -> bool:
    """Проверяет, запущен ли демон bird."""
    try:
        r = subprocess.run(
            ['sh', '-c', 'ps w | grep -E "[b]ird " | grep -v grep | wc -l'],
            capture_output=True, text=True, timeout=5,
        )
        return int((r.stdout or '0').strip()) > 0
    except Exception:
        return False


def get_version() -> str:
    try:
        r = subprocess.run(
            ['sh', '-c', '/opt/sbin/bird --version 2>&1 | head -1'],
            capture_output=True, text=True, timeout=5,
        )
        out = (r.stdout or '').strip()
        return out[:60] if out else ''
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
        'title': 'Установка BIRD',
        'icon': '\u2b07\ufe0f',
        'desc': (
            'Установит BIRD 2 — демон динамической маршрутизации '
            '(BGP / OSPF).\n\n'
            'Пакеты: <code>bird2</code>, <code>bird2c</code>.\n'
            'Конфиг: <code>/opt/etc/bird.conf</code>.\n'
            'Скрипт запуска: <code>/opt/etc/init.d/S70bird</code>.'
        ),
        'cmd': INSTALL_CMD,
    },
    'uninstall': {
        'title': 'Удаление BIRD',
        'icon': '\U0001f5d1',
        'desc': (
            'Будут удалены пакеты <code>bird2</code> и <code>bird2c</code>.\n\n'
            '⚠️ Конфиг <code>/opt/etc/bird.conf</code> останется — '
            'удалите вручную, если он не нужен.'
        ),
        'cmd': UNINSTALL_CMD,
        'danger': True,
    },
    'start': {
        'title': 'Запуск BIRD',
        'icon': '\u25b6\ufe0f',
        'desc': 'Команда: <code>S70bird start</code>',
        'cmd': SERVICE_START,
    },
    'stop': {
        'title': 'Остановка BIRD',
        'icon': '\u23f9',
        'desc': 'Команда: <code>S70bird stop</code>',
        'cmd': SERVICE_STOP,
    },
    'restart': {
        'title': 'Перезапуск BIRD',
        'icon': '\U0001f504',
        'desc': 'Команда: <code>S70bird restart</code>',
        'cmd': SERVICE_RESTART,
    },
    'reload_conf': {
        'title': 'Перечитать конфиг',
        'icon': '\U0001f4c4',
        'desc': (
            'Команда: <code>birdc configure</code>\n\n'
            'BIRD перечитает <code>/opt/etc/bird.conf</code> без '
            'перезапуска демона. Если в конфиге есть ошибка — '
            'старая конфигурация останется активной.'
        ),
        'cmd': BIRDC_CONFIGURE,
    },
    'show_status': {
        'title': 'Статус BIRD',
        'icon': '\U0001f4ca',
        'desc': 'Команда: <code>birdc show status</code>',
        'cmd': BIRDC_STATUS,
    },
    'show_protocols': {
        'title': 'Показать протоколы',
        'icon': '\U0001f517',
        'desc': 'Команда: <code>birdc show protocols</code>',
        'cmd': BIRDC_PROTOCOLS,
    },
    'show_routes': {
        'title': 'Показать маршруты',
        'icon': '\U0001f5fa',
        'desc': 'Команда: <code>birdc show route</code>',
        'cmd': BIRDC_ROUTES,
    },
    'show_interfaces': {
        'title': 'Показать интерфейсы',
        'icon': '\U0001f4e1',
        'desc': 'Команда: <code>birdc show interfaces</code>',
        'cmd': BIRDC_INTERFACES,
    },
    'enable_all': {
        'title': 'Включить все протоколы',
        'icon': '\u2705',
        'desc': 'Команда: <code>birdc enable all</code>',
        'cmd': BIRDC_ENABLE_ALL,
    },
    'disable_all': {
        'title': 'Отключить все протоколы',
        'icon': '\u274c',
        'desc': 'Команда: <code>birdc disable all</code>',
        'cmd': BIRDC_DISABLE_ALL,
    },
    'show_symbols': {
        'title': 'Показать символы',
        'icon': '\U0001f523',
        'desc': 'Команда: <code>birdc show symbols</code>',
        'cmd': '/opt/sbin/birdc show symbols',
    },
    'show_static': {
        'title': 'Показать статические маршруты',
        'icon': '\U0001f4cc',
        'desc': 'Команда: <code>birdc show static</code>',
        'cmd': '/opt/sbin/birdc show static',
    },
    'show_bfd': {
        'title': 'Показать BFD-сессии',
        'icon': '\U0001f4e1',
        'desc': 'Команда: <code>birdc show bfd sessions</code>',
        'cmd': '/opt/sbin/birdc show bfd sessions',
    },
}


# ================= Описание целей удаления =================
# Каждый target:
#   key   — идентификатор (для callback и опций)
#   desc  — описание для пользователя
#   paths — маски путей (glob) для проверки существования
#   cmd   — shell-команда для удаления (если опция активна)

UNINSTALL_TARGETS = [
    {
        'key': 'bin',
        'desc': 'Бинарники bird / birdc',
        'paths': ['/opt/sbin/bird', '/opt/sbin/birdc',
                  '/opt/bin/bird', '/opt/bin/birdc'],
        'cmd': 'rm -f /opt/sbin/bird /opt/sbin/birdc '
               '/opt/bin/bird /opt/bin/birdc',
    },
    {
        'key': 'init',
        'desc': 'Init-скрипт S70bird',
        'paths': ['/opt/etc/init.d/S70bird'],
        'cmd': 'rm -f /opt/etc/init.d/S70bird',
    },
    {
        'key': 'config',
        'desc': 'Конфиг bird.conf (+ .bak)',
        'paths': ['/opt/etc/bird.conf', '/opt/etc/bird.conf.bak'],
        'cmd': 'rm -f /opt/etc/bird.conf /opt/etc/bird.conf.bak',
    },
    {
        'key': 'logs',
        'desc': 'Логи и runtime-файлы',
        'paths': ['/opt/var/run/bird.ctl', '/opt/var/run/bird.pid',
                  '/opt/var/log/bird.log'],
        'cmd': 'rm -rf /opt/var/run/bird* /opt/var/log/bird*',
    },
]


def existing_targets():
    """Возвращает только те target'ы, чьи пути реально существуют."""
    import glob as _g
    result = []
    for t in UNINSTALL_TARGETS:
        found = False
        for p in t['paths']:
            try:
                if _g.glob(p):
                    found = True
                    break
            except Exception:
                pass
        if found:
            result.append(t)
    return result



# ================= Маски для поиска остатков после удаления ==========

SCAN_PATTERNS = [
    '*bird*', '*birdc*', '*S70bird*',
]