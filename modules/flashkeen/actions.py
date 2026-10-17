"""Действия модуля Flashkeen."""

INSTALL_CMD = (
    'opkg update || true; '
    'opkg install curl || true; '
    'curl -fsSL https://raw.githubusercontent.com/miha75vu-bit/Flashkeen/main/install.sh | sh'
)

UNINSTALL_CMD = (
    'curl -fL -s "https://raw.githubusercontent.com/miha75vu-bit/Flashkeen/main/uninstall.sh" '
    '-o /tmp/flashkeen-uninstall.sh && sh /tmp/flashkeen-uninstall.sh ; '
    'rm -f /opt/bin/f /opt/sbin/f /opt/bin/flashkeen /opt/sbin/flashkeen'
)

UPDATE_ENTWARE_CMD = 'opkg update && opkg upgrade'


# Какая команда запускает интерактивное меню
FLASHKEEN_LAUNCH = 'f'


def find_flashkeen() -> str:
    """Ищет бинарь/скрипт Flashkeen. Возвращает путь или ''."""
    import subprocess
    candidates = ['f', 'flashkeen', 'flashkeen.sh']
    for name in candidates:
        try:
            p = subprocess.run(
                ['sh', '-c', f'command -v {name} 2>/dev/null'],
                capture_output=True, text=True, timeout=3,
            )
            path = (p.stdout or '').strip()
            if path:
                return path
        except Exception:
            pass
    import os
    for path in ('/opt/bin/flashkeen', '/opt/sbin/flashkeen',
                 '/opt/usr/sbin/flashkeen', '/opt/bin/f'):
        if os.path.exists(path):
            return path
    return ''



# ================= Описание целей удаления =================

UNINSTALL_TARGETS = [
    {
        'key': 'bin',
        'desc': 'Бинарник /opt/bin/f',
        'paths': ['/opt/bin/f', '/opt/sbin/f',
                  '/opt/bin/flashkeen', '/opt/sbin/flashkeen'],
        'cmd': 'rm -f /opt/bin/f /opt/sbin/f '
               '/opt/bin/flashkeen /opt/sbin/flashkeen',
    },
    {
        'key': 'configs',
        'desc': 'Конфиги /opt/etc/flashkeen',
        'paths': ['/opt/etc/flashkeen'],
        'cmd': 'rm -rf /opt/etc/flashkeen',
    },
    {
        'key': 'logs',
        'desc': 'Логи и runtime',
        'paths': ['/opt/var/log/flashkeen*', '/opt/var/run/flashkeen*'],
        'cmd': 'rm -rf /opt/var/log/flashkeen* /opt/var/run/flashkeen*',
    },
]



# ================= Маски для поиска остатков ==================

SCAN_PATTERNS = [
    '*flashkeen*',
]