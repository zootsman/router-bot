"""Действия модуля usque-keenetic (Cloudflare WARP MASQUE)."""
import os
import subprocess

REPO_URL = 'https://side-effect-tm.github.io/usque-keenetic/all'
REPO_CONF = '/opt/etc/opkg/usque-keenetic.conf'

INSTALL_CMD = (
    'mkdir -p /opt/etc/opkg && '
    f'echo "src/gz usque-keenetic {REPO_URL}" > {REPO_CONF} && '
    'opkg update && '
    'opkg install usque-keenetic'
)

UNINSTALL_CMD = (
    'opkg remove --force-removal-of-dependent-packages '
    '--autoremove usque-keenetic 2>&1 || true'
)

SERVICE_START   = '/opt/etc/init.d/S51usque start   2>&1'
SERVICE_STOP    = '/opt/etc/init.d/S51usque stop    2>&1'
SERVICE_RESTART = '/opt/etc/init.d/S51usque restart 2>&1'
SERVICE_STATUS  = '/opt/etc/init.d/S51usque status  2>&1'

CMD_VERSION = 'opkg list-installed 2>/dev/null | grep "^usque-keenetic "'
CMD_CONFIG  = 'cat /opt/etc/usque/usque.conf 2>&1 || echo "конфиг не найден"'
CMD_LOGS    = 'tail -n 60 /opt/var/log/usque* 2>&1 || echo "лог не найден"'

USQUE_INIT = '/opt/etc/init.d/S51usque'
USQUE_CONF = '/opt/etc/usque/usque.conf'
USQUE_DIR  = '/opt/etc/usque'
USQUE_BIN  = '/opt/bin/usque'


def is_installed() -> bool:
    try:
        r = subprocess.run(
            ['sh', '-c', 'opkg list-installed 2>/dev/null | grep -q "^usque-keenetic "'],
            timeout=5,
        )
        if r.returncode == 0:
            return True
    except Exception:
        pass
    return os.path.exists(USQUE_INIT)


def is_running() -> bool:
    try:
        r = subprocess.run(
            ['sh', '-c', 'ps w | grep -E "[u]sque" | grep -v grep | wc -l'],
            capture_output=True, text=True, timeout=5,
        )
        return int((r.stdout or '0').strip()) > 0
    except Exception:
        return False


def get_version() -> str:
    try:
        r = subprocess.run(['sh', '-c', CMD_VERSION],
                           capture_output=True, text=True, timeout=5)
        for line in (r.stdout or '').splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[0] == 'usque-keenetic':
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


ACTIONS = {
    'install': {
        'title': 'Установка usque-keenetic',
        'icon': '\u2b07\ufe0f',
        'desc': (
            'Установит Cloudflare WARP (MASQUE) клиент.\n\n'
            'Регистрируется opkg-репозиторий side-effect-tm, '
            'ставится пакет <code>usque-keenetic</code>.\n\n'
            '⚠️ Требует Keenetic OS >= 5.0.\n'
            '⚠️ Конфликтует с keen_pbr / XKeen / HydraRoute.'
        ),
        'cmd': INSTALL_CMD,
    },
    'uninstall': {
        'title': 'Удаление usque-keenetic',
        'icon': '\U0001f5d1',
        'desc': (
            'Будет удалён пакет <code>usque-keenetic</code>.\n\n'
            '⚠️ Конфиги в <code>/opt/etc/usque/</code> останутся.'
        ),
        'cmd': UNINSTALL_CMD,
        'danger': True,
    },
    'start':    {'title': 'Запуск',    'icon': '\u25b6\ufe0f',
                 'desc': 'Команда: <code>S51usque start</code>',
                 'cmd': SERVICE_START},
    'stop':     {'title': 'Остановка', 'icon': '\u23f9',
                 'desc': 'Команда: <code>S51usque stop</code>',
                 'cmd': SERVICE_STOP},
    'restart':  {'title': 'Перезапуск', 'icon': '\U0001f504',
                 'desc': 'Команда: <code>S51usque restart</code>',
                 'cmd': SERVICE_RESTART},
    'status':   {'title': 'Статус',    'icon': '\U0001f4ca',
                 'desc': 'Команда: <code>S51usque status</code>',
                 'cmd': SERVICE_STATUS},
    'version':  {'title': 'Версия',    'icon': '\U0001f4c4',
                 'desc': 'Версия установленного пакета',
                 'cmd': CMD_VERSION},
    'show_config': {'title': 'Показать конфиг', 'icon': '\U0001f4c4',
                 'desc': 'Содержимое <code>usque.conf</code>',
                 'cmd': CMD_CONFIG},
    'logs':     {'title': 'Логи',      'icon': '\U0001f4dc',
                 'desc': 'Последние 60 строк лога',
                 'cmd': CMD_LOGS},
}

UNINSTALL_TARGETS = [
    {'key': 'init',    'desc': 'Init-скрипт S51usque',
     'paths': ['/opt/etc/init.d/S51usque'],
     'cmd': 'rm -f /opt/etc/init.d/S51usque'},
    {'key': 'configs', 'desc': 'Конфиги /opt/etc/usque',
     'paths': ['/opt/etc/usque'],
     'cmd': 'rm -rf /opt/etc/usque'},
    {'key': 'bin',     'desc': 'Бинарник /opt/bin/usque',
     'paths': ['/opt/bin/usque', '/opt/sbin/usque'],
     'cmd': 'rm -f /opt/bin/usque /opt/sbin/usque'},
    {'key': 'logs',    'desc': 'Логи usque*',
     'paths': ['/opt/var/log/usque*'],
     'cmd': 'rm -rf /opt/var/log/usque*'},
    {'key': 'repo',    'desc': 'opkg-репозиторий usque-keenetic',
     'paths': ['/opt/etc/opkg/usque-keenetic.conf'],
     'cmd': 'rm -f /opt/etc/opkg/usque-keenetic.conf'},
    {'key': 'opkg',    'desc': 'Метаданные opkg',
     'paths': ['/opt/lib/opkg/info/usque-keenetic*',
               '/opt/var/opkg-lists/usque-keenetic*'],
     'cmd': ('rm -rf /opt/lib/opkg/info/usque-keenetic* '
             '/opt/var/opkg-lists/usque-keenetic*')},
]

SCAN_PATTERNS = ['*usque*', '*Usque*']