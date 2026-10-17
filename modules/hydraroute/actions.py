"""Определения действий модуля HydraRoute."""

INSTALL_CMD = (
    'opkg update && '
    'opkg install curl && '
    'curl -Ls "https://ground-zerro.github.io/release/keenetic/install-neo.sh" | sh'
)

UPDATE_CMD = 'opkg update && opkg upgrade'

UNINSTALL_FULL_CMD = (
    'curl -Ls "https://git.zerrolabs.org/Ground-Zerro/release/pages/keenetic/hr-uninstall.sh" | sh'
)

UNINSTALL_STD_CMD = 'opkg remove hrneo'

# Дополнительные команды
CMD_VERSION = '/opt/bin/hrneo --version'
CMD_HELP = '/opt/bin/hrneo --help'
HR_DIR = '/opt/etc/HydraRoute'
HR_CONF = '/opt/etc/HydraRoute/hrneo.conf'
CMD_GENCONFIG = (
    f'cp -f {HR_CONF} {HR_CONF}.bak.$(date +%s) 2>/dev/null ; '
    f'/opt/bin/hrneo --genconfig {HR_DIR}/'
)
CMD_KEENETIC = '/opt/bin/hrneo --keenetic {TOKEN}'
CMD_DUMP = '/opt/bin/hrneo --dump 2>&1'
CMD_DIAG = 'ps w | grep -E "hrneo|hrweb|xray" | grep -v grep'


ACTIONS = {
    'install': {
        'title': 'Установка HydraRoute',
        'desc': (
            'Будут установлены пакеты HydraRoute.\n'
            'Веб-интерфейс HRweb станет доступен по адресу:\n'
            '<code>http://&lt;IP роутера&gt;:2000</code>\n\n'
            'Службы запустятся автоматически.'
        ),
        'cmd': INSTALL_CMD,
        'icon': '⬇️',
    },
    'update': {
        'title': 'Обновление пакетов',
        'desc': (
            'Команда: <code>opkg update &amp;&amp; opkg upgrade</code>\n\n'
            'Файлы конфигурации hrneo.conf, domain.conf, ip.list '
            'сохраняются при обновлении.'
        ),
        'cmd': UPDATE_CMD,
        'icon': '⬆️',
    },
    'uninstall_full': {
        'title': 'Полное удаление HydraRoute',
        'desc': (
            '⚠️ <b>Будут удалены:</b>\n'
            '• Пакеты: hrneo, hrweb, smartdns-webui, ipset, iptables, jq, '
            'hydraroute, adguardhome-go, node, node-npm, xray, xray-core\n'
            '• Папки: /opt/etc/HydraRoute, /opt/etc/AdGuardHome, '
            '/opt/etc/xray/, /opt/etc/Phobos, /opt/etc/smartdns-webui, '
            '/opt/var/lib/hrdns, /opt/var/lib/smartdns-webui\n\n'
            '❗ <b>ВНИМАНИЕ:</b> удаление xray может сломать VPN, если он '
            'использует xray. Проверьте перед продолжением.'
        ),
        'cmd': UNINSTALL_FULL_CMD,
        'icon': '🗑',
        'danger': True,
    },
    'uninstall_std': {
        'title': 'Стандартное удаление',
        'desc': (
            'Команда: <code>opkg remove hrneo</code>\n\n'
            'Удаляет только пакет hrneo, оставляя зависимости и данные.'
        ),
        'cmd': UNINSTALL_STD_CMD,
        'icon': '🗑',
    },
    'diag': {
        'title': 'Диагностика HydraRoute',
        'icon': '📊',
        'desc': 'Проверка запущенных процессов hrneo / hrweb / xray',
        'cmd': CMD_DIAG,
    },
    'version': {
        'title': 'Версия HydraRoute',
        'icon': '📄',
        'desc': 'Команда: <code>hrneo --version</code>',
        'cmd': CMD_VERSION,
    },
    'help': {
        'title': 'Справка HydraRoute',
        'icon': '❓',
        'desc': 'Команда: <code>hrneo --help</code>',
        'cmd': CMD_HELP,
    },
    'genconfig': {
        'title': 'Сгенерировать конфиг',
        'icon': '📝',
        'desc': 'Создаёт hrneo.conf со всеми параметрами по умолчанию',
        'cmd': CMD_GENCONFIG,
    },
    'watchlist': {
        'title': 'Watchlist',
        'icon': '📋',
        'desc': 'Текущий список отслеживания демона (hrneo --dump)',
        'cmd': CMD_DUMP,
    },
    'keenetic': {
        'title': 'Записать токен Keenetic',
        'needs_input': True,
        'icon': '🔑',
        'desc': 'Записывает rciToken в hrneo.conf',
        'cmd': CMD_KEENETIC,
    },
}


def is_installed() -> bool:
    """Проверяет, установлен ли HydraRoute."""
    import subprocess
    try:
        p = subprocess.run(
            ['sh', '-c', 'opkg list-installed 2>/dev/null | grep -q "^hrneo "'],
            timeout=5,
        )
        return p.returncode == 0
    except Exception:
        return False


def get_installed_version() -> str:
    import subprocess
    try:
        p = subprocess.run(
            ['sh', '-c', 'opkg list-installed 2>/dev/null | grep "^hrneo "'],
            capture_output=True, text=True, timeout=5,
        )
        for line in p.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[0] == 'hrneo':
                return parts[2]
    except Exception:
        pass
    return ''



# ================= Описание целей удаления =================

UNINSTALL_TARGETS = [
    {
        'key': 'xray',
        'desc': 'Xray (/opt/etc/xray)',
        'paths': ['/opt/etc/xray'],
        'cmd': 'rm -rf /opt/etc/xray',
    },
    {
        'key': 'adguard',
        'desc': 'AdGuardHome (/opt/etc/AdGuardHome)',
        'paths': ['/opt/etc/AdGuardHome'],
        'cmd': 'rm -rf /opt/etc/AdGuardHome',
    },
    {
        'key': 'phobos',
        'desc': 'Phobos, SmartDNS-WebUI',
        'paths': ['/opt/etc/Phobos', '/opt/etc/smartdns-webui',
                  '/opt/var/lib/hrdns', '/opt/var/lib/smartdns-webui'],
        'cmd': 'rm -rf /opt/etc/Phobos /opt/etc/smartdns-webui '
               '/opt/var/lib/hrdns /opt/var/lib/smartdns-webui',
    },
    {
        'key': 'logs',
        'desc': 'Логи и runtime',
        'paths': ['/opt/var/log/hydraroute*', '/opt/var/run/hrneo*'],
        'cmd': 'rm -rf /opt/var/log/hydraroute* /opt/var/run/hrneo*',
    },
]



# ================= Маски для поиска остатков ==================

SCAN_PATTERNS = [
    '*hydraroute*', '*hrneo*', '*hrweb*', '*hrdns*',
    '*Phobos*', '*smartdns-webui*',
]


# ============ Веб-морда и версии ============
import socket as _sock
import re as _re
import subprocess as _sp


def get_router_ip() -> str:
    """Локальный IP роутера (LAN)."""
    # 1. LAN-интерфейс br0 (Keenetic Home)
    try:
        r = _sp.run(['sh', '-c',
            "ip -4 addr show br0 2>/dev/null | "
            "grep -oE 'inet [0-9.]+' | head -1 | awk '{print $2}'"],
            capture_output=True, text=True, timeout=3)
        ip = (r.stdout or '').strip()
        if ip and not ip.startswith('127.'):
            return ip
    except Exception:
        pass
    # 2. Через connect к LAN-IP — не уйдёт через WAN
    s = _sock.socket(_sock.AF_INET, _sock.SOCK_DGRAM)
    try:
        s.connect(('192.168.1.1', 80))
        ip = s.getsockname()[0]
        if not ip.startswith('127.'):
            return ip
    except Exception:
        pass
    finally:
        s.close()
    return '192.168.1.1'


def get_hr_web_port() -> int:
    """Порт веб-морды HR: сначала netstat, потом конфиг, потом 2000."""
    # 1. netstat — точный порт, который hrweb слушает
    try:
        r = _sp.run(
            ['sh', '-c',
             "netstat -tlnp 2>/dev/null | grep hrweb | "
             "awk '{print $4}' | head -1"],
            capture_output=True, text=True, timeout=5,
        )
        out = (r.stdout or '').strip()
        if ':' in out:
            return int(out.rsplit(':', 1)[1])
    except Exception:
        pass
    # 2. конфиг — если кто-то задал порт вручную
    for path in ('/opt/etc/HydraRoute/hrweb.conf',
                 '/opt/etc/HydraRoute/hrneo.conf'):
        try:
            with open(path) as f:
                m = _re.search(r'^\s*port\s*[=:]\s*(\d+)',
                               f.read(), _re.M)
                if m:
                    return int(m.group(1))
        except Exception:
            pass
    return 2000


def get_hr_web_url() -> str:
    """Полный URL веб-морды HR."""
    return f'http://{get_router_ip()}:{get_hr_web_port()}'


def get_versions() -> dict:
    """Версии компонентов HR из opkg."""
    v = {'neo': '', 'web': '', 'hrdns': ''}
    try:
        r = _sp.run(
            ['sh', '-c', 'opkg list-installed 2>/dev/null'],
            capture_output=True, text=True, timeout=5,
        )
        for line in (r.stdout or '').splitlines():
            parts = line.split()
            if len(parts) >= 3:
                if   parts[0] == 'hrneo': v['neo']   = parts[2]
                elif parts[0] == 'hrweb': v['web']   = parts[2]
                elif parts[0] == 'hrdns': v['hrdns'] = parts[2]
    except Exception:
        pass
    return v


def check_updates() -> dict:
    """Проверка обновлений для hrneo/hrweb/hrdns.

    Возвращает:
      {'hrneo': {'installed': '3.24.0-1', 'latest': '3.25.0-1', 'update': True},
       ...}
    """
    pkgs = ('hrneo', 'hrweb', 'hrdns')
    result = {p: {'installed': '', 'latest': '', 'update': False}
              for p in pkgs}

    # 1. Установленные версии
    try:
        r = _sp.run(['sh', '-c', 'opkg list-installed 2>/dev/null'],
                    capture_output=True, text=True, timeout=10)
        for line in (r.stdout or '').splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[0] in pkgs:
                result[parts[0]]['installed'] = parts[2]
    except Exception:
        pass

    # 2. Обновляем список пакетов из репо
    try:
        _sp.run(['sh', '-c', 'opkg update 2>&1'],
                capture_output=True, text=True, timeout=60)
    except Exception:
        pass

    # 3. Последние версии из репо
    try:
        r = _sp.run(['sh', '-c', 'opkg list 2>/dev/null'],
                    capture_output=True, text=True, timeout=10)
        for line in (r.stdout or '').splitlines():
            parts = line.split(' - ', 1)
            if len(parts) == 2:
                name, rest = parts[0].strip(), parts[1].strip()
                if name in pkgs:
                    ver = rest.split(' - ', 1)[0].strip().split()[0]
                    result[name]['latest'] = ver
    except Exception:
        pass

    # 4. Сравнение
    for p in pkgs:
        ins = result[p]['installed']
        lat = result[p]['latest']
        if ins and lat and ins != lat:
            result[p]['update'] = True

    return result


# ============ Состояние: последние увиденные версии ============
import json as _json

HR_STATE_FILE = '/opt/router_bot/data/hydraroute/last_seen.json'


def load_last_seen() -> dict:
    try:
        with open(HR_STATE_FILE) as f:
            return _json.load(f)
    except Exception:
        return {}


def save_last_seen(data: dict) -> None:
    try:
        import os as _os
        _os.makedirs(_os.path.dirname(HR_STATE_FILE), exist_ok=True)
        with open(HR_STATE_FILE, 'w') as f:
            _json.dump(data, f, ensure_ascii=False, indent=2)
    except Exception:
        pass



def build_keenetic_cmd(token: str) -> str:
    """Команда записи токена Keenetic."""
    safe = token.strip().replace("'", "'\\''")
    return f"/opt/bin/hrneo --keenetic '{safe}' 2>&1"


def build_match_cmd(domain: str) -> str:
    """Команда проверки маршрута для домена."""
    safe = domain.strip().replace("'", "'\\''")
    return f"/opt/bin/hrneo --match '{safe}' 2>&1"


def build_help_text() -> str:
    return (
        '📖 <b>Справка HydraRoute Neo</b>\n'
        '\n'
        '⚙️ <b>Управление</b>\n'
        '• <code>--version</code> — версия компонентов\n'
        '• <code>--genconfig</code> — создать конфиг\n'
        '• <code>--keenetic &lt;token&gt;</code> — записать токен Keenetic\n'
        '\n'
        '🔍 <b>Диагностика</b>\n'
        '• <code>--dump</code> — watchlist (текущие правила)\n'
        '• <code>--match &lt;domain&gt;</code> — куда идёт домен\n'
        '• <code>--log &lt;console|file|syslog|off&gt;</code> — режим логов\n'
        '\n'
        '🌐 <b>Маршрутизация</b>\n'
        '• <code>--PolicyOrder p1,p2,...</code> — порядок политик\n'
        '• <code>--GlobalRouting &lt;true|false&gt;</code> — весь трафик через HR\n'
        '• <code>--ForceInterface &lt;if1,ifX&gt;</code> — привязать к интерфейсу\n'
        '• <code>--ConntrackFlush &lt;true|false&gt;</code> — flush при смене IP\n'
        '\n'
        '🔬 <b>L7 Capture</b> <i>(SNI / HTTP / QUIC)</i>\n'
        '• <code>--l7CaptureEnabled</code> — включить L7\n'
        '• <code>--l7EnableTLS</code> — парсинг TLS ClientHello\n'
        '• <code>--l7EnableHTTP</code> — парсинг HTTP Host\n'
        '• <code>--l7EnableQUIC</code> — парсинг QUIC SNI\n'
        '• <code>--l7WanInterface eth3</code> — WAN для правил\n'
        '\n'
        '📁 <b>Файлы</b>\n'
        '• <code>/opt/etc/HydraRoute/hrneo.conf</code> — конфиг\n'
        '• <code>/opt/var/log/LOGhrneo.log</code> — лог (если log=file)\n'
        '\n'
        '💡 <i>Полный список параметров доступен через hrneo --help в консоли.</i>'
    )