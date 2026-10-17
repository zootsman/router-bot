"""Действия модуля XKeen."""
import os
import subprocess

# Официальные команды
INSTALL_CMD = (
    'opkg update && opkg upgrade && '
    'opkg install curl tar && '
    'cd /tmp && sh -c "$(curl -sSL '
    'https://raw.githubusercontent.com/jameszeroX/XKeen/main/install.sh)"'
)

UNINSTALL_CMD = 'xkeen -remove'

# Команды управления
CMD_UPDATE_XKEEN = 'xkeen -uk'
CMD_UPDATE_GEO = 'xkeen -ug'
CMD_UPDATE_AUTO = 'xkeen -uac'
CMD_REGISTER_XRAY = 'xkeen -rx'
CMD_REGISTER_XKEEN = 'xkeen -rk'
CMD_REGISTER_INIT = 'xkeen -ri'
CMD_PORTS_SHOW = 'xkeen -cp'
CMD_PORTS_ADD = 'xkeen -ap'
CMD_PORTS_DEL = 'xkeen -dp'
CMD_PORTS_EXCL_SHOW = 'xkeen -cpe'
CMD_PORTS_EXCL_ADD = 'xkeen -ape'
CMD_PORTS_EXCL_DEL = 'xkeen -dpe'
CMD_TEST_CONN = 'xkeen -tc'
CMD_FD_TOGGLE = 'xkeen -fd'
CMD_AUTO_TOGGLE = 'xkeen -auto'
CMD_START = 'xkeen -start'
CMD_STOP = 'xkeen -stop'
CMD_RESTART = 'xkeen -restart'
CMD_STATUS = 'xkeen -status'
CMD_DIAG = 'xkeen -d'
CMD_CHANNEL = 'xkeen -channel'
CMD_UPDATE_XRAY = 'xkeen -ux'
CMD_UPDATE_MIHOMO = 'xkeen -um'
CMD_UPDATE_GEO = 'xkeen -ug'

# Возможные пути установки
XKEEN_PATHS = [
    '/opt/bin/xkeen',
    '/opt/sbin/xkeen',
]


def find_xkeen() -> str:
    """Возвращает путь к бинарю XKeen или ''."""
    for p in XKEEN_PATHS:
        if os.path.exists(p):
            return p
    try:
        r = subprocess.run(
            ['sh', '-c', 'command -v xkeen 2>/dev/null'],
            capture_output=True, text=True, timeout=3,
        )
        return (r.stdout or '').strip()
    except Exception:
        return ''


def is_installed() -> bool:
    return bool(find_xkeen())


def get_version() -> str:
    """Пытается получить версию XKeen."""
    try:
        r = subprocess.run(
            ['sh', '-c',
             'xkeen -v 2>/dev/null || xkeen --version 2>/dev/null || '
             'opkg list-installed 2>/dev/null | grep -i xkeen | head -1'],
            capture_output=True, text=True, timeout=5,
        )
        out = (r.stdout or '').strip()
        if not out:
            return ''
        # Если это строка opkg list-installed — берём версию
        parts = out.split()
        if len(parts) >= 3 and parts[0] == 'xkeen':
            return parts[2]
        return out.split('\n')[0][:40]
    except Exception:
        return ''


def get_service_status() -> str:
    """Возвращает 'running' / 'stopped' / 'unknown'."""
    try:
        # Проверяем процессы xray или mihomo
        r = subprocess.run(
            ['sh', '-c',
             'ps w | grep -E "(xray|mihomo|Xray|Mihomo)" '
             '| grep -v grep | wc -l'],
            capture_output=True, text=True, timeout=5,
        )
        count = int((r.stdout or '0').strip())
        return 'running' if count > 0 else 'stopped'
    except Exception:
        return 'unknown'


ACTIONS = {
    'install': {
        'title': 'Установка XKeen',
        'icon': '\u2b07\ufe0f',
        'desc': (
            'Будет установлена утилита XKeen для выборочной '
            'маршрутизации трафика через Xray/Mihomo.\n\n'
            'Установщик запустится интерактивно — '
            'вы сможете выбрать ядро, канал и другие параметры.'
        ),
        'cmd': INSTALL_CMD,
    },
    'uninstall': {
        'title': 'Удаление XKeen',
        'icon': '\U0001f5d1',
        'desc': (
            'Запустится <code>xkeen -remove</code>.\n\n'
            '⚠️ Это удалит настройки XKeen и ядра. '
            'Конфиги в /opt/etc/xray и /opt/etc/mihomo будут сохранены.'
        ),
        'cmd': UNINSTALL_CMD,
        'danger': True,
    },
    'start': {
        'title': 'Запуск XKeen',
        'icon': '\u25b6\ufe0f',
        'desc': 'Команда: <code>xkeen -start</code>',
        'cmd': CMD_START,
    },
    'stop': {
        'title': 'Остановка XKeen',
        'icon': '\u23f9',
        'desc': 'Команда: <code>xkeen -stop</code>',
        'cmd': CMD_STOP,
    },
    'restart': {
        'title': 'Перезапуск XKeen',
        'icon': '\U0001f504',
        'desc': 'Команда: <code>xkeen -restart</code>',
        'cmd': CMD_RESTART,
    },
    'diag': {
        'title': 'Диагностика XKeen',
        'icon': '\U0001f4ca',
        'desc': 'Команда: <code>xkeen -d</code>',
        'cmd': CMD_DIAG,
    },
    'channel': {
        'title': 'Смена канала',
        'icon': '\u2699\ufe0f',
        'desc': 'Команда: <code>xkeen -channel</code>',
        'cmd': CMD_CHANNEL,
    },
    'update_xray': {
        'title': 'Обновить ядро Xray',
        'icon': '\U0001f4e6',
        'desc': 'Команда: <code>xkeen -ux</code>',
        'cmd': CMD_UPDATE_XRAY,
    },
    'update_mihomo': {
        'title': 'Обновить ядро Mihomo',
        'icon': '\U0001f4e6',
        'desc': 'Команда: <code>xkeen -um</code>',
        'cmd': CMD_UPDATE_MIHOMO,
    },
    'update_geo': {
        'title': 'Обновить геофайлы',
        'icon': '\U0001f30d',
        'desc': 'Команда: <code>xkeen -ug</code>',
        'cmd': CMD_UPDATE_GEO,
    },
    'update_xkeen': {
        'title': 'Обновить XKeen',
        'icon': '\U0001f4e6',
        'desc': 'Команда: <code>xkeen -uk</code>',
        'cmd': CMD_UPDATE_XKEEN,
    },
    'update_auto': {
        'title': 'Настроить автообновления',
        'icon': '\U0001f504',
        'desc': 'Команда: <code>xkeen -uac</code>',
        'cmd': CMD_UPDATE_AUTO,
    },
    'register_xray': {
        'title': 'Зарегистрировать Xray',
        'icon': '\U0001f517',
        'desc': 'Команда: <code>xkeen -rx</code>',
        'cmd': CMD_REGISTER_XRAY,
    },
    'register_xkeen': {
        'title': 'Зарегистрировать XKeen',
        'icon': '\U0001f517',
        'desc': 'Команда: <code>xkeen -rk</code>',
        'cmd': CMD_REGISTER_XKEEN,
    },
    'register_init': {
        'title': 'Пересоздать init-скрипт',
        'icon': '\U0001f4c4',
        'desc': 'Команда: <code>xkeen -ri</code>',
        'cmd': CMD_REGISTER_INIT,
    },
    'ports_show': {
        'title': 'Показать порты прокси',
        'icon': '\U0001f50c',
        'desc': 'Команда: <code>xkeen -cp</code>',
        'cmd': CMD_PORTS_SHOW,
    },
    'ports_excl_show': {
        'title': 'Показать исключённые порты',
        'icon': '\U0001f6ab',
        'desc': 'Команда: <code>xkeen -cpe</code>',
        'cmd': CMD_PORTS_EXCL_SHOW,
    },
    'test_conn': {
        'title': 'Тест соединения',
        'icon': '\U0001f50d',
        'desc': 'Команда: <code>xkeen -tc</code>',
        'cmd': CMD_TEST_CONN,
    },
    'fd_toggle': {
        'title': 'Управление файловыми дескрипторами',
        'icon': '\U0001f4ca',
        'desc': 'Команда: <code>xkeen -fd</code>',
        'cmd': CMD_FD_TOGGLE,
    },
    'auto_toggle': {
        'title': 'Автозапуск при загрузке',
        'icon': '\u2699\ufe0f',
        'desc': 'Команда: <code>xkeen -auto</code>',
        'cmd': CMD_AUTO_TOGGLE,
    },
}



# ================= Описание целей удаления =================

UNINSTALL_TARGETS = [
    {
        'key': 'bin',
        'desc': 'Бинарник /opt/sbin/xkeen',
        'paths': ['/opt/sbin/xkeen', '/opt/bin/xkeen'],
        'cmd': 'rm -f /opt/sbin/xkeen /opt/bin/xkeen',
    },
    {
        'key': 'marker',
        'desc': 'Маркер /opt/sbin/.xkeen',
        'paths': ['/opt/sbin/.xkeen'],
        'cmd': 'rm -rf /opt/sbin/.xkeen',
    },
    {
        'key': 'configs',
        'desc': 'Конфиги /opt/etc/xkeen',
        'paths': ['/opt/etc/xkeen'],
        'cmd': 'rm -rf /opt/etc/xkeen',
    },
    {
        'key': 'logs',
        'desc': 'Логи и runtime',
        'paths': ['/opt/var/log/xkeen*', '/opt/var/run/xkeen*'],
        'cmd': 'rm -rf /opt/var/log/xkeen* /opt/var/run/xkeen*',
    },
]



# ================= Маски для поиска остатков ==================

SCAN_PATTERNS = [
    '*xkeen*', '*.xkeen*',
]