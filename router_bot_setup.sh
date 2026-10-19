#!/bin/sh
set -e

# --- Защита от запуска через pipe (curl | sh) ---
# Если stdin не терминал, а /dev/tty есть — переоткрываем stdin
# на /dev/tty, чтобы "read" работали.
# Если /dev/tty нет (cron, systemd, etc.) — работаем с дефолтами
# (все "read" получат пустую строку).
# При не-терминале stdin (curl|sh, Popen, cron) "read" получат EOF
# и вернут дефолт. При интерактивном запуске работают как обычно.
# Блок exec < /dev/tty УБРАН: при setsid() (Popen) /dev/tty не открывается.

SETUP_VERSION="0.0.9-02"  # AUTO_DISCOVERY_PATCH_V1
VERSION_FILE="/opt/router_bot/VERSION"
INSTALLED_VERSION=""
if [ -f "$VERSION_FILE" ]; then
    INSTALLED_VERSION=$(cat "$VERSION_FILE" 2>/dev/null | tr -d " \n\r")
fi

ver_cmp() {
    v1="$1"; v2="$2"
    base1="${v1%%-*}"; suf1=""
    case "$v1" in *-*) suf1="${v1#*-}" ;; esac
    base2="${v2%%-*}"; suf2=""
    case "$v2" in *-*) suf2="${v2#*-}" ;; esac

    a1=$(echo "$base1" | cut -d. -f1); b1=$(echo "$base1" | cut -d. -f2); c1=$(echo "$base1" | cut -d. -f3)
    a2=$(echo "$base2" | cut -d. -f1); b2=$(echo "$base2" | cut -d. -f2); c2=$(echo "$base2" | cut -d. -f3)
    a1=${a1:-0}; b1=${b1:-0}; c1=${c1:-0}
    a2=${a2:-0}; b2=${b2:-0}; c2=${c2:-0}

    if [ "$a1" -lt "$a2" ]; then echo -1; return; fi
    if [ "$a1" -gt "$a2" ]; then echo 1; return; fi
    if [ "$b1" -lt "$b2" ]; then echo -1; return; fi
    if [ "$b1" -gt "$b2" ]; then echo 1; return; fi
    if [ "$c1" -lt "$c2" ]; then echo -1; return; fi
    if [ "$c1" -gt "$c2" ]; then echo 1; return; fi

    n1=0
    if [ -n "$suf1" ]; then case "$suf1" in *[!0-9]*) n1=0 ;; *) n1="$suf1" ;; esac; fi
    n2=0
    if [ -n "$suf2" ]; then case "$suf2" in *[!0-9]*) n2=0 ;; *) n2="$suf2" ;; esac; fi
    if [ "$n1" -lt "$n2" ]; then echo -1; return; fi
    if [ "$n1" -gt "$n2" ]; then echo 1; return; fi
    echo 0
}

echo "============================================"
echo "  Router Bot - установка / обновление"
echo "============================================"
echo ""
MODE="install"
if [ -n "$INSTALLED_VERSION" ]; then
    echo "Установлено:  $INSTALLED_VERSION"
    echo "В архиве:     $SETUP_VERSION"
    echo ""
    cmp=$(ver_cmp "$INSTALLED_VERSION" "$SETUP_VERSION")
    case "$cmp" in
        -1) MODE="upgrade" ;;
        0)
            _RETRY=0
            while [ "$_RETRY" -lt 3 ]; do
                _RETRY=$((_RETRY+1))
                printf "Версии совпадают. Переустановить? (y/N): "
                read -r ANS
                ANS=$(printf "%s" "$ANS" | sed 's/[^[:alnum:]]//g')
                case "$ANS" in
                    y|Y) break ;;
                    n|N) echo "Отмена."; exit 0 ;;
                    "") ;;
                    *) echo "  Введите y (переустановить) или n (отмена)" ;;
                esac
            done
            if [ "$ANS" != "y" ] && [ "$ANS" != "Y" ]; then
                echo "Отмена."; exit 0
            fi
            MODE="reinstall"
            ;;
        1)
            _RETRY=0
            while [ "$_RETRY" -lt 3 ]; do
                _RETRY=$((_RETRY+1))
                printf "Установлена более новая версия. Продолжить? (y/N): "
                read -r ANS
                ANS=$(printf "%s" "$ANS" | sed 's/[^[:alnum:]]//g')
                case "$ANS" in
                    y|Y) break ;;
                    n|N) echo "Отмена."; exit 0 ;;
                    "") ;;
                    *) echo "  Введите y или n" ;;
                esac
            done
            if [ "$ANS" != "y" ] && [ "$ANS" != "Y" ]; then
                echo "Отмена."; exit 0
            fi
            MODE="downgrade"
            ;;
    esac
    echo "Режим: $MODE"
    echo ""
fi
export RB_MODE="$MODE"
export RB_VERSION="$SETUP_VERSION"

# ============================================================
#  Сверка файлов с манифестом (обнаружение правок пользователя)
# ============================================================
MANIFEST="/opt/router_bot/.manifest"
USER_BACKUP="/opt/router_bot/.user_backup"

if [ -d /opt/router_bot ] && [ -f "$MANIFEST" ] && [ "$MODE" != "install" ]; then
    echo "→ Сверяю файлы с предыдущей установкой..."
    _conflicts=0
    _missing=0
    while IFS= read -r _line; do
        [ -z "$_line" ] && continue
        _old_hash=$(printf '%s' "$_line" | awk '{print $1}')
        _path=$(printf '%s' "$_line" | awk '{$1=""; sub(/^ /,""); print}')
        [ -z "$_path" ] && continue
        case "$_path" in
            */__pycache__/*|*.pyc|*.pyo) continue ;;
        esac
        if [ ! -f "$_path" ]; then
            _missing=$((_missing+1))
            continue
        fi
        _cur_hash=$(sha256sum "$_path" 2>/dev/null | awk '{print $1}')
        if [ -n "$_cur_hash" ] && [ "$_cur_hash" != "$_old_hash" ]; then
            _rel="${_path#/opt/router_bot/}"
            _bak="$USER_BACKUP/$_rel"
            mkdir -p "$(dirname "$_bak")"
            cp -p "$_path" "$_bak" 2>/dev/null || true
            echo "  ⚠️  изменён: $_rel (сохранён в .user_backup/)"
            _conflicts=$((_conflicts+1))
        fi
    done < "$MANIFEST"

    if [ "$_conflicts" -eq 0 ] && [ "$_missing" -eq 0 ]; then
        echo "  ✅ изменений нет"
    else
        [ "$_conflicts" -gt 0 ] && echo "  Всего изменено: $_conflicts"
        [ "$_missing" -gt 0 ] && echo "  Отсутствует: $_missing (будут восстановлены)"
    fi
    echo ""
fi

echo "→ Создаю структуру /opt/router_bot/..."
mkdir -p /opt/router_bot/core
mkdir -p /opt/bin
mkdir -p /opt/router_bot/modules
mkdir -p /opt/router_bot/modules/net_watch
mkdir -p /opt/router_bot/modules/ssh_control
mkdir -p /opt/router_bot/modules/system
mkdir -p /opt/router_bot/modules/hydraroute
mkdir -p /opt/router_bot/modules/flashkeen
mkdir -p /opt/router_bot/modules/xkeen
mkdir -p /opt/router_bot/modules/bird
mkdir -p /opt/router_bot/modules/mtproxy
mkdir -p /opt/router_bot/modules/keen_pbr
mkdir -p /opt/router_bot/modules/neofit
mkdir -p /opt/router_bot/modules/awg_manager
mkdir -p /opt/router_bot/data/awg_manager
mkdir -p /opt/router_bot/modules/usque_keenetic
mkdir -p /opt/router_bot/data/net_watch
mkdir -p /opt/router_bot/data/ssh_control
mkdir -p /opt/router_bot/data/xkeen
mkdir -p /opt/router_bot/data/bird
mkdir -p /opt/router_bot/data/hydraroute
mkdir -p /opt/router_bot/data/mtproxy
mkdir -p /opt/router_bot/data/keen_pbr
mkdir -p /opt/router_bot/data/neofit
mkdir -p /opt/router_bot/data/usque_keenetic
mkdir -p /opt/router_bot/data/system
mkdir -p /opt/var/log

echo "  → main.py"
cat > /opt/router_bot/main.py << 'RB_MAIN_PY_EOF'
#!/opt/bin/python3
import sys
sys.path.insert(0, '/opt/router_bot')

from core.main import main

if __name__ == '__main__':
    main()
RB_MAIN_PY_EOF

echo "  → VERSION"
cat > /opt/router_bot/VERSION << 'RB_VERSION_EOF'
0.0.9-02
RB_VERSION_EOF

echo "  → core/__init__.py"
cat > /opt/router_bot/core/__init__.py << 'RB_CORE___INIT___PY_EOF'

RB_CORE___INIT___PY_EOF

echo "  → core/module_base.py"
cat > /opt/router_bot/core/module_base.py << 'RB_CORE_MODULE_BASE_PY_EOF'
"""Базовый класс модуля router_bot (контракт + дефолты)."""


class ModuleBase:
    name = ''
    title = ''
    icon = '📦'
    description = ''
    category = None
    category_title = ''
    category_icon = '📁'
    commands = []
    conflicts_with = {}
    default_enabled = True
    cleanup_paths = []
    cleanup_init = []

    def __init__(self, chat_id):
        self.chat_id = str(chat_id)

    async def startup(self, app): pass
    async def on_leave(self): pass
    async def send_card_message(self, update, ctx): pass
    async def handle_callback(self, action, query, ctx): pass
    def get_installed(self): return False
    def get_status_short(self): return '❔'
RB_CORE_MODULE_BASE_PY_EOF

echo "  → core/module_loader.py"
cat > /opt/router_bot/core/module_loader.py << 'RB_CORE_MODULE_LOADER_PY_EOF'
"""Авто-обнаружение модулей из /opt/router_bot/modules/."""
import importlib
import logging
import pkgutil

log = logging.getLogger(__name__)
MODULES_DIR = '/opt/router_bot/modules'


def discover_module_classes() -> dict:
    result = {}
    for entry in pkgutil.iter_modules([MODULES_DIR]):
        if not entry.ispkg or entry.name.startswith('_'):
            continue
        folder = entry.name
        try:
            mod = importlib.import_module(f'modules.{folder}.module')
        except Exception as e:
            log.warning('Module %s: import failed: %s', folder, e)
            continue
        cls = _find_module_class(mod, folder)
        if cls is None:
            log.warning('Module %s: no class with .name=="%s"', folder, folder)
            continue
        if folder in result:
            log.warning('Module %s: duplicate', folder); continue
        result[folder] = cls
        log.info('Discovered module: %s -> %s', folder, cls.__name__)
    return result


def _find_module_class(module, folder_name: str):
    for attr in dir(module):
        try:
            obj = getattr(module, attr)
        except Exception:
            continue
        if not isinstance(obj, type): continue
        if obj.__module__ != module.__name__: continue
        if getattr(obj, 'name', None) == folder_name: return obj
    return None
RB_CORE_MODULE_LOADER_PY_EOF

echo "  → core/list_modules.py"
cat > /opt/router_bot/core/list_modules.py << 'RB_CORE_LIST_MODULES_PY_EOF'
#!/opt/bin/python3
"""TSV: name|title|icon|description|category|default_enabled."""
import sys
sys.path.insert(0, '/opt/router_bot')
from core.module_loader import discover_module_classes


def main():
    try:
        classes = discover_module_classes()
    except Exception as e:
        print(f'ERROR|{e}', file=sys.stderr); sys.exit(1)
    for name in sorted(classes.keys()):
        cls = classes[name]
        title = getattr(cls, 'title', name) or name
        icon = getattr(cls, 'icon', '📦') or '📦'
        desc = (getattr(cls, 'description', '') or '').replace('|','/').replace('\n',' ')
        cat = getattr(cls, 'category', '') or ''
        de = '1' if getattr(cls, 'default_enabled', True) else '0'
        print('|'.join([name, title, icon, desc, cat, de]))


if __name__ == '__main__':
    main()
RB_CORE_LIST_MODULES_PY_EOF
chmod +x /opt/router_bot/core/list_modules.py

echo "  → core/uninstall_helper.py"
cat > /opt/router_bot/core/uninstall_helper.py << 'RB_CORE_UNINSTALL_HELPER_PY_EOF'
#!/opt/bin/python3
"""Пути и init-скрипты модулей: --paths | --etc | --init."""
import sys
sys.path.insert(0, '/opt/router_bot')
from core.module_loader import discover_module_classes


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else '--paths'
    try:
        classes = discover_module_classes()
    except Exception as e:
        print(f'ERROR: {e}', file=sys.stderr); sys.exit(1)

    if mode == '--init':
        seen = set()
        for name in sorted(classes.keys()):
            for i in getattr(classes[name], 'cleanup_init', []):
                if i and i not in seen:
                    seen.add(i); print(i)
        return

    if mode not in ('--paths', '--etc'):
        print(f'Unknown mode: {mode}', file=sys.stderr); sys.exit(2)

    seen = set()
    for name in sorted(classes.keys()):
        for p in getattr(classes[name], 'cleanup_paths', []):
            if not p or p in seen: continue
            seen.add(p)
            is_etc = p.startswith('/opt/etc/')
            if (mode == '--etc' and is_etc) or (mode == '--paths' and not is_etc):
                print(p)


if __name__ == '__main__':
    main()
RB_CORE_UNINSTALL_HELPER_PY_EOF
chmod +x /opt/router_bot/core/uninstall_helper.py

echo "  → core/config.py"
cat > /opt/router_bot/core/config.py << 'RB_CORE_CONFIG_PY_EOF'
"""Чтение config.env в окружение."""
import os

CONFIG_PATH = '/opt/router_bot/config.env'

def load_config():
    if not os.path.exists(CONFIG_PATH):
        return
    with open(CONFIG_PATH) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            v = v.strip().strip('"').strip("'")
            os.environ.setdefault(k.strip(), v)

def get(key: str, default: str = '') -> str:
    return os.environ.get(key, default)
RB_CORE_CONFIG_PY_EOF

echo "  → core/main.py"
cat > /opt/router_bot/core/main.py << 'RB_CORE_MAIN_PY_EOF'
"""Точка входа фреймворка router_bot."""
import asyncio
import json
import logging
import os
import socket
import subprocess
import urllib.error
import urllib.request
from datetime import datetime, timedelta

def _read_config_value(key, default=''):
    try:
        with open('/opt/router_bot/config.env') as f:
            for line in f:
                line = line.strip()
                if line.startswith(key + '='):
                    v = line.split('=', 1)[1].strip().strip('"').strip("'")
                    return v
    except Exception:
        pass
    return default

_disable_ipv6 = _read_config_value('DISABLE_IPV6', 'yes').lower() in ('1', 'yes', 'on', 'true')
if _disable_ipv6:
    _orig_getaddrinfo = socket.getaddrinfo
    def _ipv4_only(host, port, family=0, type=0, proto=0, flags=0):
        return _orig_getaddrinfo(host, port, socket.AF_INET, type, proto, flags)
    socket.getaddrinfo = _ipv4_only

# ============================================================================
#  Self-update (проверка версии на GitHub, скачивание, запуск)
# ============================================================================

_UPDATE_URLS = [
    'https://raw.githubusercontent.com/zootsman/router-bot/master/router_bot_setup.sh',
    'https://cdn.jsdelivr.net/gh/zootsman/router-bot@master/router_bot_setup.sh',
    'https://raw.gitmirror.com/zootsman/router-bot/master/router_bot_setup.sh',
    'https://ghproxy.net/https://raw.githubusercontent.com/zootsman/router-bot/master/router_bot_setup.sh',
]
_UPDATE_STATE_FILE = '/opt/router_bot/data/system/self_update.json'
_UPDATE_LOG = '/opt/var/log/self_update.log'
_UPDATE_SCRIPT = '/tmp/router_bot_setup_selfupdate.sh'
_UPDATE_CHECK_INTERVAL = 6 * 3600
_UPDATE_SNOOZE_DAYS = 7


def _ver_cmp(v1: str, v2: str) -> int:
    """Сравнивает версии с поддержкой -N. -1/0/1."""
    def _split(v):
        base, _, suf = v.partition('-')
        try:
            parts = [int(x) for x in base.split('.')]
        except ValueError:
            parts = [0, 0, 0]
        while len(parts) < 3:
            parts.append(0)
        try:
            n = int(suf) if suf else 0
        except ValueError:
            n = 0
        return parts[:3], n
    p1, n1 = _split(v1)
    p2, n2 = _split(v2)
    if p1 < p2: return -1
    if p1 > p2: return 1
    if n1 < n2: return -1
    if n1 > n2: return 1
    return 0


def _read_current_version() -> str:
    try:
        with open('/opt/router_bot/VERSION') as f:
            return f.read().strip().split('\n')[0].strip()
    except Exception:
        return ''


def _load_update_state() -> dict:
    try:
        with open(_UPDATE_STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def _save_update_state(data: dict):
    try:
        os.makedirs(os.path.dirname(_UPDATE_STATE_FILE), exist_ok=True)
        with open(_UPDATE_STATE_FILE, 'w') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
    except Exception as e:
        log.warning('save self-update state failed: %s', e)


def _fetch_latest_version(timeout=10) -> str:
    """Первые 4КБ с GitHub (с fallback на зеркала) → SETUP_VERSION."""
    import re
    last_err = None
    for url in _UPDATE_URLS:
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'RouterBot-selfupdate'})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                buf = r.read(4096).decode('utf-8', errors='replace')
            m = re.search(r'^SETUP_VERSION="([^"]+)"', buf, re.MULTILINE)
            if m:
                log.debug('fetch version OK via %s', url)
                return m.group(1)
        except Exception as e:
            last_err = e
            log.debug('fetch version failed via %s: %s', url, e)
            continue
    raise RuntimeError(f'Все зеркала недоступны. Последняя ошибка: {last_err}')


def _download_and_verify(timeout=60) -> str:
    """Скачивает setup.sh в /tmp и проверяет. Возвращает путь."""
    data = None
    last_err = None
    for url in _UPDATE_URLS:
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'RouterBot-selfupdate'})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                data = r.read()
            if len(data) > 100_000:
                log.debug('download OK via %s', url)
                break
        except Exception as e:
            last_err = e
            log.debug('download failed via %s: %s', url, e)
            data = None
            continue
    if not data:
        raise RuntimeError(f'Все зеркала недоступны. Последняя ошибка: {last_err}')
    if len(data) < 100_000:
        raise RuntimeError(f'слишком маленький: {len(data)} байт')

    with open(_UPDATE_SCRIPT, 'wb') as f:
        f.write(data)
    os.chmod(_UPDATE_SCRIPT, 0o755)

    checks = []
    r1 = subprocess.run(['sh', '-n', _UPDATE_SCRIPT], capture_output=True, timeout=10)
    if r1.returncode != 0:
        checks.append(f'sh -n: {(r1.stderr or b"").decode(errors="replace")[:120]}')
    try:
        with open(_UPDATE_SCRIPT, 'rb') as f:
            head = f.read(200).decode('utf-8', errors='replace')
            f.seek(0)
            body = f.read().decode('utf-8', errors='replace')
        if not head.startswith('#!/bin/sh'):
            checks.append('shebang не #!/bin/sh')
        if 'SETUP_VERSION=' not in body[:4096]:
            checks.append('SETUP_VERSION не найден')
        if 'RB_MAIN_PY_EOF' not in body:
            checks.append('RB_MAIN_PY_EOF не найден (не установщик?)')
    except Exception as e:
        checks.append(f'содержимое: {e}')

    if checks:
        try:
            os.unlink(_UPDATE_SCRIPT)
        except Exception:
            pass
        raise RuntimeError('; '.join(checks))
    return _UPDATE_SCRIPT


def _spawn_self_update():
    """Запускает self-update в фоне (отвязан от бота)."""
    log_fp = open(_UPDATE_LOG, 'a')
    env = os.environ.copy()
    env['RB_NONINTERACTIVE'] = '1'
    subprocess.Popen(
        ['sh', _UPDATE_SCRIPT],
        stdin=subprocess.DEVNULL,
        stdout=log_fp,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        env=env,
    )
    log.info('self-update: spawned %s (log: %s)', _UPDATE_SCRIPT, _UPDATE_LOG)


async def _check_and_notify_self_update(app) -> bool:
    current = _read_current_version()
    if not current:
        return False
    try:
        latest = await asyncio.to_thread(_fetch_latest_version)
    except Exception as e:
        log.info('self-update: fetch failed: %s', e)
        return False

    st = _load_update_state()
    st['last_check'] = datetime.now().isoformat(timespec='seconds')

    if _ver_cmp(latest, current) <= 0:
        st.pop('last_notified_version', None)
        st.pop('snoozed_until', None)
        st.pop('never_notify_version', None)
        _save_update_state(st)
        log.info('self-update: up to date (%s)', current)
        return False

    if st.get('never_notify_version') == latest:
        _save_update_state(st)
        log.info('self-update: silenced for %s', latest)
        return False
    if st.get('last_notified_version') == latest:
        _save_update_state(st)
        log.info('self-update: already notified %s', latest)
        return False
    su = st.get('snoozed_until', '')
    if su:
        try:
            if datetime.now() < datetime.fromisoformat(su):
                _save_update_state(st)
                log.info('self-update: snoozed until %s', su)
                return False
        except Exception:
            pass

    chat_id = app.bot_data.get('chat_id') or cfg('TG_CHAT_ID')
    if not chat_id:
        log.warning('self-update: chat_id неизвестен')
        return False

    text = (
        '\U0001f195 <b>Доступно обновление Router Bot</b>\n\n'
        f'Сейчас: <code>{current}</code>\n'
        f'Новое:  <code>{latest}</code>\n\n'
        '<i>Обновление скачается с GitHub и установится автоматически. '
        'Бот перезапустится через 5–10 секунд.</i>'
    )
    kb = InlineKeyboardMarkup([
        [InlineKeyboardButton('\u2b06\ufe0f Обновить сейчас',
                              callback_data='router:update_now')],
        [InlineKeyboardButton('\u23f0 Позже (7 дней)',
                              callback_data='router:update_later')],
        [InlineKeyboardButton('\u274c Не напоминать про эту версию',
                              callback_data='router:update_never')],
    ])
    try:
        msg = await app.bot.send_message(chat_id=chat_id, text=text,
                                   parse_mode='HTML', reply_markup=kb)
        try:
            from core.utils import notify_register
            notify_register(chat_id, msg.message_id)
        except Exception: pass
        st['last_notified_version'] = latest
        _save_update_state(st)
        log.info('self-update: notified %s -> %s', current, latest)
        return True
    except Exception as e:
        log.warning('self-update: notify failed: %s', e)
        return False


async def _self_update_loop(app):
    """Фоновый цикл: первая проверка через 2 мин, потом раз в 6 часов."""
    await asyncio.sleep(120)
    while True:
        try:
            await _check_and_notify_self_update(app)
        except Exception as e:
            log.debug('self-update check failed: %s', e)
        await asyncio.sleep(_UPDATE_CHECK_INTERVAL)

# -----------------------------------------------------------------------

from telegram import (
    BotCommand, InlineKeyboardButton, InlineKeyboardMarkup, Update,
)
from telegram.ext import (
    ApplicationBuilder, CommandHandler, CallbackQueryHandler,
    ContextTypes,
)

from core.config import load_config, get as cfg
from core.utils import (
    check_mirrors, get_current_mirror, apply_mirror,
    build_mirrors_text, build_mirrors_kb, ENTWARE_MIRRORS,
    set_last_msg, get_last_msg, show_card, notify_cleanup,
)
from core.router import ModuleRouter

log = logging.getLogger(__name__)


async def _build_main_menu(router):
    by_category = {}
    standalone = []
    for mod in router.all():
        cat = getattr(mod, 'category', None)
        if cat:
            by_category.setdefault(cat, []).append(mod)
        else:
            standalone.append(mod)

    lines = ['\U0001f916 <b>Router Bot</b>', '', '<i>Модули:</i>']
    kb = []

    # Сначала — одиночные модули
    for mod in standalone:
        desc = getattr(mod, 'description', '')
        if desc:
            lines.append(f'{mod.icon} <b>{mod.title}</b> \u2014 {desc}')
        else:
            lines.append(f'{mod.icon} <b>{mod.title}</b>')
        kb.append([InlineKeyboardButton(
            f'{mod.icon} {mod.title}', callback_data=f'{mod.name}:main')])

    # Потом — категории
    for cat_name, mods in by_category.items():
        if len(mods) == 1:
            # одна кнопка — прямой переход
            mod = mods[0]
            desc = getattr(mod, 'description', '')
            if desc:
                lines.append(f'{mod.icon} <b>{mod.title}</b> \u2014 {desc}')
            else:
                lines.append(f'{mod.icon} <b>{mod.title}</b>')
            kb.append([InlineKeyboardButton(
                f'{mod.icon} {mod.title}', callback_data=f'{mod.name}:main')])
        else:
            cat_title = getattr(mods[0], 'category_title', cat_name.capitalize())
            cat_icon = getattr(mods[0], 'category_icon', '\U0001f4c1')
            titles = ', '.join(m.title for m in mods)
            lines.append(f'{cat_icon} <b>{cat_title}</b> \u2014 {titles}')
            kb.append([InlineKeyboardButton(
                f'{cat_icon} {cat_title}', callback_data=f'router:cat:{cat_name}')])

    # Кнопка управления модулями
    _enabled_now = {m.name for m in router.all()}
    kb.append([InlineKeyboardButton(
        f'\U0001f9e9 Модули ({len(_enabled_now)} из {len(_ALL_MODULE_META)})',
        callback_data='router:modules',
    )])

    return '\n'.join(lines), InlineKeyboardMarkup(kb)


async def _show_category(q, ctx, cat_name: str):
    """Показывает содержимое категории со статусом каждого модуля."""
    router = ctx.application.bot_data['router']
    mods = [m for m in router.all() if getattr(m, 'category', None) == cat_name]
    if not mods:
        await q.answer('Категория пуста', show_alert=True)
        return
    await q.answer()

    cat_title = getattr(mods[0], 'category_title', cat_name.capitalize())
    cat_icon = getattr(mods[0], 'category_icon', '\U0001f4c1')

    # Кто установлен — для проверки конфликтов
    installed = set()
    running = set()
    for mod in mods:
        try:
            fn_inst = getattr(mod, 'get_installed', None)
            is_inst = bool(fn_inst and fn_inst())
            if is_inst:
                installed.add(mod.name)
            fn_run = getattr(mod, 'is_running', None)
            if is_inst:
                if fn_run:
                    if fn_run():
                        running.add(mod.name)
                else:
                    running.add(mod.name)  # fallback: считаем запущенным
        except Exception as e:
            log.debug('get_installed/running %s failed: %s', mod.name, e)

    lines = [f'{cat_icon} <b>{cat_title}</b>', '']
    kb = []

    for mod in mods:
        # Статус
        status = '\u26aa'
        try:
            fn = getattr(mod, 'get_status_short', None)
            if fn:
                status = fn()
        except Exception as e:
            log.debug('get_status_short %s failed: %s', mod.name, e)

        desc = getattr(mod, 'description', '')
        if desc:
            lines.append(f'{status} {mod.icon} <b>{mod.title}</b> \u2014 {desc}')
        else:
            lines.append(f'{status} {mod.icon} <b>{mod.title}</b>')

        # Проверка конфликтов — только если модуль УСТАНОВЛЕН
        # (для не установленных — нечего конфликтовать)
        cw = getattr(mod, 'conflicts_with', None)
        if cw and mod.name in installed:
            items = cw.items() if isinstance(cw, dict) else [(n, '') for n in cw]
            for cname, reason in items:
                if cname not in installed:
                    continue
                other = router.get(cname)
                other_title = other.title if other else cname
                is_running = cname in running
                suffix = '' if is_running else ' (не запущен)'
                if reason:
                    lines.append(
                        f'   \u26a0\ufe0f Конфликт с <b>{other_title}</b>{suffix}: '
                        f'<i>{reason}</i>'
                    )
                else:
                    lines.append(
                        f'   \u26a0\ufe0f Конфликт с <b>{other_title}</b>{suffix}'
                    )

        kb.append([InlineKeyboardButton(
            f'{mod.icon} {mod.title}', callback_data=f'{mod.name}:main')])

    kb.append([InlineKeyboardButton('\u2b05\ufe0f К модулям',
                                     callback_data='router:main')])

    try:
        await q.edit_message_text(
            '\n'.join(lines), parse_mode='HTML',
            reply_markup=InlineKeyboardMarkup(kb),
        )
    except Exception as e:
        if 'not modified' not in str(e).lower():
            raise



    await show_card(update, ctx,
        f'{icon} <b>{title}</b>\n\nНажмите кнопку ниже, чтобы открыть модуль.',
        InlineKeyboardMarkup([[
            InlineKeyboardButton(f'{icon} Открыть {title}',
                                 callback_data=f'{mod_name}:main'),
        ]]),
    )


# ============================================================================
#  Управление модулями через inline-кнопки
# ============================================================================

_ALL_MODULE_META = (
    ('net_watch',      '\U0001f4e1', 'Net Watch',      'мониторинг сетевых клиентов'),
    ('ssh_control',    '\U0001f4bb', 'SSH Control',    'управление по SSH'),
    ('system',         '\U0001f5a5', 'System',         'состояние роутера'),
    ('hydraroute',     '\U0001f40d', 'HydraRoute',     'установка/управление HR'),
    ('flashkeen',      '\U0001f4be', 'Flashkeen',      'менеджер дисков'),
    ('xkeen',          '\U0001f43e', 'XKeen',          'Xray/Mihomo'),
    ('bird',           '\U0001f426', 'BIRD',           'BGP/OSPF'),
    ('mtproxy',        '\U0001f310', 'MTProxy',        'MTProto-прокси'),
    ('keen_pbr',       '\U0001f6e4', 'Keen-PBR',       'policy-based routing'),
    ('neofit',         '\U0001f500', 'NeoFit',         'веб-панель Xray/Sing-Box'),
    ('usque_keenetic', '\u2601\ufe0f', 'Usque WARP',   'Cloudflare MASQUE'),
    ('awg_manager',    '\U0001f6e1', 'AWG Manager',    'AmneziaWG/Sing-box'),
)

_MODULE_CONFLICTS = {
    'hydraroute':     ['xkeen'],
    'xkeen':          ['hydraroute'],
    'bird':           ['hydraroute', 'xkeen'],
    'keen_pbr':       ['xkeen', 'hydraroute'],
    'usque_keenetic': ['keen_pbr', 'xkeen', 'hydraroute'],
    'awg_manager':    ['xkeen', 'hydraroute', 'keen_pbr', 'usque_keenetic'],
}

_MODULE_PKG_DEPS = {
    'ssh_control': ['openssh-client', 'openssh-keygen'],
}


def _read_enabled_modules() -> set:
    try:
        with open('/opt/router_bot/config.env') as f:
            for line in f:
                if line.startswith('ENABLED_MODULES='):
                    v = line.split('=', 1)[1].strip().strip('"').strip("'")
                    return {m.strip() for m in v.split(',') if m.strip()}
    except Exception:
        pass
    return set()


def _save_enabled_modules(mods: set):
    cfg_path = '/opt/router_bot/config.env'
    enabled_str = ','.join(sorted(mods))
    with open(cfg_path) as f:
        lines = f.readlines()
    found = False
    for i, line in enumerate(lines):
        if line.startswith('ENABLED_MODULES='):
            lines[i] = f"ENABLED_MODULES='{enabled_str}'\n"
            found = True
            break
    if not found:
        lines.append(f"ENABLED_MODULES='{enabled_str}'\n")
    with open(cfg_path, 'w') as f:
        f.writelines(lines)
    subprocess.run(['cp', '-p', cfg_path, cfg_path + '.bak'],
                   capture_output=True, timeout=5)


def _build_modules_menu(pending: set):
    lines = [
        '\U0001f9e9 <b>Модули</b>',
        '',
        '<i>Нажмите на модуль, чтобы включить/выключить. '
        'Затем нажмите «Применить».</i>',
        '',
    ]
    rows = []
    for name, icon, title, desc in _ALL_MODULE_META:
        mark = '\u2705' if name in pending else '\u2b1c'
        suffix = ''
        if name in pending:
            for c in _MODULE_CONFLICTS.get(name, []):
                if c in pending:
                    suffix = ' \u26a0\ufe0f'
                    break
        rows.append([InlineKeyboardButton(
            f'{mark} {icon} {title}{suffix}',
            callback_data=f'router:mod:t:{name}',
        )])

    n_on = sum(1 for m, _, _, _ in _ALL_MODULE_META if m in pending)
    lines.append(f'<i>Включено: {n_on} из {len(_ALL_MODULE_META)}</i>')

    routed = [m for m in ('hydraroute', 'xkeen', 'keen_pbr',
                           'usque_keenetic', 'awg_manager', 'bird')
              if m in pending]
    if len(routed) > 1:
        lines.append(
            '\u26a0\ufe0f <i>Внимание: включено несколько '
            'конфликтующих модулей. Одновременно будет работать '
            'только один.</i>'
        )

    rows.append([
        InlineKeyboardButton('\u2705 Все', callback_data='router:mod:all'),
        InlineKeyboardButton('\u2b1c Ничего', callback_data='router:mod:none'),
    ])
    rows.append([
        InlineKeyboardButton('\u2705 Применить', callback_data='router:mod:apply'),
        InlineKeyboardButton('\u274c Отмена', callback_data='router:mod:cancel'),
    ])
    return '\n'.join(lines), InlineKeyboardMarkup(rows)


async def _on_modules_menu(q, ctx):
    await q.answer()
    actual = _read_enabled_modules()
    ctx.application.bot_data['pending_modules'] = set(actual)
    text, kb = _build_modules_menu(actual)
    try:
        await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
    except Exception as e:
        if 'not modified' not in str(e).lower():
            raise


async def _on_module_toggle(q, ctx, name):
    await q.answer()
    pending = ctx.application.bot_data.get('pending_modules')
    if pending is None:
        pending = _read_enabled_modules()
    if name in pending:
        if len(pending) <= 1:
            await q.answer('Нужен хотя бы один модуль', show_alert=True)
            return
        pending.discard(name)
    else:
        pending.add(name)
    ctx.application.bot_data['pending_modules'] = pending
    text, kb = _build_modules_menu(pending)
    try:
        await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
    except Exception as e:
        if 'not modified' not in str(e).lower():
            raise


async def _on_module_bulk(q, ctx, mode):
    await q.answer()
    if mode == 'all':
        ctx.application.bot_data['pending_modules'] = {
            m for m, _, _, _ in _ALL_MODULE_META
        }
    else:
        ctx.application.bot_data['pending_modules'] = {'net_watch'}
    pending = ctx.application.bot_data['pending_modules']
    text, kb = _build_modules_menu(pending)
    try:
        await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
    except Exception as e:
        if 'not modified' not in str(e).lower():
            raise


async def _on_modules_apply(q, ctx):
    pending = ctx.application.bot_data.get('pending_modules')
    if not pending:
        await q.answer('Нечего применять', show_alert=True)
        return
    actual = _read_enabled_modules()
    added = pending - actual
    removed = actual - pending
    if not added and not removed:
        await q.answer('Изменений нет', show_alert=False)
        return

    await q.answer('Применяю...')
    try:
        await q.edit_message_text(
            '\u23f3 <b>Применяю изменения...</b>\n\n'
            f'Добавляю: {len(added)}, убираю: {len(removed)}\n'
            '<i>Проверяю зависимости...</i>',
            parse_mode='HTML',
        )
    except Exception:
        pass

    deps_to_install = []
    for m in added:
        for pkg in _MODULE_PKG_DEPS.get(m, []):
            r = subprocess.run(
                ['sh', '-c',
                 f'opkg list-installed 2>/dev/null | grep -q "^{pkg} "'],
                timeout=5,
            )
            if r.returncode != 0:
                deps_to_install.append(pkg)

    if deps_to_install:
        try:
            await q.edit_message_text(
                '\u23f3 <b>Применяю изменения...</b>\n\n'
                f'\U0001f4e6 Устанавливаю: '
                f'<code>{" ".join(deps_to_install)}</code>\n'
                '<i>Это займёт 10–30 сек...</i>',
                parse_mode='HTML',
            )
        except Exception:
            pass
        try:
            await asyncio.to_thread(
                subprocess.run,
                ['opkg', 'install'] + deps_to_install,
                capture_output=True,
                timeout=120,
            )
        except Exception as e:
            log.warning('opkg install failed: %s', e)

    try:
        _save_enabled_modules(pending)
    except Exception as e:
        log.exception('save enabled modules failed: %s', e)
        try:
            await q.edit_message_text(
                f'\u274c <b>Ошибка записи</b>\n\n<code>{e}</code>',
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([[
                    InlineKeyboardButton('\u2b05\ufe0f Назад',
                                          callback_data='router:modules'),
                ]]),
            )
        except Exception:
            pass
        return

    ctx.application.bot_data.pop('pending_modules', None)

    enabled_str = ','.join(sorted(pending))
    try:
        await q.edit_message_text(
            '\u2705 <b>Модули сохранены</b>\n\n'
            f'Включено: <b>{len(pending)}</b> из {len(_ALL_MODULE_META)}\n'
            f'<code>{enabled_str}</code>\n\n'
            '\U0001f504 <i>Бот перезапустится через 3 секунды. '
            'Когда вернётся — напишите /start.</i>',
            parse_mode='HTML',
        )
    except Exception:
        pass

    subprocess.Popen(
        ['sh', '-c', 'sleep 3 && /opt/etc/init.d/S98routerbot restart'],
        start_new_session=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    log.info('modules applied: %s', enabled_str)


async def _on_modules_cancel(q, ctx):
    await q.answer()
    ctx.application.bot_data.pop('pending_modules', None)
    router = ctx.application.bot_data['router']
    text, kb = await _build_main_menu(router)
    try:
        await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
    except Exception as e:
        if 'not modified' not in str(e).lower():
            raise


async def _cmd_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    router = ctx.application.bot_data['router']
    for mod in router.all():
        if hasattr(mod, 'on_leave'):
            try:
                await mod.on_leave()
            except Exception as e:
                log.warning('on_leave %s failed: %s', mod.name, e)
    text, kb = await _build_main_menu(router)
    await show_card(update, ctx, text, kb)


async def _cmd_restart(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    kb = InlineKeyboardMarkup([
        [InlineKeyboardButton('\u2705 Перезапустить', callback_data='router:restart_confirm')],
        [InlineKeyboardButton('\u274c Отмена', callback_data='router:main')],
    ])
    await update.message.reply_text(
        '\U0001f504 <b>Перезапустить Router Bot?</b>\n\n'
        'Бот будет недоступен 5–10 секунд.',
        parse_mode='HTML',
        reply_markup=kb,
    )


async def _cmd_reboot(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    kb = InlineKeyboardMarkup([
        [InlineKeyboardButton('\u2705 Перезагрузить', callback_data='router:reboot_confirm')],
        [InlineKeyboardButton('\u274c Отмена', callback_data='router:main')],
    ])
    await update.message.reply_text(
        '\U0001f504 <b>Перезагрузить роутер?</b>\n\n'
        '⚠️ Роутер будет недоступен 1–3 минуты.\n'
        'Бот вернётся автоматически после загрузки.',
        parse_mode='HTML',
        reply_markup=kb,
    )


async def _do_reboot_confirm(q, ctx):
    await q.answer('Перезагружаю...')
    try:
        await q.edit_message_text(
            '\U0001f504 <b>Роутер перезагружается...</b>\n\n'
            'Вернётся через 1–3 минуты. Напишите /start после.',
            parse_mode='HTML',
        )
    except Exception:
        pass
    try:
        subprocess.Popen(
            ['sh', '-c', 'sleep 3 && reboot'],
            start_new_session=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        log.info('Reboot scheduled (3s delay)')
    except Exception as e:
        log.exception('Reboot failed: %s', e)


async def _do_restart_confirm(q, ctx):
    await q.answer('Перезапускаю...')
    try:
        await q.edit_message_text(
            '\U0001f504 <b>Перезапуск...</b>\n\n'
            'Бот вернётся через 5–10 секунд. Напишите /start после.',
            parse_mode='HTML',
        )
    except Exception:
        pass

    # отвязанный процесс: ждёт 3 сек, потом рестартит бота
    try:
        subprocess.Popen(
            ['sh', '-c', 'sleep 3 && /opt/etc/init.d/S98routerbot restart'],
            start_new_session=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        log.info('Restart scheduled (3s delay)')
    except Exception as e:
        log.exception('Restart scheduling failed: %s', e)


async def _cmd_mirrors(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    await show_card(update, ctx, '\U0001f30d Проверяю зеркала Entware... (5-10 сек)')
    results = await check_mirrors()
    current = get_current_mirror()
    text = build_mirrors_text(results, current)
    kb = build_mirrors_kb(results)
    last_id = get_last_msg(update.effective_chat.id)
    if last_id:
        try:
            await ctx.bot.edit_message_text(
                chat_id=update.effective_chat.id, message_id=last_id,
                text=text, parse_mode='HTML', reply_markup=kb,
            )
        except Exception:
            pass


async def _cmd_update(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    await show_card(update, ctx, '\U0001f50d Проверяю версию на GitHub...')
    last_id = get_last_msg(update.effective_chat.id)
    async def _edit(text, kb=None):
        if last_id:
            try:
                await ctx.bot.edit_message_text(
                    chat_id=update.effective_chat.id, message_id=last_id,
                    text=text, parse_mode='HTML', reply_markup=kb,
                )
            except Exception:
                pass
    current = _read_current_version()
    try:
        latest = await asyncio.to_thread(_fetch_latest_version)
    except Exception as e:
        await _edit(f'\u274c Не удалось проверить: <code>{e}</code>')
        return
    if _ver_cmp(latest, current) <= 0:
        await _edit(
            f'\u2705 <b>Актуальная версия</b>\n\n'
            f'Текущая: <code>{current}</code>\n'
            f'На GitHub: <code>{latest}</code>')
        return
    text = (
        f'\U0001f195 <b>Доступно обновление</b>\n\n'
        f'Сейчас: <code>{current}</code>\n'
        f'Новое:  <code>{latest}</code>\n\n'
        f'Обновить?'
    )
    kb = InlineKeyboardMarkup([
        [InlineKeyboardButton('\u2b06\ufe0f Обновить сейчас',
                              callback_data='router:update_now')],
        [InlineKeyboardButton('\u23f0 Позже',
                              callback_data='router:update_later')],
        [InlineKeyboardButton('\u274c Отмена',
                              callback_data='router:main')],
    ])
    await _edit(text, kb)


async def _on_self_update_now(q, ctx):
    try:
        await q.answer('Скачиваю...')
    except Exception as e:
        log.warning('q.answer update_now failed: %s', e)
    try:
        await q.edit_message_text(
            '\U0001f4e5 <b>Скачиваю и проверяю обновление...</b>\n\n'
            '<i>Занимает ~10 секунд.</i>',
            parse_mode='HTML')
    except Exception:
        pass
    try:
        path = await asyncio.to_thread(_download_and_verify)
        log.info('self-update: downloaded %s (%d байт)', path, os.path.getsize(path))
    except Exception as e:
        log.exception('self-update: download failed: %s', e)
        try:
            await q.edit_message_text(
                f'\u274c <b>Не удалось скачать обновление</b>\n\n'
                f'<code>{e}</code>\n\n'
                f'Попробуйте позже: /update',
                parse_mode='HTML')
        except Exception:
            pass
        return
    try:
        await q.edit_message_text(
            '\u2705 <b>Обновление скачано и проверено</b>\n\n'
            'Установка займёт 1–2 минуты. Бот перезапустится автоматически.\n'
            'Напишите /start через 2 минуты.',
            parse_mode='HTML')
    except Exception:
        pass
    try:
        _spawn_self_update()
    except Exception as e:
        log.exception('spawn failed: %s', e)
        try:
            await ctx.bot.send_message(
                chat_id=q.message.chat_id,
                text=f'\u274c Не удалось запустить: {e}\n\n'
                     f'Запустите вручную:\n'
                     f'<code>sh /tmp/router_bot_setup_selfupdate.sh</code>',
                parse_mode='HTML')
        except Exception:
            pass


async def _on_self_update_later(q, ctx):
    try:
        await q.answer()
    except Exception:
        pass
    st = _load_update_state()
    until = (datetime.now() + timedelta(days=_UPDATE_SNOOZE_DAYS)).isoformat(timespec='seconds')
    st['snoozed_until'] = until
    _save_update_state(st)
    await q.answer(f'Напомню через {_UPDATE_SNOOZE_DAYS} дней')
    try:
        await q.edit_message_text(
            f'\u23f0 <b>Напомню позже</b>\n\n'
            f'До: <code>{until[:10]}</code>\n\n'
            f'Проверить вручную: /update',
            parse_mode='HTML')
    except Exception:
        pass


async def _on_self_update_never(q, ctx):
    try:
        await q.answer('Уведомления отключены для этой версии')
    except Exception:
        pass
    st = _load_update_state()
    latest = st.get('last_notified_version', '')
    if latest:
        st['never_notify_version'] = latest
    _save_update_state(st)
    await q.answer('Уведомления отключены для этой версии')
    try:
        await q.edit_message_text(
            '\u274c <b>Уведомления отключены</b>\n\n'
            '<i>При выходе следующей версии напоминание придёт снова.</i>\n'
            'Проверить вручную: /update',
            parse_mode='HTML')
    except Exception:
        pass


async def _on_mirrors(q, ctx):
    """Callback router:mirrors — открывает карточку зеркал."""
    await q.answer('Проверяю зеркала...')
    results = await check_mirrors()
    current = get_current_mirror()
    text = build_mirrors_text(results, current)
    kb = build_mirrors_kb(results)
    try:
        await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
    except Exception as e:
        if 'not modified' not in str(e).lower():
            raise


async def _on_mirrors_check(q, ctx):
    """Callback router:mirrors_check — перепроверить зеркала."""
    await q.answer('Проверяю...')
    results = await check_mirrors()
    current = get_current_mirror()
    text = build_mirrors_text(results, current)
    kb = build_mirrors_kb(results)
    try:
        await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
    except Exception as e:
        if 'not modified' not in str(e).lower():
            raise


async def _on_mirror_apply(q, ctx, idx):
    """Callback router:mirror_apply:<idx> — применить зеркало."""
    try:
        i = int(idx)
        url = ENTWARE_MIRRORS[i]
    except Exception:
        await q.answer('Неверный индекс', show_alert=True)
        return
    ok, msg = apply_mirror(url)
    if ok:
        await q.answer(f'✅ {msg}')
    else:
        await q.answer(f'❌ {msg}', show_alert=True)
    # перерисуем
    results = await check_mirrors()
    current = get_current_mirror()
    text = build_mirrors_text(results, current)
    kb = build_mirrors_kb(results)
    try:
        await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
    except Exception:
        pass


async def _cmd_help(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    router = ctx.application.bot_data['router']
    for mod in router.all():
        if hasattr(mod, 'on_leave'):
            try:
                await mod.on_leave()
            except Exception as e:
                log.warning('on_leave %s failed: %s', mod.name, e)
    lines = ['\U0001f916 <b>Router Bot</b>', '', '<b>Основные команды:</b>',
             '/start   \u2014 главное меню',
             '/help    \u2014 эта справка',
             '/restart \u2014 перезапуск бота',
             '/reboot  \u2014 перезагрузка роутера',
             '/mirrors \u2014 проверка зеркал Entware',
             '/update  \u2014 проверка обновления бота']
    mod_cmds = []
    for mod in router.all():
        for cmd_name, desc in getattr(mod, 'commands', []):
            mod_cmds.append(f'/{cmd_name}   \u2014 {desc}')
    if mod_cmds:
        lines += ['', '<b>Модули:</b>'] + mod_cmds
    lines += ['', '<b>Активные модули:</b>']
    for mod in router.all():
        icon  = getattr(mod, 'icon', '\U0001f4e6')
        title = getattr(mod, 'title', mod.name)
        desc  = getattr(mod, 'description', '')
        if desc:
            lines.append(f'{icon} <b>{title}</b> \u2014 {desc}')
        else:
            lines.append(f'{icon} <b>{title}</b>')
    lines += ['', '<i>Полный список команд \u2014 нажмите / в поле ввода.</i>']
    kb = InlineKeyboardMarkup([
        [InlineKeyboardButton('\U0001f680 Открыть главное меню', callback_data='router:main')],
    ])
    await show_card(update, ctx, '\n'.join(lines), kb)


async def _on_router_main(query, ctx):
    """Callback 'router:main' — возврат в главное меню."""
    await query.answer()
    ctx.application.bot_data.pop('pending_modules', None)
    router = ctx.application.bot_data['router']
    text, kb = await _build_main_menu(router)
    try:
        await query.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
    except Exception as e:
        if 'not modified' not in str(e).lower():
            raise


def _register_module_open_handler(app, mod, cmd_name):
    """Открывает карточку модуля по /<cmd_name>."""
    async def _open(update, ctx, _mod=mod):
        try:
            if hasattr(_mod, 'send_card_message'):
                await _mod.send_card_message(update, ctx)
            else:
                await update.message.reply_text(
                    f'{getattr(_mod, "title", _mod.name)} недоступен')
        except Exception as e:
            log.exception('Open %s failed: %s', getattr(_mod, 'name', '?'), e)
            try:
                await update.message.reply_text(
                    f'\u274c {getattr(_mod, "title", "модуль")}: {e}')
            except Exception:
                pass
    app.add_handler(CommandHandler(cmd_name, _open))


async def post_init(app):
    router = app.bot_data['router']
    for mod in router.all():
        try:
            await mod.startup(app)
        except Exception as e:
            log.exception('Module %s startup failed: %s', mod.name, e)
    cmds = [
        BotCommand('start',   '\U0001f680 Главное меню'),
        BotCommand('help',    '\u2753 Помощь'),
        BotCommand('restart', '\U0001f504 Перезапуск бота'),
        BotCommand('reboot',  '\U0001f504 Перезагрузка роутера'),
        BotCommand('mirrors', '\U0001f30d Проверка зеркал Entware'),
        BotCommand('update',  '\U0001f195 Проверить обновление'),
    ]
    seen = {c.command for c in cmds}
    for mod in router.all():
        for cmd_name, desc in getattr(mod, 'commands', []):
            if cmd_name in seen:
                continue
            seen.add(cmd_name)
            cmds.append(BotCommand(cmd_name, desc))
            _register_module_open_handler(app, mod, cmd_name)
    try:
        await app.bot.set_my_commands(cmds)
        log.info('Commands registered: %s', [c.command for c in cmds])
    except Exception as e:
        log.warning('set_my_commands failed: %s', e)
    app.bot_data['chat_id'] = cfg('TG_CHAT_ID')
    asyncio.create_task(_self_update_loop(app))
    log.info('self-update loop started (interval %ss)', _UPDATE_CHECK_INTERVAL)
    log.info('Router bot started')




async def _notif_cleanup_loop(app):
    await asyncio.sleep(300)
    while True:
        try:
            await notify_cleanup(app.bot, older_than_hours=24)
        except Exception as e:
            log.debug('notif cleanup loop failed: %s', e)
        await asyncio.sleep(3600)

def main():
    logging.basicConfig(
        format='%(asctime)s [%(levelname)s] %(message)s',
        level=logging.INFO,
        handlers=[
            logging.FileHandler('/opt/var/log/router_bot.log'),
        ],
    )
    for noisy in ('httpx', 'httpcore'):
        logging.getLogger(noisy).setLevel(logging.CRITICAL)
    for tlog in ('telegram.ext.Updater', 'telegram.request'):
        logging.getLogger(tlog).setLevel(logging.WARNING)

    load_config()

    # Проверка сети при старте
    try:
        import socket as _s
        _s.create_connection(('149.154.166.110', 443), timeout=5).close()
        log.info('Telegram API: доступен (IPv4)')
    except Exception as _e:
        log.warning('Telegram API: НЕДОСТУПЕН (%s)', _e)

    token = cfg('TG_BOT_TOKEN')
    chat_id = cfg('TG_CHAT_ID')
    if not token or not chat_id:
        log.critical('TG_BOT_TOKEN / TG_CHAT_ID не заданы в config.env')
        return

    # --- Регистрация модулей из ENABLED_MODULES ---
    enabled_raw = cfg('ENABLED_MODULES', 'net_watch,ssh_control')
    enabled_set = {m.strip() for m in enabled_raw.split(',') if m.strip()}
    log.info('Enabled modules: %s', sorted(enabled_set))

    router = ModuleRouter()

    from core.module_loader import discover_module_classes
    _all_classes = discover_module_classes()
    log.info('Discovered modules: %s', sorted(_all_classes.keys()))
    for _mname in sorted(enabled_set):
        _cls = _all_classes.get(_mname)
        if _cls is None:
            log.warning('Unknown module in ENABLED_MODULES: %s', _mname)
            continue
        try:
            router.register(_cls(chat_id))
        except Exception as e:
            log.exception('Failed to init module %s: %s', _mname, e)

    if not router.all():
        log.critical('Ни один модуль не включён. Проверьте ENABLED_MODULES в config.env')
        return

    app = ApplicationBuilder().token(token).post_init(post_init).build()
    app.bot_data['router'] = router

    # Глобальные команды
    app.add_handler(CommandHandler('start', _cmd_start))
    app.add_handler(CommandHandler('help', _cmd_help))
    app.add_handler(CommandHandler('restart', _cmd_restart))
    app.add_handler(CommandHandler('reboot', _cmd_reboot))
    app.add_handler(CommandHandler('mirrors', _cmd_mirrors))
    app.add_handler(CommandHandler('update', _cmd_update))

    # Общий callback — обрабатывает router:main отдельно, остальное — в роутер
    async def _global_callback(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        q = update.callback_query
        try:
            await notify_cleanup(ctx.bot, update.effective_chat.id, exclude_msg_id=q.message.message_id)
        except Exception:
            pass
        if q.data.startswith('router:cat:'):
            cat_name = q.data[len('router:cat:'):]
            return await _show_category(q, ctx, cat_name)
        if q.data.endswith(':edit_new'):
            _mn = q.data[:-len(':edit_new')]
            _m = ctx.application.bot_data['router'].get(_mn)
            if _m and hasattr(_m, '_ask_new_config'):
                await _m._ask_new_config(q, ctx)
                return
        if q.data == 'router:update_now':
            return await _on_self_update_now(q, ctx)
        if q.data == 'router:update_later':
            return await _on_self_update_later(q, ctx)
        if q.data == 'router:update_never':
            return await _on_self_update_never(q, ctx)
        if q.data == 'router:mirrors':
            return await _on_mirrors(q, ctx)
        if q.data == 'router:mirrors_check':
            return await _on_mirrors_check(q, ctx)
        if q.data.startswith('router:mirror_apply:'):
            return await _on_mirror_apply(q, ctx, q.data[len('router:mirror_apply:'):])
        if q.data == 'router:restart_confirm':
            return await _do_restart_confirm(q, ctx)
        if q.data == 'router:reboot_confirm':
            return await _do_reboot_confirm(q, ctx)
        if q.data == 'router:modules':
            return await _on_modules_menu(q, ctx)
        if q.data.startswith('router:mod:t:'):
            return await _on_module_toggle(q, ctx, q.data[len('router:mod:t:'):])
        if q.data == 'router:mod:all':
            return await _on_module_bulk(q, ctx, 'all')
        if q.data == 'router:mod:none':
            return await _on_module_bulk(q, ctx, 'none')
        if q.data == 'router:mod:apply':
            return await _on_modules_apply(q, ctx)
        if q.data == 'router:mod:cancel':
            return await _on_modules_cancel(q, ctx)
        if q.data == 'router:main':
            # сбрасываем состояние всех модулей
            for mod in router.all():
                if hasattr(mod, 'on_leave'):
                    try:
                        await mod.on_leave()
                    except Exception as e:
                        log.warning('on_leave %s failed: %s', mod.name, e)
            return await _on_router_main(q, ctx)
        return await router.dispatch_callback(update, ctx)

    app.add_handler(CallbackQueryHandler(_global_callback))

    # --- авто-удаление сообщений пользователя ---
    from telegram.ext import MessageHandler as _MH, filters as _f
    async def _del_user_msg(update, ctx):
        try:
            if update.message:
                await ctx.bot.delete_message(
                    chat_id=update.effective_chat.id, 
                    message_id=update.message.message_id
                )
        except Exception as e:
            log.debug('auto-delete failed: %s', e)
            
    app.add_handler(_MH(_f.COMMAND, _del_user_msg), group=-101)
    app.add_handler(_MH(_f.TEXT & ~_f.COMMAND, _del_user_msg), group=-100)

    # --- авто-удаление сообщений пользователя (только текст и команды) ---
    from telegram.ext import MessageHandler as _MH, filters as _f

    async def _force_del_user_msg(update, ctx):
        if update.message:
            try:
                await ctx.bot.delete_message(
                    chat_id=update.effective_chat.id,
                    message_id=update.message.message_id
                )
            except Exception as e:
                import logging
                logging.getLogger(__name__).debug(
                    'force_del_user_msg failed: %s', e
                )
            try:
                await notify_cleanup(ctx.bot, update.effective_chat.id)
            except Exception:
                pass

    app.add_handler(_MH(_f.TEXT | _f.COMMAND, _force_del_user_msg), group=-999)

    log.info('Starting router bot...')
    app.run_polling(drop_pending_updates=True)
RB_CORE_MAIN_PY_EOF

echo "  → core/router.py"
cat > /opt/router_bot/core/router.py << 'RB_CORE_ROUTER_PY_EOF'
"""Реестр модулей и роутинг callback'ов по префиксу."""
import logging

log = logging.getLogger(__name__)

class ModuleRouter:
    def __init__(self):
        self._modules = {}
        self._order = []

    def register(self, module):
        if module.name in self._modules:
            log.warning('Module %s already registered, skip', module.name)
            return
        self._modules[module.name] = module
        self._order.append(module.name)
        log.info('Module registered: %s (%s)', module.name, module.title)

    def get(self, name):
        return self._modules.get(name)

    def all(self):
        return [self._modules[n] for n in self._order]

    def first(self):
        if not self._order:
            return None
        return self._modules[self._order[0]]

    async def dispatch_callback(self, update, ctx):
        """Callback с префиксом '<module>:...' идёт в модуль.
        Без префикса — в первый зарегистрированный (совместимость).
        Всегда ловит исключения и отвечает пользователю."""
        q = update.callback_query
        data = q.data or ''

        async def _safe_call(mod, action):
            try:
                return await mod.handle_callback(action, q, ctx)
            except Exception as e:
                log.exception('Module %s handle_callback(%r) failed: %s',
                              mod.name, action, e)
                try:
                    await q.answer(
                        f'❌ Ошибка: {type(e).__name__}',
                        show_alert=True,
                    )
                except Exception:
                    pass

        if ':' in data:
            prefix, rest = data.split(':', 1)
            mod = self._modules.get(prefix)
            if mod:
                return await _safe_call(mod, rest)
            # неизвестный префикс — в первый
            mod = self.first()
            if mod:
                return await _safe_call(mod, data)
        else:
            mod = self.first()
            if mod:
                return await _safe_call(mod, data)
RB_CORE_ROUTER_PY_EOF

echo "  → core/utils.py"
cat > /opt/router_bot/core/utils.py << 'RB_CORE_UTILS_PY_EOF'
"""Общие утилиты для всех модулей."""
import json
import os

def get_router_ip() -> str:
    """Локальный IP роутера (LAN)."""
    import subprocess
    import socket
    try:
        r = subprocess.run(
            ['sh', '-c', "ip -4 addr show br0 2>/dev/null | grep -oE 'inet [0-9.]+' | head -1 | awk '{print $2}'"],
            capture_output=True, text=True, timeout=3)
        ip = (r.stdout or '').strip()
        if ip and not ip.startswith('127.'):
            return ip
    except Exception:
        pass
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
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

def load_json(path: str, default):
    if not os.path.exists(path):
        return default
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default

def save_json(path: str, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)



# ================== Универсальное меню удаления ==================

import glob as _glob


def existing_targets(targets):
    """Фильтрует список UNINSTALL_TARGETS, оставляя только те,
    чьи paths реально существуют в системе."""
    result = []
    for t in targets:
        found = False
        for p in t.get('paths', []):
            try:
                if _glob.glob(p):
                    found = True
                    break
            except Exception:
                pass
        if found:
            result.append(t)
    return result


def sync_opts(targets, current_opts):
    """Синхронизирует состояние чекбоксов с актуальным списком
    таргетов (ключи, которых больше нет, отбрасываются; новые —
    включаются по умолчанию)."""
    new_opts = {}
    for t in targets:
        k = t['key']
        new_opts[k] = current_opts.get(k, True)
    return new_opts


def build_uninstall_menu(targets, opts, title, always_msg, prefix):
    """Возвращает (text, InlineKeyboardMarkup) для меню удаления.

    targets     — список уже отфильтрованных таргетов
    opts        — текущее состояние чекбоксов (dict)
    title       — 'Удаление BIRD'
    always_msg  — что удаляется всегда (HTML-строка)
    prefix      — 'bird', 'xkeen', ...
    """
    from telegram import InlineKeyboardButton, InlineKeyboardMarkup

    lines = [
        f'\U0001f5d1 <b>{title}</b>',
        '',
        always_msg,
        '',
    ]
    if not targets:
        lines.append('<i>Дополнительных остатков не найдено.</i>')
    else:
        lines.append('Найдено следующее — нажмите, чтобы переключить:')

    kb_rows = []
    for t in targets:
        k = t['key']
        mark = '\u2705' if opts.get(k, True) else '\u2b1c'
        kb_rows.append([InlineKeyboardButton(
            f'{mark} {t["desc"]}',
            callback_data=f'{prefix}:opt:{k}',
        )])

    kb_rows.append([InlineKeyboardButton(
        '\U0001f5d1 Удалить',
        callback_data=f'{prefix}:opt:go')])

    kb_rows.append([InlineKeyboardButton(
        '\u274c Отмена',
        callback_data=f'{prefix}:main')])

    return '\n'.join(lines), InlineKeyboardMarkup(kb_rows)


def collect_uninstall_cmd(targets, opts, base_cmd):
    """Собирает shell-команду из base_cmd + выбранных таргетов.
    Каждая команда обёрнута в echo, чтобы лог был читаемым."""
    parts = []
    if base_cmd:
        parts.append(f"echo '▸ Базовое удаление...' ; {base_cmd}")
    for t in targets:
        k = t['key']
        if opts.get(k, True):
            cmd = t.get('cmd', '')
            desc = t.get('desc', k)
            if cmd:
                safe_desc = desc.replace("'", "'\\''")
                parts.append(f"echo '' ; echo '▸ {safe_desc}' ; {cmd}")
    parts.append("echo '' ; echo 'Готово.'")
    return ' ; '.join(parts)


def toggle_opt(opts, key):
    """Инвертирует состояние чекбокса, возвращает новое значение."""
    opts[key] = not opts.get(key, True)
    return opts[key]



# ================== Скан остатков после удаления ==================

def scan_leftovers(patterns, search_paths=None, exclude=None):
    """Ищет файлы/каталоги по маскам в типичных местах.

    patterns      — список масок ('*bird*', '*xkeen*')
    search_paths  — список базовых каталогов (по умолчанию /opt/*)
    exclude       — список путей, которые надо игнорировать
                    (например, /opt/router_bot/modules/bird)
    """
    import glob as _g

    if search_paths is None:
        search_paths = [
            '/opt/bin', '/opt/sbin', '/opt/etc', '/opt/etc/init.d',
            '/opt/var/log', '/opt/var/run', '/opt/var/lib',
            '/opt/lib', '/opt/share',
        ]
    if exclude is None:
        exclude = ['/opt/router_bot']

    found = set()
    for base in search_paths:
        for pat in patterns:
            full = pat if pat.startswith('/') else f'{base}/{pat}'
            try:
                for p in _g.glob(full):
                    # исключаем наши собственные модули
                    if any(p.startswith(ex) for ex in exclude):
                        continue
                    found.add(p)
            except Exception:
                pass
    return sorted(found)


def build_leftovers_message(leftovers, prefix):
    """Возвращает (text, kb) для сообщения со списком остатков."""
    from telegram import InlineKeyboardButton, InlineKeyboardMarkup

    text = (
        f'\U0001f50d <b>Найдены остатки после удаления ({len(leftovers)}):</b>\n\n'
    )
    # Ограничим вывод первыми 30 элементами
    show = leftovers[:30]
    for p in show:
        text += f'  \u2022 <code>{p}</code>\n'
    if len(leftovers) > 30:
        text += f'  \u2026 и ещё {len(leftovers) - 30}\n'
    text += '\nУдалить их?'

    kb = InlineKeyboardMarkup([
        [InlineKeyboardButton(
            f'\U0001f5d1 Удалить все ({len(leftovers)})',
            callback_data=f'{prefix}:cleanup:all')],
        [InlineKeyboardButton(
            '\u2705 Оставить', callback_data=f'{prefix}:main')],
    ])
    return text, kb



# ================== Проверка зеркал Entware ==================

import subprocess as _sp
import time as _time

# ============================================================
#  Автоопределение архитектуры Entware + актуальные зеркала
# ============================================================

# Базовые URL зеркал (без /{arch}) — только живые на 2026-10
# Базовые URL зеркал (без /{arch}).
# Порядок = порядок проверки в install.sh и отображения в /mirrors.
# Мёртвые зеркала тоже включены — пользователь должен их видеть
# (check_mirrors() в реальном времени ставит ✅/❌).
MIRROR_BASES = [
    'http://bin.entware.net',
    'http://mirrors.nju.edu.cn/entware',
    'https://mirrors.bfsu.edu.cn/entware',
    'https://mirrors.cernet.edu.cn/entware',
    'https://mirror.vinet.io/entware',
]
# Псевдоним для совместимости с внутренним кодом
_MIRROR_BASES = MIRROR_BASES


def _valid_entware_arch(value):
    import re
    return bool(value and re.fullmatch(r'[A-Za-z0-9_.+-]+', value)
                and '-' in value and value != 'all')


def _configured_entware_urls():
    """Читает активные Entware src из opkg.conf без комментариев."""
    urls = []
    try:
        with open('/opt/etc/opkg.conf') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                parts = line.split()
                if len(parts) >= 3 and parts[0] in ('src/gz', 'src'):
                    urls.append((parts[1], parts[-1].rstrip('/')))
    except Exception:
        pass
    return urls


def _arch_from_url(url):
    parts = [p for p in url.rstrip('/').split('/') if p]
    if parts and parts[-1].lower() == 'keenetic':
        parts.pop()
    if parts and _valid_entware_arch(parts[-1]):
        return parts[-1]
    return ''


def detect_entware_arch() -> str:
    """Определяет архитектуру по активному Entware feed, затем по opkg."""
    for name, url in _configured_entware_urls():
        if name == 'entware':
            arch = _arch_from_url(url)
            if arch:
                return arch

    # opkg arch-теги не всегда совпадают с именами каталогов репозитория.
    # Используем только явно известные соответствия.
    mapping = {
        'aarch64-3.10': 'aarch64-k3.10',
        'aarch64-k3.10': 'aarch64-k3.10',
        'mipselsf-3.4': 'mipselsf-k3.4',
        'mipselsf-k3.4': 'mipselsf-k3.4',
        'mipssf-3.4': 'mipssf-k3.4',
        'mipssf-k3.4': 'mipssf-k3.4',
        'armv7sf-3.2': 'armv7sf-k3.2',
        'armv7sf-k3.2': 'armv7sf-k3.2',
        'x64-3.2': 'x64-k3.2',
        'x64-k3.2': 'x64-k3.2',
    }
    try:
        r = _sp.run(['opkg', 'print-architecture'], capture_output=True,
                    text=True, timeout=5)
        candidates = []
        for line in (r.stdout or '').splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[0] == 'arch':
                try:
                    priority = int(parts[2])
                except ValueError:
                    continue
                if parts[1] in mapping:
                    candidates.append((priority, mapping[parts[1]]))
        if candidates:
            return max(candidates)[1]
    except Exception:
        pass
    return ''


# Базовые URL зеркал без архитектуры. Для проверки к каждому добавляется
# архитектура, найденная в конфигурации конкретного роутера.
MIRROR_BASES = [
    'http://bin.entware.net',
    'http://mirrors.nju.edu.cn/entware',
    'https://mirrors.bfsu.edu.cn/entware',
    'https://mirrors.cernet.edu.cn/entware',
    'https://mirror.vinet.io/entware',
]
_MIRROR_BASES = MIRROR_BASES
OPKG_CONF = '/opt/etc/opkg.conf'


def get_entware_mirrors() -> list:
    arch = detect_entware_arch()
    if not arch:
        return []
    return [f'{base.rstrip("/")}/{arch}' for base in _MIRROR_BASES]


ENTWARE_MIRRORS = get_entware_mirrors()
_MIRROR_PROBE_FILES = ('Packages.gz', 'Packages', 'Packages.manifest')


def _probe_index(url, timeout=10):
    """Проверяет индекс пакетов и не считает редирект/пустой ответ успехом."""
    import gzip as _gzip
    import os as _os
    import shutil as _shutil
    import tempfile as _tempfile

    curl = _shutil.which('curl') or ('/opt/bin/curl' if _os.path.exists('/opt/bin/curl') else '')
    if not curl:
        return False, 'curl отсутствует', ''

    fd, path = _tempfile.mkstemp(prefix='rbmirror_')
    _os.close(fd)
    last_code, last_file = '000', ''
    try:
        # Проверяем корневой индекс и /keenetic: некоторые зеркала публикуют
        # Keenetic-специфичный feed отдельно.
        for suffix in ('', '/keenetic'):
            for fname in _MIRROR_PROBE_FILES:
                full_url = url.rstrip('/') + suffix + '/' + fname
                last_file = suffix + '/' + fname
                try:
                    r = _sp.run([
                        curl, '-4', '-sS', '-L', '--connect-timeout', '4',
                        '--max-time', str(timeout), '--max-filesize', '1048576',
                        '-r', '0-65535', '-A', 'RouterBot-mirror-check/3.0',
                        '-o', path, '-w', '%{http_code}', full_url
                    ], capture_output=True, text=True, timeout=timeout + 3)
                    last_code = (r.stdout or '').strip()[-3:] or '000'
                except Exception:
                    last_code = '000'
                    continue

                if last_code not in ('200', '206') or r.returncode != 0:
                    continue
                try:
                    with open(path, 'rb') as f:
                        head = f.read(65536)
                except Exception:
                    continue
                if not head or b'<html' in head[:2048].lower() or b'<!doctype html' in head[:2048].lower():
                    continue

                if head.startswith(b'\x1f\x8b'):
                    try:
                        with _gzip.open(path, 'rb') as gz:
                            sample = gz.read(4096)
                        if b'Package:' in sample or b'Filename:' in sample:
                            return True, last_code, last_file
                    except Exception:
                        # Диапазон может обрываться до конца gzip-потока.
                        # Если заголовок gzip корректный, читаем его через zlib
                        # в режиме raw-deflate и проверяем содержимое без trailer.
                        try:
                            import zlib
                            dec = zlib.decompressobj(16 + zlib.MAX_WBITS)
                            sample = dec.decompress(head, 16384)
                            if b'Package:' in sample or b'Filename:' in sample:
                                return True, last_code, last_file
                        except Exception:
                            pass
                elif b'Package:' in head or b'Filename:' in head:
                    return True, last_code, last_file
        return False, last_code or 'unreachable', last_file
    finally:
        try:
            _os.unlink(path)
        except Exception:
            pass


def _check_one_sync(url, timeout=10):
    start = _time.time()
    if not detect_entware_arch():
        return {'url': url, 'time': 0, 'ok': False,
                'code': 'архитектура не определена', 'file': ''}
    ok, code, fname = _probe_index(url, timeout)
    return {'url': url, 'time': round(_time.time() - start, 2),
            'ok': ok, 'code': code, 'file': fname}


async def check_mirrors():
    import asyncio as _a
    mirrors = get_entware_mirrors()
    if not mirrors:
        return [{'url': 'архитектура Entware не определена', 'time': 0,
                 'ok': False, 'code': 'проверьте /opt/etc/opkg.conf', 'file': ''}]
    tasks = [_a.to_thread(_check_one_sync, u) for u in mirrors]
    return await _a.gather(*tasks)


def get_current_mirror():
    import os as _os
    if not _os.path.exists(OPKG_CONF):
        return ''
    try:
        with open(OPKG_CONF) as f:
            for line in f:
                s = line.strip()
                if not s or s.startswith('#'):
                    continue
                parts = s.split()
                if len(parts) < 3 or parts[0] not in ('src/gz', 'src'):
                    continue
                url = parts[-1].rstrip('/')
                if parts[1] == 'entware':
                    arch = detect_entware_arch()
                    if arch and url.endswith('/' + arch + '/keenetic'):
                        return url[:-len('/keenetic')]
                    if arch and url.endswith('/' + arch):
                        return url
                    return url
    except Exception:
        pass
    return ''


def apply_mirror(new_base):
    """Меняет URL известных зеркал, сохраняя архитектуру и feed-суффиксы."""
    import os as _os
    if not _os.path.exists(OPKG_CONF):
        return False, 'opkg.conf не найден'
    arch = detect_entware_arch()
    if not arch:
        return False, 'Архитектура не определена; конфигурация не изменена'
    if not new_base.rstrip('/').endswith('/' + arch):
        return False, 'Зеркало не соответствует архитектуре ' + arch
    try:
        with open(OPKG_CONF) as f:
            lines = f.readlines()
    except Exception as e:
        return False, f'Ошибка чтения: {e}'

    changed = 0
    new_lines = []
    known = get_entware_mirrors()
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith('#'):
            parts = stripped.split()
            if len(parts) >= 3 and parts[0] in ('src/gz', 'src'):
                url = parts[-1].rstrip('/')
                for old in known:
                    if url == old or url.startswith(old + '/'):
                        replacement = new_base.rstrip('/') + url[len(old):]
                        pos = line.find(parts[-1])
                        if pos >= 0:
                            line = line[:pos] + replacement + line[pos + len(parts[-1]):]
                            changed += 1
                        break
        new_lines.append(line)

    if not changed:
        return False, 'В opkg.conf не найдены источники текущего зеркала'
    backup = OPKG_CONF + '.bak'
    try:
        shutil.copy2(OPKG_CONF, backup)
        tmp = OPKG_CONF + '.tmp'
        with open(tmp, 'w') as f:
            f.writelines(new_lines)
        _os.replace(tmp, OPKG_CONF)
        return True, f'Обновлено строк: {changed}; резервная копия: {backup}'
    except Exception as e:
        return False, f'Ошибка записи: {e}'


def _short_domain(url):
    """Возвращает домен без протокола и пути."""
    u = url.replace('http://', '').replace('https://', '')
    return u.split('/')[0]


def build_mirrors_text(results, current):
    """Формирует текст карточки со списком зеркал."""
    lines = ['\U0001f30d <b>Зеркала Entware</b>', '']
    try:
        _arch = detect_entware_arch()
        lines.append(f'Архитектура: <code>{_arch}</code>')
    except Exception:
        pass
    if current:
        lines.append(f'Текущее: <code>{current}</code>')
    lines.append('')
    lines.append('<b>Проверка отклика:</b>')
    for i, r in enumerate(results, 1):
        mark = '\u2705' if r['ok'] else '\u274c'
        t = f"{r['time']}с" if r['ok'] else r['code'][:20]
        name = _short_domain(r['url'])
        lines.append(f'{mark} {i}. <code>{name}</code> — {t}')
    return '\n'.join(lines)


def build_mirrors_kb(results):
    from telegram import InlineKeyboardButton, InlineKeyboardMarkup
    rows = []

    # Ищем самый быстрый
    best_idx = -1
    best_time = 999.0
    for i, r in enumerate(results):
        if r['ok'] and r['time'] < best_time:
            best_time = r['time']
            best_idx = i

    if best_idx >= 0:
        rows.append([InlineKeyboardButton(
            f'\U0001f680 Автовыбор ({best_time}с)',
            callback_data=f'router:mirror_apply:{best_idx}')])

    for i, r in enumerate(results):
        if r['ok']:
            name = _short_domain(r['url'])
            rows.append([InlineKeyboardButton(
                f'\U0001f4e6 {name}',
                callback_data=f'router:mirror_apply:{i}')])

    rows.append([InlineKeyboardButton(
        '\U0001f504 Проверить снова', callback_data='router:mirrors_check')])
    rows.append([InlineKeyboardButton(
        '\u2b05\ufe0f Назад', callback_data='router:main')])
    return InlineKeyboardMarkup(rows)



# ================== Универсальный edit-or-send ==================

async def ui_edit_or_send(bot, chat_id, message_id, text, kb=None,
                          parse_mode='HTML'):
    """Редактирует сообщение, если message_id задан и edit удался.
    Иначе шлёт новое. Возвращает message_id актуального сообщения.

    Использование:
        self._status_msg_id = await ui_edit_or_send(
            ctx.bot, self.chat_id, self._status_msg_id,
            text='⏳ Выполняется...', kb=kill_kb,
        )
    """
    import logging as _log
    _l = _log.getLogger(__name__)

    if message_id:
        try:
            await bot.edit_message_text(
                chat_id=chat_id, message_id=message_id,
                text=text, parse_mode=parse_mode, reply_markup=kb,
            )
            return message_id
        except Exception as e:
            err = str(e).lower()
            if 'not modified' in err:
                return message_id
            if 'message to edit not found' in err or 'message_id_invalid' in err:
                _l.debug('ui_edit_or_send: message gone, sending new')
            else:
                _l.debug('ui_edit_or_send: edit failed: %s', e)

    msg = await bot.send_message(
        chat_id=chat_id, text=text,
        parse_mode=parse_mode, reply_markup=kb,
    )
    return msg.message_id


async def ui_edit_q(q, text, kb=None, parse_mode='HTML'):
    """Edit через callback_query. Возвращает message_id или None.

    Использование:
        await ui_edit_q(q, '⏳ Выполняется...', kb=kill_kb)
    """
    try:
        await q.edit_message_text(text, parse_mode=parse_mode, reply_markup=kb)
        set_last_msg(q.message.chat_id, q.message.message_id)
        return q.message.message_id
    except Exception as e:
        if 'not modified' in str(e).lower():
            return q.message.message_id
        raise


# ================== Одно окно: last_msg + show_card ==================

import json as _json_lm
LAST_MSG_FILE = '/opt/router_bot/data/system/last_msg.json'

def _lm_load():
    try:
        with open(LAST_MSG_FILE) as f: return _json_lm.load(f)
    except Exception: return {}

def _lm_save(d):
    try:
        os.makedirs(os.path.dirname(LAST_MSG_FILE), exist_ok=True)
        with open(LAST_MSG_FILE, 'w') as f: _json_lm.dump(d, f)
    except Exception: pass

def set_last_msg(chat_id, msg_id):
    d = _lm_load()
    d[str(chat_id)] = int(msg_id)
    _lm_save(d)

def get_last_msg(chat_id):
    return _lm_load().get(str(chat_id))

async def show_card(update, ctx, text, kb=None, parse_mode='HTML'):
    """Удаляет сообщение пользователя; редактирует последнее сообщение бота
    (или отправляет новое, если предыдущего нет)."""
    import logging
    log = logging.getLogger(__name__)
    chat_id = update.effective_chat.id
    try:
        if update.message:
            await ctx.bot.delete_message(
                chat_id=chat_id, 
                message_id=update.message.message_id
            )
    except Exception as e:
        log.debug('show_card delete failed: %s', e)
        
    last_id = get_last_msg(chat_id)
    if last_id:
        try:
            await ctx.bot.edit_message_text(
                chat_id=chat_id, message_id=last_id,
                text=text, parse_mode=parse_mode, reply_markup=kb,
            )
            return last_id
        except Exception as e:
            if 'not modified' in str(e).lower():
                return last_id
    msg = await ctx.bot.send_message(
        chat_id=chat_id, text=text, parse_mode=parse_mode, reply_markup=kb,
    )
    set_last_msg(chat_id, msg.message_id)
    return msg.message_id


# ================== Уведомления Net Watch ==================

import time as _time_notif
NOTIF_FILE = '/opt/router_bot/data/net_watch/notifications.json'

def _notif_load():
    try:
        with open(NOTIF_FILE) as f:
            return _json_lm.load(f)
    except Exception:
        return {}

def _notif_save(data):
    try:
        os.makedirs(os.path.dirname(NOTIF_FILE), exist_ok=True)
        with open(NOTIF_FILE, 'w') as f:
            _json_lm.dump(data, f)
    except Exception:
        pass

def notify_register(chat_id, message_id):
    data = _notif_load()
    cid = str(chat_id)
    lst = data.setdefault(cid, [])
    lst.append({"id": int(message_id), "ts": int(_time_notif.time())})
    data[cid] = lst[-200:]
    _notif_save(data)

async def notify_cleanup(bot, chat_id=None, older_than_hours=None, exclude_msg_id=None):
    """Удаляет уведомления. Если exclude_msg_id задан — не трогает это сообщение."""
    data = _notif_load()
    now = int(_time_notif.time())
    cutoff = now - int(older_than_hours * 3600) if older_than_hours else None
    changed = False
    for cid in list(data.keys()):
        if chat_id is not None and str(chat_id) != cid:
            continue
        lst = data[cid]
        remaining = []
        for item in lst:
            msg_id = item.get('id')
            if exclude_msg_id and msg_id == exclude_msg_id:
                remaining.append(item)
                continue
            ts = item.get('ts', 0)
            if cutoff is not None and ts >= cutoff:
                remaining.append(item)
                continue
            try:
                await bot.delete_message(chat_id=int(cid), message_id=msg_id)
            except Exception:
                pass
        if len(remaining) != len(lst):
            changed = True
        if remaining:
            data[cid] = remaining
        else:
            del data[cid]
    if changed:
        _notif_save(data)
RB_CORE_UTILS_PY_EOF

echo "  → core/rb"
cat > /opt/router_bot/core/rb << 'RB_CORE_RB_EOF'
#!/bin/sh
# rb — Router Bot helper. Управление ботом из терминала.
# Установлен в /opt/bin/rb. Исходник: /opt/router_bot/core/rb

BOT_DIR=/opt/router_bot
S98=/opt/etc/init.d/S98routerbot
S97=/opt/etc/init.d/S97tgroutes
S99=/opt/etc/init.d/S99routerbot_health
LOG=/opt/var/log/router_bot.log
CONF=$BOT_DIR/config.env
VER_FILE=$BOT_DIR/VERSION
PIDFILE=/var/run/routerbot.pid
GIVEUP=/var/run/routerbot.giveup

show_help() {
    cat << 'EOF'

  Router Bot — управление из терминала

  Использование:  rb <команда> [аргументы]

  ── Сервис ─────────────────────────────────────────
    start, s         Запустить бота
    stop, x          Остановить бота
    restart, r       Перезапустить
    reset            Сбросить giveup-маркер (после 10 падений)
    status, st       Статус: процессы, порт, giveup

  ── Диагностика ────────────────────────────────────
    logs [N]         Последние N строк лога (по умолч. 40)
    follow, f        Лог в реальном времени (Ctrl+C — выход)
    version, v       Версия бота
    ipv6 [on|off]    Вкл/выкл IPv6 (off = только IPv4)
    tgtest           Диагностика сети Telegram
    config, c        Конфиг: показать/править/восстановить
    modules, m       Включённые модули
    routes           Маршруты Telegram (table 16385)
    health           Запустить healthcheck
    rebuild          Перестроить маршруты Telegram
    procs            Дерево процессов бота

  ── Обслуживание ───────────────────────────────────
    update, u        Обновить из setup-файла
    uninstall        Подсказка по удалению

  ── Справка ────────────────────────────────────────
    -h, --help, help      Показать эту справку
    (без аргументов)      То же самое

  Примеры:
    rb               # эта справка
    rb st            # статус
    rb logs 100      # последние 100 строк лога
    rb r             # перезапуск
    rb v             # версия
    rb config        # показать config.env
    rb config init   # создать заново (с подтверждением)
    rb config tun    # перенастроить туннель к TG
    rb config edit   # править конфиг
    rb config check  # проверить обязательные ключи
EOF
    echo ""
}

do_status() {
    echo ""
    echo "  Router Bot — статус"
    echo "  ────────────────────────────────────────"

    if [ -f "$VER_FILE" ]; then
        echo "  Версия:      $(cat $VER_FILE 2>/dev/null)"
    else
        echo "  Версия:      (VERSION-файл отсутствует)"
    fi

    if [ -f "$GIVEUP" ]; then
        echo "  Состояние:   ❌ GIVEUP (10 падений подряд)"
        echo "  Сброс:       rb reset"
    else
        if [ -f "$PIDFILE" ] && kill -0 "$(cat $PIDFILE 2>/dev/null)" 2>/dev/null; then
            echo "  Состояние:   🟢 работает (PID $(cat $PIDFILE))"
        else
            echo "  Состояние:   🔴 остановлен"
        fi
    fi

    echo "  Процессы:"
    P=$(ps w 2>/dev/null | grep -E "routerbot_wrapper|router_bot/main.py" | grep -v grep)
    if [ -n "$P" ]; then
        echo "$P" | sed 's/^/    /'
    else
        echo "    (нет)"
    fi

    echo "  Telegram-маршруты:"
    R=$(ip rule show 2>/dev/null | grep 16385)
    if [ -n "$R" ]; then
        echo "$R" | sed 's/^/    /'
    else
        echo "    (нет — table 16385 пуст)"
    fi

    echo "  Лог:         $LOG"
    echo "  Конфиг:      $CONF"
    echo ""
}


_rb_ci_ask() {
    # Задаёт вопрос. Возвращает:
    #   0 — введено (значение в _RB_CI_VAL)
    #   1 — отмена (q/quit/Ctrl+C/EOF)
    _prompt="$1"
    _def="$2"
    if [ -n "$_def" ]; then
        printf "%s [%s]: " "$_prompt" "$_def"
    else
        printf "%s: " "$_prompt"
    fi
    if ! IFS= read -r _RB_CI_VAL; then
        echo
        return 1
    fi
    _RB_CI_VAL=$(printf '%s' "$_RB_CI_VAL" | tr -d '\r')
    case "$_RB_CI_VAL" in
        q|Q|quit|QUIT|exit|EXIT|отмена|Отмена|ОТМЕНА)
            return 1
            ;;
        "")
            _RB_CI_VAL="$_def"
            ;;
    esac
    return 0
}

do_config_init() {
    _abort() {
        echo ""
        echo "  ⏹  Отменено — config.env не изменён"
        return 1
    }

    if [ -f "$CONF" ]; then
        echo ""
        echo "  ⚠️  config.env уже существует: $CONF"
        echo "  Он будет перезаписан. Текущий сохранится как .broken.<timestamp>"
        echo ""
        printf "  Продолжить? (y/N): "
        read _r
        _r=$(printf "%s" "$_r" | tr -cd '\040-\176')
        case "$_r" in
            y|Y) ;;
            *) echo ""; echo "  ⏹  Отменено — config.env не изменён"; return 1 ;;
        esac
    fi

    echo ""
    echo "  ════════════════════════════════════════"
    echo "  Создание config.env (визард)"
    echo "  ════════════════════════════════════════"
    echo "  Отмена на любом шаге:"
    echo "    q <Enter>   — прервать (ничего не изменится)"
    echo "    Ctrl+C      — прервать"
    echo ""

    # --- 1. Токен ---
    _ci_token=""
    _attempt=0
    while [ -z "$_ci_token" ]; do
        _attempt=$((_attempt+1))
        if [ "$_attempt" -gt 5 ]; then
            echo "  Слишком много попыток, отмена"
            return 1
        fi
        if ! _rb_ci_ask "  Токен бота (от @BotFather)" ""; then
            _abort; return 1
        fi
        if [ -z "$_RB_CI_VAL" ]; then
            echo "  ❌ Пусто, попробуйте ещё"
            continue
        fi
        printf "  Проверяю токен... "
        _res=$(TG_TOKEN="$_RB_CI_VAL" /opt/bin/python3 - << 'PYEOF' 2>/dev/null
import os, json, urllib.request, urllib.error
tok = os.environ.get("TG_TOKEN", "")
try:
    r = urllib.request.urlopen(f"https://api.telegram.org/bot{tok}/getMe", timeout=10)
    d = json.loads(r.read())
    print("OK:" + d["result"].get("username", "") if d.get("ok") else "FAIL_OTHER:bad")
except urllib.error.HTTPError as e:
    print(f"FAIL_TOKEN:HTTP {e.code}")
except urllib.error.URLError as e:
    print(f"FAIL_NET:{e.reason}")
except Exception as e:
    print(f"FAIL_OTHER:{type(e).__name__}")
PYEOF
)
        case "$_res" in
            OK:*)
                echo "✅ @${_res#OK:}"
                _ci_token="$_RB_CI_VAL"
                ;;
            FAIL_TOKEN:*)
                echo "❌ неверный токен: ${_res#FAIL_TOKEN:}"
                ;;
            FAIL_NET:*)
                echo "⚠️  сеть: ${_res#FAIL_NET:}"
                echo "     токен НЕ проверен"
                printf "     Использовать всё равно? (y/N): "
                read _r
                case "$_r" in y|Y) _ci_token="$_RB_CI_VAL" ;; esac
                ;;
            *)
                echo "❌ $_res"
                ;;
        esac
    done

    # --- 2. Chat ID ---
    _ci_chat=""
    _attempt=0
    while [ -z "$_ci_chat" ]; do
        _attempt=$((_attempt+1))
        if [ "$_attempt" -gt 5 ]; then
            echo "  Слишком много попыток, отмена"
            return 1
        fi
        if ! _rb_ci_ask "  Chat ID (узнать у @userinfobot)" ""; then
            _abort; return 1
        fi
        if [ -z "$_RB_CI_VAL" ]; then
            echo "  ❌ Пусто, попробуйте ещё"
            continue
        fi
        printf "  Отправляю тестовое сообщение... "
        _res=$(TG_TOKEN="$_ci_token" TG_CHAT="$_RB_CI_VAL" /opt/bin/python3 - << 'PYEOF' 2>/dev/null
import os, json, urllib.request, urllib.parse, urllib.error
tok = os.environ["TG_TOKEN"]
chat = os.environ["TG_CHAT"]
try:
    data = urllib.parse.urlencode({"chat_id": chat, "text": "Router Bot: проверка chat_id"}).encode()
    r = urllib.request.urlopen(f"https://api.telegram.org/bot{tok}/sendMessage", data=data, timeout=10)
    d = json.loads(r.read())
    print("OK" if d.get("ok") else "FAIL_OTHER:not ok")
except urllib.error.HTTPError as e:
    print(f"FAIL_CHAT:HTTP {e.code}")
except urllib.error.URLError as e:
    print(f"FAIL_NET:{e.reason}")
except Exception as e:
    print(f"FAIL_OTHER:{type(e).__name__}")
PYEOF
)
        case "$_res" in
            OK)
                echo "✅ доставлено"
                _ci_chat="$_RB_CI_VAL"
                ;;
            FAIL_CHAT:*)
                echo "❌ chat_id неверен: ${_res#FAIL_CHAT:}"
                ;;
            FAIL_NET:*)
                echo "⚠️  сеть: ${_res#FAIL_NET:}"
                printf "     Использовать всё равно? (y/N): "
                read _r
                case "$_r" in y|Y) _ci_chat="$_RB_CI_VAL" ;; esac
                ;;
            *)
                echo "❌ $_res"
                ;;
        esac
    done

    # --- 3. Модули ---
    _all_mods="net_watch,ssh_control,system,hydraroute,flashkeen,xkeen,bird,mtproxy,keen_pbr,neofit,usque_keenetic,awg_manager"
    echo ""
    echo "  Доступные модули:"
    echo "    net_watch ssh_control system hydraroute flashkeen xkeen"
    echo "    bird mtproxy keen_pbr neofit usque_keenetic"
    if ! _rb_ci_ask "  Модули (через запятую, Enter = все)" "$_all_mods"; then
        _abort; return 1
    fi
    _ci_mods="$_RB_CI_VAL"

    # --- 4. POLL_INTERVAL ---
    if ! _rb_ci_ask "  Интервал опроса ndmc, сек" "5"; then
        _abort; return 1
    fi
    _ci_poll="$_RB_CI_VAL"
    case "$_ci_poll" in
        ''|*[!0-9]*) _ci_poll=5 ;;
    esac

    # --- 5. HEARTBEAT_INTERVAL ---
    if ! _rb_ci_ask "  Heartbeat, сек (0 = выкл)" "3600"; then
        _abort; return 1
    fi
    _ci_hb="$_RB_CI_VAL"
    case "$_ci_hb" in
        ''|*[!0-9]*) _ci_hb=3600 ;;
    esac

    # --- 6. VENDOR_LOOKUP ---
    if ! _rb_ci_ask "  Искать вендора по MAC (on/off)" "on"; then
        _abort; return 1
    fi
    _ci_vendor="$_RB_CI_VAL"
    case "$_ci_vendor" in
        on|ON|On|off|OFF|Off) ;;
        *) _ci_vendor=on ;;
    esac

    # --- 7. Автоопределение сети ---
    echo ""
    echo "  Определяю параметры сети..."
    _ci_wan_if=$(ip route show default 2>/dev/null | awk '{
        for(i=1;i<=NF;i++) if ($i=="dev") iface=$(i+1);
        if (iface !~ /^(opkgtun|tun|wg|tap|ppp)/) { print iface; exit }
    }')
    [ -z "$_ci_wan_if" ] && _ci_wan_if="eth3"
    _ci_wan_src=$(ip -4 -o addr show dev "$_ci_wan_if" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    _ci_route_table=$(ip rule show 2>/dev/null | awk -v src="$_ci_wan_src" '
        $0 ~ "from " src " " { for(i=1;i<=NF;i++) if($i=="lookup") { print $(i+1); exit } }')
    [ -z "$_ci_route_table" ] && _ci_route_table="16385"
    echo "    WAN: $_ci_wan_if ($_ci_wan_src) → table $_ci_route_table"

    # --- 8. VPN ---
    _ci_use_vpn="no"
    _ci_vpn_if=""
    _ci_vpn_src=""
    printf "  Проверяю Telegram напрямую... "
    if /opt/bin/curl -sf --max-time 6 "https://api.telegram.org" >/dev/null 2>&1; then
        echo "✅ доступен, VPN не нужен"
    else
        echo "❌ недоступен"
        printf "  Настроить VPN? (y/N): "
        read _r
        case "$_r" in
            y|Y)
                _tuns=$(ip -o link show 2>/dev/null | sed 's/@[^ :]*//g' | \
                    awk -F': ' '$2 ~ /^(opkgtun[0-9]+|nwg[0-9]+|wg[0-9]+|tap[0-9]+)$/ { print $2 }')
                if [ -z "$_tuns" ]; then
                    echo "  Туннели не найдены — VPN не настроен"
                else
                    _n=0
                    _tuns_list=""
                    for _t in $_tuns; do
                        _n=$((_n+1))
                        _tuns_list="$_tuns_list $_t"
                        _tip=$(ip -4 -o addr show dev "$_t" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
                        if ip -o link show dev "$_t" 2>/dev/null | grep -q '<[^>]*UP[^>]*>'; then
                            echo "    $_n) $_t  ${_tip:-no-IP}  [UP]"
                        else
                            echo "    $_n) $_t  ${_tip:-no-IP}  [DOWN]"
                        fi
                    done
                    if ! _rb_ci_ask "  Номер туннеля" "1"; then
                        _abort; return 1
                    fi
                    _sel="$_RB_CI_VAL"
                    case "$_sel" in
                        ''|*[!0-9]*)
                            _ci_vpn_if=$(echo "$_tuns_list" | awk '{print $1}')
                            ;;
                        *)
                            if [ "$_sel" -ge 1 ] && [ "$_sel" -le "$_n" ]; then
                                _ci_vpn_if=$(echo "$_tuns_list" | awk -v n="$_sel" '{print $n}')
                            else
                                _ci_vpn_if=$(echo "$_tuns_list" | awk '{print $1}')
                            fi
                            ;;
                    esac
                    if [ -n "$_ci_vpn_if" ]; then
                        _ci_vpn_src=$(ip -4 -o addr show dev "$_ci_vpn_if" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
                        _ci_use_vpn="yes"
                        echo "  Выбран: $_ci_vpn_if ($_ci_vpn_src)"
                    fi
                fi
                ;;
        esac
    fi

    # --- Сводка ---
    echo ""
    echo "  ════════════════════════════════════════"
    echo "  Сводка — что будет записано"
    echo "  ════════════════════════════════════════"
    case "$_ci_token" in
        *:*) _masked="${_ci_token%%:*}:... (${#_ci_token} символов)" ;;
        *)   _masked="... (${#_ci_token} символов)" ;;
    esac
    echo "  TG_BOT_TOKEN:        $_masked"
    echo "  TG_CHAT_ID:          $_ci_chat"
    echo "  ENABLED_MODULES:     $_ci_mods"
    echo "  POLL_INTERVAL:       $_ci_poll"
    echo "  HEARTBEAT_INTERVAL:  $_ci_hb"
    echo "  VENDOR_LOOKUP:       $_ci_vendor"
    echo "  WAN_IF / WAN_SRC:    $_ci_wan_if / $_ci_wan_src"
    echo "  ROUTE_TABLE:         $_ci_route_table"
    if [ "$_ci_use_vpn" = "yes" ]; then
        echo "  VPN:                 $_ci_vpn_if ($_ci_vpn_src)"
    else
        echo "  VPN:                 не используется"
    fi
    echo ""
    printf "  ❓ Применить и записать config.env? (y/N): "
    read _r
    case "$_r" in
        y|Y) ;;
        *) echo "  Отменено — config.env не изменён"; return 1 ;;
    esac

    # --- Запись ---
    mkdir -p "$(dirname "$CONF")"
    if [ -f "$CONF" ]; then
        _ts=$(date +%s)
        cp -p "$CONF" "${CONF}.broken.${_ts}"
        chmod 600 "${CONF}.broken.${_ts}" 2>/dev/null
        echo "  Старый конфиг сохранён: config.env.broken.${_ts}"
    fi

    {
        echo "# Router Bot — конфиг"
        echo "# Создан $(date '+%Y-%m-%d %H:%M:%S') через rb config init"
        echo ""
        echo "TG_BOT_TOKEN='$_ci_token'"
        echo "TG_CHAT_ID='$_ci_chat'"
        echo ""
        echo "ENABLED_MODULES='$_ci_mods'"
        echo ""
        echo "POLL_INTERVAL=$_ci_poll"
        echo "HEARTBEAT_INTERVAL=$_ci_hb"
        echo "VENDOR_LOOKUP=$_ci_vendor"
        echo "NDMC_PATH=/bin/ndmc"
        echo ""
        echo "WAN_IF='$_ci_wan_if'"
        echo "WAN_SRC='$_ci_wan_src'"
        echo "ROUTE_TABLE='$_ci_route_table'"
        echo ""
        echo "USE_VPN='$_ci_use_vpn'"
        echo "VPN_IF='$_ci_vpn_if'"
        echo "VPN_SRC='$_ci_vpn_src'"
    } > "$CONF"
    chmod 600 "$CONF"
    cp -p "$CONF" "${CONF}.bak"
    chmod 600 "${CONF}.bak"

    echo ""
    echo "  ✅ config.env создан: $CONF"
    echo "  ✅ Бэкап:              ${CONF}.bak"
    echo ""
    if [ "$_ci_use_vpn" = "yes" ] && [ -x /opt/etc/init.d/S97tgroutes ]; then
        echo "  → Перестраиваю маршруты Telegram через $_ci_vpn_if..."
        /opt/etc/init.d/S97tgroutes rebuild >/dev/null 2>&1 || true
        echo "  ✅ Готово"
        echo ""
    fi
    echo "  → Перезапустить бота: rb restart"
    return 0
}

do_config_tun() {
    # Перенастройка туннеля к api.telegram.org
    _abort() {
        echo ""
        echo "  ⏹  Отменено — настройки туннеля не изменены"
        return 1
    }

    echo ""
    echo "  ════════════════════════════════════════════"
    echo "  Перенастройка туннеля к api.telegram.org"
    echo "  ════════════════════════════════════════════"
    echo ""

    # Текущее состояние
    _cur_vpn_if=$(sed -n "s/^VPN_IF='\(.*\)'/\1/p" "$CONF" 2>/dev/null)
    _cur_vpn_src=$(sed -n "s/^VPN_SRC='\(.*\)'/\1/p" "$CONF" 2>/dev/null)
    _cur_use_vpn=$(sed -n "s/^USE_VPN='\(.*\)'/\1/p" "$CONF" 2>/dev/null)
    _cur_route_table=$(sed -n "s/^ROUTE_TABLE='\(.*\)'/\1/p" "$CONF" 2>/dev/null)
    [ -z "$_cur_route_table" ] && _cur_route_table="16385"

    if [ "$_cur_use_vpn" = "yes" ] && [ -n "$_cur_vpn_if" ]; then
        echo "  Текущий туннель: $_cur_vpn_if ($_cur_vpn_src)"
        echo "  Таблица маршрутов: $_cur_route_table"
    else
        echo "  Туннель не используется (USE_VPN=no)"
    fi
    echo ""

    printf "  Перенастроить туннель? (y/N): "
    read _r
    _r=$(printf "%s" "$_r" | tr -cd '\040-\176')
    case "$_r" in
        y|Y) ;;
        *) _abort; return 1 ;;
    esac

    # --- Список туннелей ---
    echo ""
    echo "  Сканирую туннели..."
    _tuns=$(ip -o link show 2>/dev/null | sed 's/@[^ :]*//g' | \
        awk -F': ' '$2 ~ /^(opkgtun[0-9]+|nwg[0-9]+|wg[0-9]+|tap[0-9]+)$/ { print $2 }')

    if [ -z "$_tuns" ]; then
        echo "  ⚠️  Туннели не найдены"
        echo "  Проверьте: ip -o link show"
        return 1
    fi

    _all_tuns=""
    _n=0
    _first_up=""
    for _t in $_tuns; do
        if ip -o link show dev "$_t" 2>/dev/null | grep -q '<[^>]*UP[^>]*>'; then
            _n=$((_n+1))
            _all_tuns="$_all_tuns $_t"
            [ -z "$_first_up" ] && _first_up="$_t"
            _tip=$(ip -4 -o addr show dev "$_t" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
            _mark=""
            [ "$_t" = "$_cur_vpn_if" ] && _mark=" ← текущий"
            echo "    $_n) $_t  ${_tip:-no-IP}  [UP]$_mark"
        fi
    done
    for _t in $_tuns; do
        if ! ip -o link show dev "$_t" 2>/dev/null | grep -q '<[^>]*UP[^>]*>'; then
            _n=$((_n+1))
            _all_tuns="$_all_tuns $_t"
            _tip=$(ip -4 -o addr show dev "$_t" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
            echo "    $_n) $_t  ${_tip:-no-IP}  [DOWN]"
        fi
    done
    echo ""

    _new_vpn_if=""
    if [ "$_n" -eq 1 ]; then
        _new_vpn_if=$(echo "$_all_tuns" | awk '{print $1}')
        echo "  Единственный туннель: $_new_vpn_if"
    else
        while true; do
            if [ -n "$_first_up" ]; then
                printf "  Номер туннеля [1-%d] (Enter = %s, q = отмена): " "$_n" "$_first_up"
            else
                printf "  Номер туннеля [1-%d] (q = отмена): " "$_n"
            fi
            read _ANS
            _ANS=$(printf "%s" "$_ANS" | tr -d "[:space:]")

            case "$_ANS" in
                q|Q) _abort; return 1 ;;
            esac

            if [ -z "$_ANS" ]; then
                if [ -n "$_first_up" ]; then
                    _new_vpn_if="$_first_up"
                    break
                else
                    echo "  Введите номер вручную"
                    continue
                fi
            fi

            case "$_ANS" in
                *[!0-9]*) echo "  Ошибка: число от 1 до $_n"; continue ;;
            esac

            if [ "$_ANS" -ge 1 ] && [ "$_ANS" -le "$_n" ]; then
                _new_vpn_if=$(echo "$_all_tuns" | awk -v n="$_ANS" '{print $n}')
                [ -n "$_new_vpn_if" ] && break
            else
                echo "  Ошибка: число от 1 до $_n"
            fi
        done
    fi

    # Предупреждение, если DOWN
    if ! ip -o link show dev "$_new_vpn_if" 2>/dev/null | grep -q '<[^>]*UP[^>]*>'; then
        echo "  ⚠️  Туннель $_new_vpn_if в состоянии DOWN"
        printf "  Продолжить с ним? (y/N): "
        read _c
        _c=$(printf "%s" "$_c" | tr -cd '\040-\176')
        if [ "$_c" != "y" ] && [ "$_c" != "Y" ]; then
            _abort; return 1
        fi
    fi

    _new_vpn_src=$(ip -4 -o addr show dev "$_new_vpn_if" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    if [ -z "$_new_vpn_src" ]; then
        printf "  Введите IP туннеля %s: " "$_new_vpn_if"
        read _new_vpn_src
        _new_vpn_src=$(printf "%s" "$_new_vpn_src" | tr -cd '\040-\176')
        if [ -z "$_new_vpn_src" ]; then
            _abort; return 1
        fi
    fi

    # --- Проверка доступа ---
    echo ""
    echo "  Проверяю доступ к api.telegram.org через $_new_vpn_if ($_new_vpn_src)..."
    # Временно добавим маршруты
    for _net in 149.154.160.0/20 91.108.4.0/22; do
        ip route add "$_net" dev "$_new_vpn_if" src "$_new_vpn_src" table "$_cur_route_table" 2>/dev/null || true
    done
    ip rule add to 149.154.160.0/20 lookup "$_cur_route_table" priority 1100 2>/dev/null || true
    ip rule add to 91.108.4.0/22 lookup "$_cur_route_table" priority 1101 2>/dev/null || true

    _CURL_OK=no
    if /opt/bin/curl -sf --max-time 8 "https://api.telegram.org" >/dev/null 2>&1; then
        _CURL_OK=yes
    fi

    if [ "$_CURL_OK" != "yes" ]; then
        echo "  ❌ Через $_new_vpn_if доступа нет"
        printf "  Сохранить выбор всё равно? (y/N): "
        read _c
        _c=$(printf "%s" "$_c" | tr -cd '\040-\176')
        if [ "$_c" != "y" ] && [ "$_c" != "Y" ]; then
            _abort; return 1
        fi
    else
        echo "  ✅ Доступ есть"
    fi

    # --- Запись ---
    if [ ! -f "$CONF" ]; then
        echo "  ❌ config.env не найден"
        return 1
    fi
    _ts=$(date +%s)
    \cp -f -p "$CONF" "${CONF}.broken.${_ts}" 2>/dev/null || true

    sed -i "s|^VPN_IF=.*|VPN_IF='$_new_vpn_if'|" "$CONF"
    sed -i "s|^VPN_SRC=.*|VPN_SRC='$_new_vpn_src'|" "$CONF"
    sed -i "s|^USE_VPN=.*|USE_VPN='yes'|" "$CONF"

    # Обновить .bak
    \cp -f -p "$CONF" "${CONF}.bak" 2>/dev/null || true

    echo ""
    echo "  ✅ config.env обновлён:"
    echo "     VPN_IF   = $_new_vpn_if"
    echo "     VPN_SRC  = $_new_vpn_src"
    echo "     USE_VPN  = yes"
    echo ""

    # --- S97 rebuild ---
    if [ -x "$S97" ]; then
        echo "  → Применяю маршруты (S97tgroutes rebuild)..."
        $S97 rebuild >/dev/null 2>&1 && echo "  ✅ Маршруты применены" || \
            echo "  ⚠️  S97tgroutes rebuild вернул ошибку"
    else
        echo "  ⚠️  $S97 не найден — маршруты не применены"
    fi

    echo ""
    echo "  → Перезапустить бота: rb restart"
    return 0
}

do_config() {
    _sub="${1:-show}"
    _key="$2"
    _val="$3"
    _bak="${CONF}.bak"

    case "$_sub" in
        show|"")
            if [ -f "$CONF" ]; then
                echo ""
                echo "  === $CONF ==="
                cat "$CONF"
                echo ""
                if [ -f "$_bak" ] && [ "$CONF" -nt "$_bak" ]; then
                    echo "  ⚠️  config.env новее бэкапа (rb config backup чтобы обновить)"
                fi
            elif [ -f "$_bak" ]; then
                echo ""
                echo "  ❌ config.env отсутствует!"
                echo "  ✅ есть резервная копия: $_bak"
                echo ""
                echo "  Восстановить: rb config restore"
            else
                echo ""
                echo "  ❌ config.env отсутствует, резервной копии нет"
                echo "     Переустановите бот: sh /tmp/router_bot_setup.sh"
                return 1
            fi
            ;;

        edit|e)
            if [ ! -f "$CONF" ]; then
                echo "❌ config.env не найден. Сначала: rb config restore"
                return 1
            fi
            _ed="${EDITOR:-nano}"
            command -v "$_ed" >/dev/null 2>&1 || _ed="vi"
            if [ "$_ed" = "vi" ] && ! command -v vi >/dev/null 2>&1; then
                echo "❌ Редактор не найден (ни nano, ни vi)"
                return 1
            fi
            "$_ed" "$CONF"
            cp -p "$CONF" "$_bak"
            chmod 600 "$CONF" "$_bak" 2>/dev/null || true
            echo ""
            echo "✅ Изменения сохранены, бэкап обновлён"
            echo "   Перезапустить бота: rb restart"
            ;;

        restore|r)
            if [ ! -f "$_bak" ]; then
                echo "❌ Резервная копия $_bak отсутствует — восстанавливать нечего"
                echo "   Переустановите бот: sh /tmp/router_bot_setup.sh"
                return 1
            fi
            if [ -f "$CONF" ]; then
                _ts=$(date +%s)
                cp -p "$CONF" "${CONF}.broken.${_ts}"
                chmod 600 "${CONF}.broken.${_ts}" 2>/dev/null || true
                echo "⚠️  Текущий файл сохранён: config.env.broken.${_ts}"
            fi
            cp -p "$_bak" "$CONF"
            chmod 600 "$CONF"
            echo "✅ config.env восстановлен из бэкапа"
            echo "   Перезапустить бота: rb restart"
            ;;

        backup|b)
            if [ ! -f "$CONF" ]; then
                echo "❌ config.env отсутствует — бэкапить нечего"
                return 1
            fi
            cp -p "$CONF" "$_bak"
            chmod 600 "$_bak" 2>/dev/null || true
            echo "✅ Бэкап обновлён: $_bak"
            ;;

        init|new|create)
            do_config_init
            return $?
            ;;

        tun|tunnel)
            do_config_tun
            return $?
            ;;

        check|chk)
            if [ ! -f "$CONF" ]; then
                echo "❌ config.env отсутствует"
                if [ -f "$_bak" ]; then
                    echo "   Восстановить: rb config restore"
                fi
                return 1
            fi
            echo ""
            echo "  → Проверка ключей в $CONF"
            _err=0
            for _k in TG_BOT_TOKEN TG_CHAT_ID ENABLED_MODULES; do
                if grep -q "^${_k}=" "$CONF"; then
                    _v=$(sed -n "s/^${_k}='\(.*\)'/\1/p" "$CONF" | head -1)
                    [ -z "$_v" ] && _v=$(sed -n "s/^${_k}=\(.*\)/\1/p" "$CONF" | head -1)
                    if [ -z "$_v" ]; then
                        echo "  ❌ $_k: пустой"
                        _err=$((_err+1))
                    else
                        case "$_k" in
                            TG_BOT_TOKEN)
                                echo "  ✅ $_k: ${_v%:*}:... (${#_v} символов)"
                                ;;
                            *)
                                echo "  ✅ $_k: $_v"
                                ;;
                        esac
                    fi
                else
                    echo "  ❌ $_k: отсутствует"
                    _err=$((_err+1))
                fi
            done
            echo ""
            if [ "$_err" -eq 0 ]; then
                echo "  ✅ Все обязательные ключи на месте"
            else
                echo "  ❌ Ошибок: $_err"
                return 1
            fi
            ;;

        get|show-key)
            if [ -z "$_key" ]; then
                echo "Использование: rb config get KEY"
                echo "Пример: rb config get TG_CHAT_ID"
                return 1
            fi
            if [ ! -f "$CONF" ]; then
                echo "❌ config.env отсутствует"
                return 1
            fi
            sed -n "s/^${_key}='\(.*\)'/\1/p" "$CONF" | head -1
            ;;

        set)
            if [ -z "$_key" ] || [ -z "$_val" ]; then
                echo "Использование: rb config set KEY VALUE"
                echo "Пример: rb config set POLL_INTERVAL 10"
                return 1
            fi
            if [ ! -f "$CONF" ]; then
                echo "❌ config.env отсутствует. Сначала: rb config restore"
                return 1
            fi
            if grep -q "^${_key}=" "$CONF"; then
                sed -i "s|^${_key}=.*|${_key}='${_val}'|" "$CONF"
                echo "✅ $_key = $_val"
            else
                printf "\n%s='%s'\n" "$_key" "$_val" >> "$CONF"
                echo "✅ $_key = $_val (добавлен)"
            fi
            cp -p "$CONF" "$_bak"
            chmod 600 "$CONF" "$_bak" 2>/dev/null || true
            echo "   Бэкап обновлён. Перезапустить бота: rb restart"
            ;;

        *)
            echo "Неизвестная подкоманда: $_sub"
            echo ""
            echo "  rb config [show]            показать конфиг"
            echo "  rb config init              создать заново (визард)"
            echo "  rb config tun               перенастроить туннель TG"
            echo "  rb config edit              редактировать"
            echo "  rb config restore           восстановить из .bak"
            echo "  rb config backup            обновить .bak"
            echo "  rb config check             проверить ключи"
            echo "  rb config get KEY           показать значение"
            echo "  rb config set KEY VALUE     изменить ключ"
            return 1
            ;;
    esac
}

do_modules() {
    echo ""
    if [ -f "$CONF" ]; then
        . "$CONF"
        echo "  Включённые модули (ENABLED_MODULES):"
        echo "    $ENABLED_MODULES"
        echo ""
        echo "  Всего модулей в проекте: 12"
        echo "    net_watch, ssh_control, system, hydraroute, flashkeen,"
        echo "    xkeen, bird, mtproxy, keen_pbr, neofit, usque_keenetic,"
        echo "    awg_manager"
    else
        echo "config.env не найден"
    fi
    echo ""
}

do_routes() {
    echo ""
    echo "  === ip rule (table 16385) ==="
    ip rule show 2>/dev/null | grep 16385 || echo "  (пусто)"
    echo ""
    echo "  === ip route (table 16385) ==="
    ip route show table 16385 2>/dev/null || echo "  (пусто)"
    echo ""
    echo "  === route get 149.154.166.110 ==="
    ip route get 149.154.166.110 2>/dev/null
    echo ""
}

do_procs() {
    echo ""
    echo "  === Процессы бота ==="
    ps w 2>/dev/null | grep -E "routerbot_wrapper|router_bot/main.py|tg-ws-proxy|hrneo" | grep -v grep \
        | sed 's/^/    /' || echo "    (нет)"
    echo ""
}

case "$1" in
    ""|-h|--help|help|h)
        show_help
        ;;
    start|s)
        $S98 start
        ;;
    stop|x)
        $S98 stop
        ;;
    restart|r)
        $S98 restart
        ;;
    reset)
        $S98 reset
        ;;
    status|st)
        do_status
        ;;
    logs|log|l)
        N="${2:-40}"
        if [ -f "$LOG" ]; then
            tail -n "$N" "$LOG"
        else
            echo "Лог не найден: $LOG"
        fi
        ;;
    follow|f)
        if [ -f "$LOG" ]; then
            echo "Ctrl+C — выход"
            tail -f "$LOG"
        else
            echo "Лог не найден: $LOG"
        fi
        ;;
    version|v)
        if [ -f "$VER_FILE" ]; then
            cat "$VER_FILE"
        else
            echo "VERSION-файл отсутствует"
        fi
        ;;
    config|c)
        do_config "$2" "$3" "$4"
        ;;
    modules|m)
        do_modules
        ;;
    tgtest)
        echo ""
        echo "  === Диагностика Telegram ==="
        echo ""
        printf "  1. DNS: "
        if /opt/bin/python3 -c "import socket; print(socket.gethostbyname('api.telegram.org'))" 2>/dev/null; then
            :
        else
            echo "ОШИБКА"
        fi
        printf "  2. TCP (443): "
        if /opt/bin/python3 -c "import socket; s=socket.create_connection(('149.154.166.110',443),timeout=5); s.close()" 2>/dev/null; then
            echo "OK"
        else
            echo "ОШИБКА"
        fi
        printf "  3. HTTP getMe: "
        TOKEN=$(sed -n "s/^TG_BOT_TOKEN='\(.*\)'/\1/p" "$CONF")
        CODE=$(/opt/bin/curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "https://api.telegram.org/bot${TOKEN}/getMe")
        echo "HTTP $CODE"
        printf "  4. Маршрут к TG: "
        ip route get 149.154.166.110 2>/dev/null | head -1
        echo ""
        echo "  5. ip rule (table 16385):"
        ip rule show | grep 16385 | sed 's/^/     /' || echo "     (пусто)"
        echo ""
        ;;

    ipv6)
        _v6="$2"
        if [ "$_v6" = "on" ]; then
            sed -i "s/^DISABLE_IPV6=.*/DISABLE_IPV6='no'/" "$CONF"
            cp -p "$CONF" "$CONF.bak" 2>/dev/null || true
            echo "✅ IPv6 включён. Перезапустите бота: rb restart"
        elif [ "$_v6" = "off" ]; then
            sed -i "s/^DISABLE_IPV6=.*/DISABLE_IPV6='yes'/" "$CONF"
            cp -p "$CONF" "$CONF.bak" 2>/dev/null || true
            echo "✅ IPv6 отключён (бот только на IPv4). Перезапустите бота: rb restart"
        else
            _cur=$(sed -n "s/^DISABLE_IPV6='\(.*\)'/\1/p" "$CONF" 2>/dev/null)
            if [ "$_cur" = "no" ]; then
                echo "IPv6: включён (бот использует IPv4 и IPv6)"
            else
                echo "IPv6: отключён (бот использует только IPv4)"
            fi
            echo "Использование: rb ipv6 [on|off]"
        fi
        ;;
    routes)
        do_routes
        ;;
    procs|ps)
        do_procs
        ;;
    health)
        if [ -x "$S99" ]; then
            $S99
        else
            echo "S99routerbot_health не найден"
        fi
        ;;
    rebuild)
        if [ -x "$S97" ]; then
            $S97 rebuild
            echo "Маршруты перестроены."
        else
            echo "S97tgroutes не найден"
        fi
        ;;
    update|u)
        TMP="/tmp/router_bot_setup.sh"
        echo "→ Скачиваю установщик с GitHub (с fallback на зеркала)..."
        OK=0
        for URL in \
          "https://raw.githubusercontent.com/zootsman/router-bot/master/router_bot_setup.sh" \
          "https://cdn.jsdelivr.net/gh/zootsman/router-bot@master/router_bot_setup.sh" \
          "https://raw.gitmirror.com/zootsman/router-bot/master/router_bot_setup.sh" \
          "https://ghproxy.net/https://raw.githubusercontent.com/zootsman/router-bot/master/router_bot_setup.sh"; do
            echo "  Пробую: $URL"
            if /opt/bin/curl -fsSL --max-time 20 "$URL" -o "$TMP"; then
                if [ -s "$TMP" ] && head -1 "$TMP" | grep -q '^#!/bin/sh'; then
                    OK=1
                    echo "  ✅ Скачано ($(wc -c < "$TMP") байт)"
                    break
                fi
            fi
        done
        if [ "$OK" = "1" ]; then
            chmod +x "$TMP"
            echo ""
            exec sh "$TMP"
        else
            echo "  ❌ Не удалось скачать ни с одного зеркала"
            echo "  Скачайте вручную и закиньте через scp/FTP:"
            echo "    scp router_bot_setup.sh root@192.168.1.1:/tmp/"
            echo "    sh /tmp/router_bot_setup.sh"
            exit 1
        fi
        ;;
    uninstall)
        echo ""
        echo "  Удаление Router Bot:"
        echo "    sh /opt/router_bot/uninstall.sh"
        echo ""
        ;;
    *)
        echo "Неизвестная команда: $1"
        echo "Справка:  rb -h"
        exit 1
        ;;
esac
RB_CORE_RB_EOF

echo "  → modules/__init__.py"
cat > /opt/router_bot/modules/__init__.py << 'RB_MODULES___INIT___PY_EOF'

RB_MODULES___INIT___PY_EOF

echo "  → modules/net_watch/__init__.py"
cat > /opt/router_bot/modules/net_watch/__init__.py << 'RB_MODULES_NET_WATCH___INIT___PY_EOF'

RB_MODULES_NET_WATCH___INIT___PY_EOF

echo "  → modules/net_watch/module.py"
cat > /opt/router_bot/modules/net_watch/module.py << 'RB_MODULES_NET_WATCH_MODULE_PY_EOF'
#!/opt/bin/python3
import asyncio
import html
import json
import logging
import os
import re
import subprocess
import socket
import urllib.request
from datetime import datetime, timedelta

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, BotCommand
from telegram.ext import (
    ApplicationBuilder, CommandHandler, CallbackQueryHandler,
    MessageHandler, filters, ContextTypes,
)
from core.utils import show_card



TOKEN = os.environ.get('TG_BOT_TOKEN', '')
CHAT_ID = os.environ.get('TG_CHAT_ID', '')
POLL_INTERVAL = int(os.environ.get('POLL_INTERVAL', '5'))
MISS_THRESHOLD = int(os.environ.get('MISS_THRESHOLD', '3'))
HEARTBEAT_INTERVAL = int(os.environ.get('HEARTBEAT_INTERVAL', '3600'))
VENDOR_LOOKUP = os.environ.get('VENDOR_LOOKUP', 'on').lower() in ('1', 'on', 'yes', 'true')
NDMC_PATH = os.environ.get('NDMC_PATH', '/bin/ndmc')
BLOCKED_FILE = '/opt/router_bot/data/net_watch/blocked.json'
KNOWN_NAMES_FILE = '/opt/router_bot/data/net_watch/known_names.json'

HISTORY_FILE = '/opt/router_bot/data/net_watch/history.json'
VENDORS_FILE = '/opt/router_bot/data/net_watch/vendors.json'
HISTORY_LIMIT = 20

log = logging.getLogger(__name__)



# ---------- ndmc ----------
async def run_ndmc(cmd: str, timeout: float = 5) -> str:
    proc = await asyncio.create_subprocess_exec(
        NDMC_PATH, '-c', cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        log.warning('ndmc timeout: %s', cmd)
        return ''
    return out.decode(errors='replace')


async def get_active_clients() -> dict:
    output = await run_ndmc('show ip hotspot')
    if not output:
        return {}

    known_names = load_json(KNOWN_NAMES_FILE, {})
    clients = {}

    # ключи, которые не нужны (вложенные подсекции и дубликаты)
    IGNORE = {
        'via', 'mws-backhaul', 'id', 'description', 'expires',
        'registered', 'policy', 'priority', 'rx', 'tx',
        'schedule', 'traffic-shape', 'dhcp', 'interface', 'type',
        'auto-negotiation', 'mld', 'psm', 'txss', 'ebf', 'dl-mu',
        'ht', 'gi', 'mcs', '_11', 'roam', 'pmf', 'security',
        'authenticated', 'connected', 'ssdp',
    }

    INT_FIELDS = {
        'rxbytes', 'txbytes', 'speed', 'port', 'txrate',
        'rssi', 'uptime', 'first-seen', 'last-seen',
    }

    for block in output.split('host:'):
        if not block.strip():
            continue

        c = {
            'mac': '', 'name': '', 'hostname': '', 'ip': '', 'ip6': '',
            'active': 'no', 'access': 'permit',
            'rxbytes': 0, 'txbytes': 0,
            'link': '', 'speed': 0, 'duplex': False, 'port': 0,
            'ssid': '', 'ap': '', 'txrate': 0, 'mode': '', 'rssi': 0,
            'uptime': 0, 'first_seen': 0, 'last_seen': 0,
            'ssdp_manufacturer': '', 'ssdp_model': '', 'ssdp_model_desc': '',
        }

        in_ssdp = False
        for raw in block.split('\n'):
            stripped = raw.strip()
            if not stripped:
                continue

            if stripped == 'ssdp:':
                in_ssdp = True
                continue

            if ':' not in stripped:
                continue
            k, v = stripped.split(':', 1)
            k = k.strip()
            v = v.strip()

            # ssdp: manufacturer / model / model-desc
            if in_ssdp:
                if k == 'manufacturer' and not c['ssdp_manufacturer']:
                    c['ssdp_manufacturer'] = v
                elif k == 'model-desc' and not c['ssdp_model_desc']:
                    c['ssdp_model_desc'] = v
                elif k == 'model' and not c['ssdp_model']:
                    c['ssdp_model'] = v
                continue

            if k in IGNORE:
                continue

            if k in INT_FIELDS:
                try:
                    val = int(v)
                except Exception:
                    continue
                if k == 'first-seen':
                    c['first_seen'] = val
                elif k == 'last-seen':
                    c['last_seen'] = val
                else:
                    c[k] = val
                continue

            if k == 'duplex':
                c['duplex'] = (v == 'yes')
                continue

            # строковые поля — только если ещё не заданы
            if k == 'mac' and not c['mac']:
                c['mac'] = v
            elif k == 'ip' and not c['ip']:
                c['ip'] = v
            elif k == 'ip6' and not c['ip6']:
                c['ip6'] = v
            elif k == 'hostname' and not c['hostname']:
                c['hostname'] = v
            elif k == 'name' and not c['name']:
                c['name'] = v
            elif k == 'active' and not c['active']:
                c['active'] = v
            elif k == 'access' and not c['access']:
                c['access'] = v
            elif k == 'link' and not c['link']:
                c['link'] = v
            elif k == 'ssid' and not c['ssid']:
                c['ssid'] = v
            elif k == 'ap' and not c['ap']:
                c['ap'] = v
            elif k == 'mode' and not c['mode']:
                c['mode'] = v

        mac = c['mac']
        if not mac:
            continue
        if c['active'] != 'yes' and c.get('link', '') != 'up':
            continue

        display = (known_names.get(mac)
                   or (c['name'] if c['name'] and ' - ' not in c['name'] else None)
                   or c['hostname']
                   or (c['name'].split(' - ')[0].strip() if c['name'] and ' - ' in c['name'] else None)
                   or mac)
        c['name'] = display
        clients[mac] = c

    return clients

async def _hotspot_access(mac: str) -> str:
    """Возвращает 'permit' / 'deny' / '' (устройство не в hotspot)."""
    out = await run_ndmc('show ip hotspot')
    if not out:
        return ''
    mac_low = mac.lower()
    current = None
    for line in out.split('\n'):
        stripped = line.strip()
        if stripped.startswith('mac:'):
            current = stripped.split('mac:')[1].strip().lower()
        elif stripped.startswith('access:') and current == mac_low:
            return stripped.split('access:')[1].strip()
    return ''


async def block_client(mac: str) -> bool:
    """Блокирует MAC. Возвращает True если access стал deny."""
    log.info('block: sending deny for %s', mac)
    out = await run_ndmc(f'ip hotspot host {mac} deny')
    if out:
        log.debug('block output: %s', out.strip()[:200])

    access = await _hotspot_access(mac)
    if access == 'deny':
        log.info('block: %s is now deny', mac)
        return True

    log.warning('block FAILED for %s (access=%s)', mac, access or 'unknown')
    return False


async def unblock_client(mac: str) -> bool:
    """Снимает блокировку. Возвращает True если access стал permit."""
    log.info('unblock: sending permit for %s', mac)
    out = await run_ndmc(f'ip hotspot host {mac} permit')
    if out:
        log.debug('unblock output: %s', out.strip()[:200])

    access = await _hotspot_access(mac)
    if access == 'permit':
        log.info('unblock: %s is now permit', mac)
        return True

    log.warning('unblock FAILED for %s (access=%s)', mac, access or 'unknown')
    return False

# ---------- JSON-хелперы ----------
def load_json(path: str, default):
    if not os.path.exists(path):
        return default
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def save_json(path: str, data):
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def get_vendor(mac: str) -> str:
    """Производитель по MAC через macvendors.com, с кешем в файле."""
    if not VENDOR_LOOKUP:
        return ''
    if not mac or len(mac) < 8:
        return ''
    mac_up = mac.upper().replace('-', ':')

    cache = load_json(VENDORS_FILE, {})
    if mac_up in cache:
        return cache[mac_up]

    vendor = ''
    try:
        url = f'https://api.macvendors.com/{mac_up}'
        req = urllib.request.Request(url, headers={'User-Agent': 'WiFiNotifier/1.0'})
        with urllib.request.urlopen(req, timeout=4) as r:
            vendor = r.read().decode('utf-8', errors='replace').strip()
            if len(vendor) > 60:
                vendor = vendor[:57] + '...'
    except Exception as e:
        log.debug('vendor lookup %s failed: %s', mac_up, e)

    cache = load_json(VENDORS_FILE, {})
    cache[mac_up] = vendor
    save_json(VENDORS_FILE, cache)
    return vendor


async def get_vendor_async(mac: str) -> str:
    try:
        return await asyncio.to_thread(get_vendor, mac)
    except Exception as e:
        log.debug('get_vendor_async failed: %s', e)
        return ''


NAME_RULES = [
    # Порядок важен: первое совпадение выигрывает.
    # TV / медиа — ВЫШЕ умных колонок (Station TV — это TV).
    ('\U0001f4fa', 'телевизор / медиа',
        ['-tv', 'tv-', 'bravia', 'chromecast', 'apple-tv', 'androidtv', 'smarttv',
         'телевизор', 'smart-tv']),
    ('\U0001f3ae', 'игровая консоль',
        ['xbox', 'playstation', 'ps4', 'ps5', 'nintendo', 'switch', 'консол']),
    ('\U0001f50a', 'умная колонка',
        ['yandex-station', 'yandex_station', 'station', 'google-home', 'googlehome',
         'alexa', 'echo', 'homepod', 'sonos', 'колонк', 'speaker']),
    ('\u231a', 'часы / трекер',
        ['watch', 'mi-band', 'miband', 'часы', 'tracker']),
    ('\U0001f5a8\ufe0f', 'принтер / МФУ',
        ['printer', 'hp-', 'hp_', 'canon', 'epson', 'brother', 'принтер', 'mfp']),
    ('\U0001f4f7', 'камера / видеонаблюдение',
        ['camera', 'cam-', 'cam_', 'ipc', 'dvr', 'nvr', 'камера']),
    ('\U0001f697', 'автомобиль',
        ['tesla', 'bmw', 'toyota', 'audi', 'kia', 'hyundai', 'car-']),
    ('\U0001f4bb', 'компьютер / ноутбук',
        ['laptop', 'notebook', 'macbook', 'desktop', 'pc-', '-pc',
         'ноутбук', 'компьютер', 'imac', 'mac-mini']),
    ('\U0001f4be', 'NAS / хранилище',
        ['synology', 'qnap', 'nas-', '-nas', 'хранилищ']),
    ('\U0001f4f1', 'смартфон / планшет',
        ['iphone', 'ipad', 'android', 'galaxy', 'redmi', 'xiaomi',
         'pixel', 'huawei', 'honor', 'realme', 'oneplus', 'oppo',
         'vivo', 'телефон', 'samsung', '-a1', 'sm-', 'poco',
         'mi-', 'mi_', 'redmi-', 'note-', 'phone', 'x8', 'x9',
         'x10', 'x11', 'x12', 'x13', 'x14']),
]


def _fmt_bytes(n):
    try:
        n = int(n)
    except Exception:
        return '?'
    if n < 1024:
        return f'{n} Б'
    if n < 1024 ** 2:
        return f'{n / 1024:.1f} КБ'
    if n < 1024 ** 3:
        return f'{n / 1024 ** 2:.1f} МБ'
    return f'{n / 1024 ** 3:.2f} ГБ'


def _device_meta(name: str, vendor: str = '', ssdp_model: str = '',
                 hostname: str = ''):
    """Возвращает (icon, label) — иконку и тип устройства."""
    n = (name or '').lower()
    v = (vendor or '').lower()
    m = (ssdp_model or '').lower()
    h = (hostname or '').lower()
    combined = f'{n} {m} {h}'

    for icon, label, keys in NAME_RULES:
        for k in keys:
            if k in combined:
                return icon, label

    if 'apple' in v:
        return '\U0001f4f1', 'смартфон / планшет'
    if 'microsoft' in v or 'xbox' in v:
        return '\U0001f3ae', 'игровая консоль'
    if 'synology' in v or 'qnap' in v:
        return '\U0001f4be', 'NAS / хранилище'
    if 'hewlett' in v or 'canon' in v or 'epson' in v or 'brother' in v:
        return '\U0001f5a8\ufe0f', 'принтер / МФУ'

    return '\U0001f4f6', 'устройство'


def device_icon(name: str, vendor: str = '', ssdp_model: str = '',
                hostname: str = '') -> str:
    """Иконка по имени / ssdp-модели / hostname / производителю."""
    return _device_meta(name, vendor, ssdp_model, hostname)[0]


def device_type(name: str, vendor: str = '', ssdp_model: str = '',
                hostname: str = '') -> str:
    """Тип устройства (текстом)."""
    return _device_meta(name, vendor, ssdp_model, hostname)[1]


def append_event(mac: str, event_type: str):
    h = load_json(HISTORY_FILE, {})
    events = h.get(mac, [])
    events.append({
        't': datetime.now().isoformat(timespec='seconds'),
        'e': event_type,
    })
    if len(events) > HISTORY_LIMIT * 5:
        events = events[-HISTORY_LIMIT * 5:]
    h[mac] = events
    save_json(HISTORY_FILE, h)


def get_history(mac: str, limit: int = HISTORY_LIMIT):
    h = load_json(HISTORY_FILE, {})
    events = h.get(mac, [])
    # На случай если в файле события вперемешку — сортируем по ISO-времени
    try:
        events = sorted(events, key=lambda e: e.get('t', ''))
    except Exception:
        pass
    return events[-limit:]


def fmt_event(ev: dict) -> str:
    try:
        t = datetime.fromisoformat(ev['t']).strftime('%d.%m %H:%M:%S')
    except Exception:
        t = str(ev.get('t', '?'))
    if ev.get('e') == 'connect':
        return f'🟢 {t} — подключение'
    return f'🔴 {t} — отключение'



# ---------- Telegram ----------
def main_keyboard():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton('🔄 Обновить список', callback_data='refresh')],
        [InlineKeyboardButton('📊 Статистика', callback_data='stats')],
    ])


def device_keyboard(mac: str, blocked: bool):
    if blocked:
        btn = InlineKeyboardButton('🔓 Разблокировать', callback_data=f'unblock:{mac}')
    else:
        btn = InlineKeyboardButton('🚫 Заблокировать', callback_data=f'block:{mac}')
    return InlineKeyboardMarkup([[btn]])


async def send(bot, text: str, markup=None):
    try:
        msg = await bot.send_message(
            chat_id=CHAT_ID, text=text,
            parse_mode='HTML', reply_markup=markup,
        )
        try:
            from core.utils import notify_register
            notify_register(CHAT_ID, msg.message_id)
        except Exception as e:
            log.debug('notify_register failed: %s', e)
    except Exception as e:
        log.error('Telegram send error: %s', e)



async def cmd_status(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    text, kb = await build_status_message()
    kb = _prefix_kb(kb)
    rows = list(kb.inline_keyboard)
    rows.append([InlineKeyboardButton('⬅️ К модулям', callback_data='router:main')])
    await update.message.reply_text(
        text, parse_mode='HTML', reply_markup=InlineKeyboardMarkup(rows),
    )

def _fmt_duration(seconds: float) -> str:
    seconds = int(seconds)
    d, rem = divmod(seconds, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    parts = []
    if d: parts.append(f'{d}д')
    if h: parts.append(f'{h}ч')
    if m or not parts: parts.append(f'{m}м')
    return ' '.join(parts)


def build_stats_text() -> str:
    stats = load_json('/opt/router_bot/data/net_watch/stats.json', {})
    now = datetime.now()

    session_started = stats.get('session_started')
    try:
        uptime = (now - datetime.fromisoformat(session_started)).total_seconds()
    except Exception:
        uptime = 0

    return (
        f'📊 <b>Статистика</b>\n'
        f'\n'
        f'🕐 Аптайм сессии: <b>{_fmt_duration(uptime)}</b>'
    )

async def cmd_stats(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(build_stats_text(), parse_mode='HTML')


async def build_status_message():
    """Возвращает (text, InlineKeyboardMarkup)."""
    clients = await get_active_clients()
    blocked = load_json(BLOCKED_FILE, [])
    ts = datetime.now().strftime('%H:%M:%S')

    kb_rows = []

    if not clients:
        text = f'📡 Сейчас нет активных клиентов.\n\n<i>Обновлено в {ts}</i>'
    else:
        lines = [f'📡 <b>Активные клиенты ({len(clients)}):</b>']
        for mac, info in clients.items():
            is_blocked = mac in blocked
            name = html.escape(info['name'])
            ip = html.escape(info.get('ip', 'unknown'))
            mac_esc = html.escape(mac)
            icon = device_icon(
                info['name'],
                info.get('ssdp_manufacturer', ''),
                info.get('ssdp_model', ''),
                info.get('hostname', ''),
            )

            lines.append('')
            if is_blocked:
                lines.append(f'🚫 <i>{icon} {name}</i>')
                lock_btn = InlineKeyboardButton('🔓', callback_data=f'unblock:{mac}')
            else:
                lines.append(f'🟢 {icon} <b>{name}</b>')
                lock_btn = InlineKeyboardButton('🚫', callback_data=f'block:{mac}')

            lines.append(f'        <code>{ip}</code>')
            lines.append(f'        <code>{mac_esc}</code>')

            btn_name = info['name']
            if len(btn_name) > 28:
                btn_name = btn_name[:25] + '...'
            name_btn = InlineKeyboardButton(f'{icon} {btn_name}', callback_data=f'dev:{mac}')
            kb_rows.append([name_btn, lock_btn])

        lines.append('')
        lines.append(f'<i>Обновлено в {ts}</i>')
        text = '\n'.join(lines)

    kb_rows.append([
        InlineKeyboardButton('🔄 Обновить', callback_data='refresh'),
        InlineKeyboardButton('📊 Статистика', callback_data='stats'),
    ])

    return text, InlineKeyboardMarkup(kb_rows)


async def build_device_card(info: dict, blocked: list):
    """info — словарь из get_active_clients (или урезанный для офлайн)."""
    mac = info.get('mac', '')
    name = info.get('name', mac)
    ip = info.get('ip', 'unknown')
    hostname = info.get('hostname', '')
    is_blocked = mac in blocked
    history = get_history(mac, HISTORY_LIMIT)
    vendor_mac = await get_vendor_async(mac)

    ssdp_mfr = info.get('ssdp_manufacturer', '')
    ssdp_mdl = info.get('ssdp_model', '')

    eff_vendor = ssdp_mfr or vendor_mac
    eff_model = ssdp_mdl

    hostname = info.get('hostname', '')
    icon = device_icon(name, eff_vendor, eff_model, hostname)
    dtype = device_type(name, eff_vendor, eff_model, hostname)

    lines = [f'{icon} <b>{html.escape(name)}</b>']

    # Строка описания: SSDP > hostname > macvendors
    if ssdp_mfr and ssdp_mdl:
        lines.append(f'🏭 <i>{html.escape(ssdp_mfr)} — {html.escape(ssdp_mdl)}</i>')
    elif hostname and hostname != name and hostname.replace(':', '').lower() != mac.replace(':', '').lower():
        lines.append(f'🏷 <i>{html.escape(hostname)}</i>')
    elif vendor_mac:
        lines.append(f'🏭 <i>{html.escape(vendor_mac)}</i>')

    lines.append(f'📡 {dtype}')
    lines.append('')

    # --- Подключение ---
    is_wifi = bool(info.get('ssid'))
    if is_wifi:
        lines.append(f"📶 WiFi · {html.escape(info['ssid'])}")
        if info.get('txrate'):
            mode = info.get('mode', '')
            rate = info['txrate']
            rate_s = f'{rate} Мбит/с' if rate < 1000 else f'{rate/1000:.1f} Гбит/с'
            extra = f' ({mode})' if mode else ''
            lines.append(f'   Скорость: {rate_s}{extra}')
        if info.get('rssi'):
            rssi = info['rssi']
            if rssi >= -50:
                q = '🟢 отличный'
            elif rssi >= -60:
                q = '🟢 хороший'
            elif rssi >= -70:
                q = '🟡 средний'
            else:
                q = '🔴 слабый'
            lines.append(f'   Сигнал: {rssi} dBm ({q})')
    else:
        # Ethernet
        port = info.get('port', 0)
        speed = info.get('speed', 0)
        port_s = f' · порт {port}' if port else ''
        lines.append(f'🔌 Ethernet{port_s}')
        if speed:
            speed_s = f'{speed} Мбит/с' if speed < 1000 else f'{speed/1000:.1f} Гбит/с'
            duplex = 'full-duplex' if info.get('duplex') else 'half-duplex'
            lines.append(f'   Скорость: {speed_s} · {duplex}')

    lines.append('')
    lines.append(f'IP: <code>{html.escape(ip)}</code>')
    lines.append(f'MAC: <code>{html.escape(mac)}</code>')

    # --- Статус ---
    if is_blocked:
        status = '🚫 Заблокирован'
    else:
        status = '🟢 Онлайн'
    up = info.get('uptime', 0)
    if up > 0:
        status += f' · {_fmt_duration(up)}'
    lines.append(f'Статус: {status}')

    # --- Трафик ---
    rx = info.get('rxbytes', 0)
    tx = info.get('txbytes', 0)
    if rx or tx:
        lines.append('')
        lines.append(f'📊 Трафик: ↓ {_fmt_bytes(rx)} · ↑ {_fmt_bytes(tx)}')

    # --- История ---
    if history:
        lines.append('')
        lines.append(f'📜 <b>Последние {len(history)} событий:</b>')
        last_i = len(history) - 1
        for i, ev in enumerate(history):
            suffix = '  ◀' if i == last_i else ''
            lines.append(fmt_event(ev) + suffix)
    else:
        lines.append('')
        lines.append('📜 История пуста')

    text = '\n'.join(lines)

    if is_blocked:
        lock_btn = InlineKeyboardButton('🔓 Разблокировать', callback_data=f'unblock:{mac}')
    else:
        lock_btn = InlineKeyboardButton('🚫 Заблокировать', callback_data=f'block:{mac}')

    kb = InlineKeyboardMarkup([
        [lock_btn],
    ])
    return text, kb

async def safe_edit(q, text, markup=None):
    """edit_message_text; при 'not modified' просто игнорируем."""
    try:
        await q.edit_message_text(text, parse_mode='HTML', reply_markup=markup)
    except Exception as e:
        if 'not modified' in str(e).lower():
            return
        raise



async def delete_later(ctx: ContextTypes.DEFAULT_TYPE):
    data = ctx.job.data
    log.debug("delete_later: удаляю message_id=%s", data.get('message_id'))
    try:
        await ctx.bot.delete_message(
            chat_id=data['chat_id'], message_id=data['message_id'],
        )
        log.debug("delete_later: OK, удалено")
    except Exception as e:
        log.warning('delete_later FAIL: %s', e)




# ---------- Heartbeat ----------
async def heartbeat(ctx: ContextTypes.DEFAULT_TYPE):
    clients = await get_active_clients()
    text = (
        f'💓 <b>Heartbeat</b>\n'
        f'Клиентов онлайн: <b>{len(clients)}</b>\n'
        f'Время: {datetime.now():%Y-%m-%d %H:%M}'
    )
    try:
        msg = await ctx.bot.send_message(
            chat_id=CHAT_ID, text=text, parse_mode='HTML',
        )
        log.info("heartbeat: отправлено message_id=%s", msg.message_id)
        jq = getattr(ctx, 'job_queue', None) or ctx.application.job_queue
        log.debug("heartbeat: job_queue=%s", jq)
        j = jq.run_once(
            delete_later, when=timedelta(seconds=10),
            data={'chat_id': msg.chat_id, 'message_id': msg.message_id},
        )
        log.debug("heartbeat: run_once scheduled: %s", j)
    except Exception as e:
        log.exception('heartbeat send/schedule error: %s', e)
    log.info('Heartbeat sent, clients=%d', len(clients))


# ---------- Мониторинг ----------
class MonitorState:
    def __init__(self):
        self.known: dict = {}
        self.events = 0
        # MAC -> message_id уведомления о подключении (для редактирования)
        self.notice_msgs: dict = {}
        # MAC -> счётчик циклов подряд без него (debounce)
        self._miss: dict = {}


def _connection_line(info: dict) -> str:
    """Одна строка про тип подключения — WiFi или Ethernet."""
    if info.get('ssid'):
        ssid = info['ssid']
        rate = info.get('txrate', 0)
        rate_s = ''
        if rate:
            rate_s = f' · {rate} Мбит/с'
        return f'📶 WiFi · {html.escape(ssid)}{rate_s}'
    port = info.get('port', 0)
    speed = info.get('speed', 0)
    parts = []
    if port:
        parts.append(f'порт {port}')
    if speed:
        parts.append(f'{speed} Мбит/с' if speed < 1000 else f'{speed/1000:.1f} Гбит/с')
    suffix = ' · ' + ' · '.join(parts) if parts else ''
    return f'🔌 Ethernet{suffix}'


def _connect_text(info: dict) -> str:
    name = info.get('name') or info.get('mac', '?')
    ip = info.get('ip', 'unknown')
    mac = info.get('mac', '?')
    conn = _connection_line(info)
    return (
        f'🟢 <b>Подключилось:</b> {html.escape(name)}\n'
        f'{conn}\n'
        f'IP: <code>{html.escape(ip)}</code>\n'
        f'MAC: <code>{html.escape(mac)}</code>'
    )


def _disconnect_text(info: dict) -> str:
    name = info.get('name') or info.get('mac', '?')
    mac = info.get('mac', '?')
    return (
        f'🔴 <b>Отключилось:</b> {html.escape(name)}\n'
        f'MAC: <code>{html.escape(mac)}</code>'
    )



async def poll_loop(app):
    state = MonitorState()
    # state доступен через app.bot_data — если понадобится в будущем
    app.bot_data['net_watch_state'] = state
    state.known = await get_active_clients()
    log.info('Initial clients: %s', list(state.known.keys()))

    while True:
        try:
            current = await get_active_clients()
            blocked = load_json(BLOCKED_FILE, [])

            # --- 1. Обновляем имена у уже известных устройств ---
            for mac, info in current.items():
                if mac not in state.known:
                    continue
                old_name = state.known[mac].get('name', '')
                new_name = info.get('name', '')

                # Считаем, что новое имя лучше, если:
                # - старое = MAC (или начинается как MAC),
                # - новое не MAC.
                old_is_mac = (old_name == mac
                              or old_name.replace(':', '').lower()
                                  == mac.replace(':', '').lower())
                new_is_mac = (new_name == mac
                              or new_name.replace(':', '').lower()
                                  == mac.replace(':', '').lower())

                if old_is_mac and not new_is_mac and new_name:
                    # Обновляем в памяти
                    state.known[mac]['name'] = new_name
                    log.info('Name updated for %s: %s -> %s',
                             mac, old_name, new_name)

                    # Редактируем отправленное уведомление
                    msg_id = state.notice_msgs.get(mac)
                    if msg_id:
                        try:
                            new_info = dict(state.known[mac])
                            new_info['name'] = new_name
                            await app.bot.edit_message_text(
                                chat_id=CHAT_ID,
                                message_id=msg_id,
                                text=_connect_text(new_info),
                                parse_mode='HTML',
                                reply_markup=device_keyboard(mac, mac in blocked),
                            )
                            log.info('Notice edited for %s', mac)
                        except Exception as e:
                            err = str(e).lower()
                            if ('message_id_invalid' in err
                                    or 'message to edit not found' in err
                                    or 'not modified' in err):
                                log.debug('edit notice skipped: %s', e)
                                state.notice_msgs.pop(mac, None)
                            else:
                                log.warning('edit notice error: %s', e)

                # IP тоже актуализируем
                if info.get('ip'):
                    state.known[mac]['ip'] = info['ip']

            # --- 2. Новые устройства: уведомляем сразу ---
            for mac, info in current.items():
                if mac in state.known:
                    continue

                # Дедупликация: если последнее событие уже 'connect',
                # значит это НЕ реальное подключение, а восстановление
                # состояния после рестарта бота. Тихо запоминаем и идём дальше.
                prev_events = load_json(HISTORY_FILE, {}).get(mac, [])
                last_type = prev_events[-1].get('e') if prev_events else None

                state.known[mac] = info
                if last_type == 'connect':
                    log.info('silent restore %s (last event already connect)', mac)
                    continue

                state.events += 1

                try:
                    msg = await app.bot.send_message(
                        chat_id=CHAT_ID,
                        text=_connect_text(info),
                        parse_mode='HTML',
                        reply_markup=device_keyboard(mac, mac in blocked),
                    )
                    try:
                        from core.utils import notify_register
                        notify_register(CHAT_ID, msg.message_id)
                    except Exception as e:
                        log.debug('notify_register failed: %s', e)
                    state.notice_msgs[mac] = msg.message_id
                    append_event(mac, 'connect')
                    log.info('New device: %s (%s), msg_id=%s',
                             mac, info['name'], msg.message_id)
                except Exception as e:
                    log.exception('send connect notice error: %s', e)

            # --- 3. Отключения (с debounce) ---
            if not current:
                log.warning('hotspot returned empty — skip disconnect check')
            else:
                static_arp = _static_arp_macs()
                for mac in list(state.known.keys()):
                    if mac in current:
                        state._miss.pop(mac, None)
                        continue
                    if mac.lower() in static_arp:
                        # Статический ARP — считаем онлайн
                        state._miss.pop(mac, None)
                        continue
                    state._miss[mac] = state._miss.get(mac, 0) + 1
                    if state._miss[mac] < MISS_THRESHOLD:
                        log.debug('miss %s (%d/%d)', mac,
                                  state._miss[mac], MISS_THRESHOLD)
                        continue
                    info = state.known[mac]
                    state.notice_msgs.pop(mac, None)
                    append_event(mac, 'disconnect')
                    await send(app.bot, _disconnect_text(info))
                    state.events += 1
                    del state.known[mac]
                    state._miss.pop(mac, None)

            stats = load_json('/opt/router_bot/data/net_watch/stats.json',
                              {'total_events': 0, 'started': datetime.now().isoformat()})
            stats['total_events'] = state.events
            save_json('/opt/router_bot/data/net_watch/stats.json', stats)

        except Exception as e:
            log.exception('Poll loop error: %s', e)

        await asyncio.sleep(POLL_INTERVAL)

# ---------- Main ----------
async def _startup_module(app):
    asyncio.create_task(poll_loop(app))
    log.info('Net Watch module started')

def _prefix_kb(kb):
    """Применяет префикс net_watch: ко всем callback_data."""
    if kb is None:
        return None
    new_rows = []
    for row in kb.inline_keyboard:
        new_row = []
        for btn in row:
            cd = btn.callback_data
            if cd and not cd.startswith('net_watch:') and cd != 'router:main':
                new_row.append(InlineKeyboardButton(btn.text, callback_data=f'net_watch:{cd}'))
            else:
                new_row.append(btn)
        new_rows.append(new_row)
    return InlineKeyboardMarkup(new_rows)


# ======================== Module interface ========================

import logging as _logging
_log = _logging.getLogger('net_watch')

CHAT_ID = os.environ.get('TG_CHAT_ID', '')  # перезагружаем актуальный


class NetWatchModule:
    name = 'net_watch'
    title = 'Net Watch'
    icon = '📡'
    description = 'мониторинг сетевых клиентов'
    commands = [('net', '📡 Net Watch')]
    cleanup_paths = []
    cleanup_init = []

    def __init__(self, chat_id: str):
        import sys
        this = sys.modules[__name__]
        this.CHAT_ID = chat_id
        self.chat_id = str(chat_id)
        self._editing_name_mac = None
        self._editing_name_msg_id = None

    async def startup(self, app):
        # Инициализация stats.json: пишем session_started при каждом старте
        try:
            stats = load_json('/opt/router_bot/data/net_watch/stats.json', {})
            stats['session_started'] = datetime.now().isoformat(timespec='seconds')
            stats.setdefault('session_started', datetime.now().isoformat(timespec='seconds'))
            save_json('/opt/router_bot/data/net_watch/stats.json', stats)
            log.info('Net Watch session_started=%s', stats['session_started'])
        except Exception as e:
            log.warning('session_started write failed: %s', e)

        app.add_handler(CommandHandler('status', cmd_status))
        app.add_handler(CommandHandler('stats', cmd_stats))
        app.add_handler(MessageHandler(
            filters.TEXT & ~filters.COMMAND,
            self._handle_text,
        ), group=1)
        try:
            added = await sync_known_hosts_from_router()
            log.info('startup sync known hosts: %d added', added)
        except Exception as e:
            log.warning('startup known hosts sync failed: %s', e)
        await _startup_module(app)


    async def on_leave(self):
        """Сброс состояния при уходе из модуля."""
        pass

    async def send_card_message(self, update, ctx):
        """Отправляет карточку модуля в ответ на команду /net."""
        clients = await get_active_clients()
        blocked = load_json(BLOCKED_FILE, [])
        text = (
            f'{self.icon} <b>{self.title}</b>\n'
            f'<i>{self.description}</i>\n'
            f'\n'
            f'\U0001f7e2 Онлайн сейчас: <b>{len(clients)}</b>\n'
            f'\U0001f6ab Заблокировано: <b>{len(blocked)}</b>'
        )
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('\U0001f4cb Открыть список', callback_data='net_watch:clients')],
            [InlineKeyboardButton('\U0001f4ca Статистика', callback_data='net_watch:stats')],
            [InlineKeyboardButton('\U0001f3e0 Модули', callback_data='router:main')],
        ])
        await show_card(update, ctx, text, kb=kb)

    async def handle_callback(self, action: str, query, ctx):
        await query.answer()

        if action == 'main':
            return await self._show_module_card(query, ctx)
        if action in ('clients', 'refresh'):
            return await self._show_clients(query, ctx)
        if action == 'stats':
            return await self._show_stats(query, ctx)
        if action == 'sync_known':
            return await self._do_sync_known(query, ctx)
        if action.startswith('rename:'):
            return await self._ask_rename(action[7:], query, ctx)
        if action.startswith('autoname:'):
            return await self._do_autoname(action[9:], query, ctx)
        if action.startswith('dev:'):
            return await self._show_device(action[4:], query, ctx)
        if action.startswith('block:'):
            return await self._do_block(action[6:], query, ctx)
        if action.startswith('unblock:'):
            return await self._do_unblock(action[8:], query, ctx)

    # ------- экраны -------

    async def _show_module_card(self, q, ctx):
        """Уровень 1. Назад → главное меню."""
        clients = await get_active_clients()
        blocked = load_json(BLOCKED_FILE, [])
        text = (
            f'{self.icon} <b>{self.title}</b>\n'
            f'<i>мониторинг сетевых клиентов</i>\n'
            f'\n'
            f'🟢 Онлайн сейчас: <b>{len(clients)}</b>\n'
            f'🚫 Заблокировано: <b>{len(blocked)}</b>'
        )
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('📋 Открыть список', callback_data='net_watch:clients')],
            [InlineKeyboardButton('📊 Статистика', callback_data='net_watch:stats')],
            [InlineKeyboardButton('🔁 Синхронизировать имена с роутером',
                                  callback_data='net_watch:sync_known')],
            [InlineKeyboardButton('⬅️ Назад', callback_data='router:main')],
        ])
        await safe_edit(q, text, kb)

    async def _show_clients(self, q, ctx):
        """Уровень 2. Назад → карточка модуля."""
        text, kb = await build_status_message()
        kb = _prefix_kb(kb)
        rows = list(kb.inline_keyboard)
        rows.append([
            InlineKeyboardButton('⬅️ Назад', callback_data='net_watch:main'),
            InlineKeyboardButton('🏠 Модули', callback_data='router:main'),
        ])
        kb = InlineKeyboardMarkup(rows)
        await safe_edit(q, text, kb)

    async def _show_stats(self, q, ctx):
        """Уровень 2. Назад → карточка модуля."""
        text = build_stats_text()
        kb = InlineKeyboardMarkup([
            [
                InlineKeyboardButton('⬅️ Назад', callback_data='net_watch:main'),
                InlineKeyboardButton('🏠 Модули', callback_data='router:main'),
            ],
        ])
        await safe_edit(q, text, kb)

    async def _show_device(self, mac, q, ctx):
        """Карточка устройства."""
        clients = await get_active_clients()
        blocked = load_json(BLOCKED_FILE, [])
        if mac in clients:
            info = clients[mac]
        else:
            names = load_json(KNOWN_NAMES_FILE, {})
            info = {
                'mac': mac,
                'name': names.get(mac, mac),
                'ip': 'не в сети',
                'hostname': '',
                'ssdp_manufacturer': '',
                'ssdp_model': '',
                'ssid': '',
                'port': 0,
                'speed': 0,
                'duplex': False,
                'txrate': 0,
                'mode': '',
                'rssi': 0,
                'uptime': 0,
                'rxbytes': 0,
                'txbytes': 0,
            }
        text, kb = await build_device_card(info, blocked)
        kb = _prefix_kb(kb)
        rows = list(kb.inline_keyboard)
        rename_row = [InlineKeyboardButton(
            '✏️ Переименовать',
            callback_data=f'net_watch:rename:{mac}',
        )]
        if mac in load_json(KNOWN_NAMES_FILE, {}):
            rename_row.append(InlineKeyboardButton(
                '🔄 Авто-имя',
                callback_data=f'net_watch:autoname:{mac}',
            ))
        rows.append(rename_row)
        rows.append([
            InlineKeyboardButton('⬅️ Назад', callback_data='net_watch:clients'),
            InlineKeyboardButton('🏠 Модули', callback_data='router:main'),
        ])
        kb = InlineKeyboardMarkup(rows)
        await safe_edit(q, text, kb)


    # ------- действия -------

    async def _do_block(self, mac, q, ctx):
        blocked = load_json(BLOCKED_FILE, [])
        if mac not in blocked:
            ok = await block_client(mac)
            if not ok:
                await q.answer('❌ Не удалось заблокировать', show_alert=True)
                return
            blocked.append(mac)
            save_json(BLOCKED_FILE, blocked)
        # возвращаемся на карточку устройства, чтобы пользователь видел результат
        await self._show_device(mac, q, ctx)

    async def _do_unblock(self, mac, q, ctx):
        blocked = load_json(BLOCKED_FILE, [])
        ok = await unblock_client(mac)
        if not ok:
            await q.answer('❌ Не удалось разблокировать', show_alert=True)
            return
        if mac in blocked:
            blocked.remove(mac)
            save_json(BLOCKED_FILE, blocked)
        await self._show_device(mac, q, ctx)


    # ------- переименование -------

    async def _ask_rename(self, mac, q, ctx):
        self._editing_name_mac = mac
        self._editing_name_msg_id = q.message.message_id
        known = load_json(KNOWN_NAMES_FILE, {})
        current = known.get(mac, '')
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('\u274c \u041e\u0442\u043c\u0435\u043d\u0430',
                                  callback_data=f'net_watch:dev:{mac}')],
        ])
        text = (
            f'\u270f\ufe0f <b>\u041f\u0435\u0440\u0435\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435 \u0443\u0441\u0442\u0440\u043e\u0439\u0441\u0442\u0432\u0430</b>\n\n'
            f'MAC: <code>{mac}</code>\n'
        )
        if current:
            text += f'\u0422\u0435\u043a\u0443\u0449\u0435\u0435 \u0438\u043c\u044f: <b>{html.escape(current)}</b>\n'
        text += (
            '\n\u041e\u0442\u043f\u0440\u0430\u0432\u044c\u0442\u0435 \u043d\u043e\u0432\u043e\u0435 \u0438\u043c\u044f \u0441\u043b\u0435\u0434\u0443\u044e\u0449\u0438\u043c \u0441\u043e\u043e\u0431\u0449\u0435\u043d\u0438\u0435\u043c.\n'
            '<i>\u0414\u043e 32 \u0441\u0438\u043c\u0432\u043e\u043b\u043e\u0432.</i>'
        )
        await safe_edit(q, text, kb)

    async def _do_sync_known(self, q, ctx):
        await q.answer('Синхронизирую...')
        try:
            added = await sync_known_hosts_from_router()
        except Exception as e:
            log.exception('sync_known failed: %s', e)
            await q.answer('Ошибка: %s' % e, show_alert=True)
            return
        if added:
            await q.answer('Добавлено имён: %d' % added, show_alert=True)
        else:
            await q.answer('Новых имён с роутера нет', show_alert=True)
        await self._show_module_card(q, ctx)

    async def _do_autoname(self, mac, q, ctx):
        known = load_json(KNOWN_NAMES_FILE, {})
        if mac in known:
            del known[mac]
            save_json(KNOWN_NAMES_FILE, known)
            log.info('autoname reset for %s', mac)
        try:
            await asyncio.to_thread(remove_known_host_from_router, mac)
        except Exception as e:
            log.warning('router remove raised: %s', e)
        await self._show_device(mac, q, ctx)

    async def _handle_text(self, update, ctx):
        if str(update.effective_chat.id) != self.chat_id:
            return
        if not self._editing_name_mac:
            return
        raw = (update.message.text or '').strip()
        if not raw:
            return
        name = raw.replace('\n', ' ').replace('\r', '')
        if len(name) > 32:
            name = name[:32]
        mac = self._editing_name_mac
        msg_id = self._editing_name_msg_id
        self._editing_name_mac = None
        self._editing_name_msg_id = None

        known = load_json(KNOWN_NAMES_FILE, {})
        known[mac] = name
        save_json(KNOWN_NAMES_FILE, known)
        log.info('renamed %s -> %s', mac, name)

        try:
            ok = await asyncio.to_thread(push_known_host_to_router, name, mac)
            if not ok:
                log.warning('router push failed for %s', mac)
        except Exception as e:
            log.warning('router push raised: %s', e)

        try:
            await update.message.delete()
        except Exception:
            pass

        clients = await get_active_clients()
        blocked = load_json(BLOCKED_FILE, [])
        if mac in clients:
            info = clients[mac]
        else:
            names = load_json(KNOWN_NAMES_FILE, {})
            info = {
                'mac': mac, 'name': names.get(mac, mac),
                'ip': '\u043d\u0435 \u0432 \u0441\u0435\u0442\u0438', 'hostname': '',
                'ssdp_manufacturer': '', 'ssdp_model': '',
                'ssid': '', 'port': 0, 'speed': 0, 'duplex': False,
                'txrate': 0, 'mode': '', 'rssi': 0, 'uptime': 0,
                'rxbytes': 0, 'txbytes': 0,
            }
        card_text, card_kb = await build_device_card(info, blocked)
        card_kb = _prefix_kb(card_kb)
        rows = list(card_kb.inline_keyboard)
        rows.append([
            InlineKeyboardButton('\u270f\ufe0f \u041f\u0435\u0440\u0435\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u0442\u044c',
                                 callback_data=f'net_watch:rename:{mac}'),
            InlineKeyboardButton('\U0001f504 \u0410\u0432\u0442\u043e-\u0438\u043c\u044f',
                                 callback_data=f'net_watch:autoname:{mac}'),
        ])
        rows.append([
            InlineKeyboardButton('\u2b05\ufe0f \u041d\u0430\u0437\u0430\u0434',
                                 callback_data='net_watch:clients'),
            InlineKeyboardButton('\U0001f3e0 \u041c\u043e\u0434\u0443\u043b\u0438',
                                 callback_data='router:main'),
        ])
        card_kb = InlineKeyboardMarkup(rows)

        if msg_id:
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id,
                    message_id=msg_id,
                    text=card_text,
                    parse_mode='HTML',
                    reply_markup=card_kb,
                )
                return
            except Exception as e:
                log.warning('rename edit failed: %s', e)
        try:
            await ctx.bot.send_message(
                chat_id=self.chat_id,
                text=card_text,
                parse_mode='HTML',
                reply_markup=card_kb,
            )
        except Exception as e:
            log.warning('rename send failed: %s', e)


def _static_arp_macs() -> set:
    """MAC-и со статической ARP-записью (0x6)."""
    result = set()
    try:
        with open('/proc/net/arp') as f:
            for ln in f.readlines()[1:]:
                parts = ln.split()
                if len(parts) >= 4 and parts[2] == '0x6':
                    result.add(parts[3].lower())
    except Exception:
        pass
    return result

# ===================== known host: синк с роутером =====================

def _decode_keenetic_quoted(s):
    """Раскодирует строку Keenetic: hex-escape вида backslash-x-NN в UTF-8."""
    out = bytearray()
    i = 0
    while i < len(s):
        if i + 4 <= len(s) and s[i] == chr(92) and s[i+1] == 'x':
            try:
                out.append(int(s[i+2:i+4], 16))
                i += 4
                continue
            except ValueError:
                pass
        out.extend(s[i].encode('utf-8'))
        i += 1
    return out.decode('utf-8', errors='replace')


def parse_known_hosts_line(line):
    """Парсит строку 'known host <name> <mac>'.
    Возвращает (name, mac) или None."""
    s = line.strip()
    m = re.match(
        r'^known\s+host\s+'
        r'(?:"((?:[^"\\]|\\.)*)"|(\S+))'
        r'\s+([0-9a-fA-F:]{11,17})\s*$',
        s,
    )
    if not m:
        return None
    if m.group(1) is not None:
        name = _decode_keenetic_quoted(m.group(1))
    else:
        name = m.group(2)
    mac = m.group(3).lower()
    return name, mac


def fetch_router_known_hosts():
    """Возвращает {mac: name} из running-config роутера."""
    try:
        r = subprocess.run(
            ['/bin/ndmc', '-c', 'show running-config'],
            capture_output=True, text=True, timeout=10,
        )
        out = (r.stdout or '') + '\n' + (r.stderr or '')
    except Exception as e:
        log.warning('fetch known hosts failed: %s', e)
        return {}
    result = {}
    for line in out.splitlines():
        if 'known host' not in line:
            continue
        parsed = parse_known_hosts_line(line)
        if parsed:
            name, mac = parsed
            result[mac] = name
    return result


def push_known_host_to_router(name, mac):
    """known host \"<name>\" <mac> + save."""
    safe_name = name.replace('"', "'").strip()
    if not safe_name:
        return False
    if len(safe_name) > 64:
        safe_name = safe_name[:64]
    cmd = 'known host "%s" %s' % (safe_name, mac)
    try:
        r = subprocess.run(
            ['/bin/ndmc', '-c', cmd],
            capture_output=True, text=True, timeout=10,
        )
        out = (r.stdout or '') + (r.stderr or '')
        if r.returncode != 0 or 'error' in out.lower():
            log.warning('known host add failed: %s', out.strip()[:200])
            return False
        subprocess.run(
            ['/bin/ndmc', '-c', 'system configuration save'],
            capture_output=True, text=True, timeout=15,
        )
        log.info('router known host set: %s -> %s', mac, safe_name)
        return True
    except Exception as e:
        log.warning('known host push failed: %s', e)
        return False


def remove_known_host_from_router(mac):
    """no known host <mac> + save."""
    try:
        r = subprocess.run(
            ['/bin/ndmc', '-c', 'no known host %s' % mac],
            capture_output=True, text=True, timeout=10,
        )
        out = (r.stdout or '') + (r.stderr or '')
        if 'no such host' in out.lower():
            return True
        if r.returncode != 0 or 'error' in out.lower():
            log.warning('known host del failed: %s', out.strip()[:200])
            return False
        subprocess.run(
            ['/bin/ndmc', '-c', 'system configuration save'],
            capture_output=True, text=True, timeout=15,
        )
        log.info('router known host removed: %s', mac)
        return True
    except Exception as e:
        log.warning('known host remove failed: %s', e)
        return False


async def sync_known_hosts_from_router():
    """Читает known hosts с роутера и записывает в known_names.json
    ТОЛЬКО те MAC, которых там ещё нет.
    Возвращает количество добавленных."""
    router_hosts = await asyncio.to_thread(fetch_router_known_hosts)
    if not router_hosts:
        return 0
    local = load_json(KNOWN_NAMES_FILE, {})
    added = 0
    for mac, name in router_hosts.items():
        if mac in local:
            continue
        if not name:
            continue
        if name.lower().replace(':', '') == mac.replace(':', ''):
            continue
        if re.search(r'[0-9]{4}-[0-9]{2}-[0-9]{2}', name):
            continue
        local[mac] = name
        added += 1
    if added:
        save_json(KNOWN_NAMES_FILE, local)
    log.info('known hosts sync: %d added (total %d)', added, len(local))
    return added
RB_MODULES_NET_WATCH_MODULE_PY_EOF

echo "  → modules/ssh_control/__init__.py"
cat > /opt/router_bot/modules/ssh_control/__init__.py << 'RB_MODULES_SSH_CONTROL___INIT___PY_EOF'

RB_MODULES_SSH_CONTROL___INIT___PY_EOF

echo "  → modules/ssh_control/module.py"
cat > /opt/router_bot/modules/ssh_control/module.py << 'RB_MODULES_SSH_CONTROL_MODULE_PY_EOF'
"""Модуль SSH Control: управление устройствами по SSH."""
import asyncio
import html
import logging
import os
import tempfile

from telegram import (
    InlineKeyboardButton, InlineKeyboardMarkup, Update,
)
from telegram.ext import MessageHandler, filters, ContextTypes

from .ssh_client import (
    probe_fingerprint, run_command, InteractiveSSH, detect_question, run_script,
    get_last_probe_error,
)
from .storage import (
    load_hosts, add_host, remove_host, get_host,
)


log = logging.getLogger(__name__)

MAX_MSG = 3800
FILE_THRESHOLD = 7000

def _esc(s: str) -> str:
    return html.escape(s or '')

def _split(text: str, size: int = MAX_MSG):
    if not text:
        return ['']
    chunks = []
    cur = ''
    for line in text.splitlines(keepends=True):
        if len(cur) + len(line) > size:
            if cur:
                chunks.append(cur)
            cur = line
            while len(cur) > size:
                chunks.append(cur[:size])
                cur = cur[size:]
        else:
            cur += line
    if cur:
        chunks.append(cur)
    return chunks

def _extract_code_block(text: str):
    import re
    m = re.search(r'```(?:[a-zA-Z0-9_]*)\n(.*?)```', text, flags=re.DOTALL)
    if m:
        return m.group(1).rstrip('\n')
    m = re.search(r'```(.*?)```', text, flags=re.DOTALL)
    if m:
        return m.group(1).strip('\n')
    return text

def _is_script(text: str) -> bool:
    return '\n' in text.strip()

import re as _re
from core.utils import show_card, set_last_msg, get_last_msg

def _filter_ssh_noise(err: str) -> str:
    if not err:
        return ''
    lines = []
    for line in err.splitlines():
        low = line.lower()
        if 'warning: permanently added' in low:
            continue
        if 'warning: remote host identification has changed' in low:
            continue
        if _re.match(r'^connection to .+ closed\.?$', line.strip(), _re.IGNORECASE):
            continue
        lines.append(line)
    return '\n'.join(lines).strip()

class SSHControlModule:
    name = 'ssh_control'
    title = 'SSH Control'
    icon = '💻'
    description = 'управление устройствами по SSH'
    commands = [('ssh', '💻 SSH Control')]
    cleanup_paths = []
    cleanup_init = []

    def __init__(self, chat_id: str):
        self.chat_id = str(chat_id)
        self.state = 'idle'
        self.temp = {}
        self.active_hid = None
        self.prompt_msg_id = None
        self.interactive = None
        self.interactive_hid = None
        self.interactive_msg_id = None
        self.interactive_question_sent = False
        self.interactive_out_buffer = []
        self.current_script_proc = None

    async def startup(self, app):
        log.info('SSH Control: registering MessageHandler (group=50)')
        app.add_handler(MessageHandler(
            filters.TEXT & ~filters.COMMAND,
            self._handle_text,
        ), group=50)
        log.info('SSH Control module started (group=50)')

    async def send_card_message(self, update, ctx):
        hosts = load_hosts()
        text = (
            f'{self.icon} <b>{self.title}</b>\n'
            f'<i>{self.description}</i>\n'
            f'\n'
            f'Сохранённых хостов: <b>{len(hosts)}</b>'
        )
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('➕ Добавить хост', callback_data='ssh_control:add')],
            [InlineKeyboardButton('📋 Список хостов', callback_data='ssh_control:hosts')],
            [InlineKeyboardButton('🏠 Модули', callback_data='router:main')],
        ])
        await show_card(update, ctx, text, kb=kb)

    async def on_leave(self):
        if self.interactive:
            try:
                self.interactive.kill()
            except Exception:
                pass
        if self.current_script_proc:
            try:
                self.current_script_proc.kill()
            except Exception:
                pass
            self.current_script_proc = None
        self.state = 'idle'
        self.temp = {}
        self.active_hid = None
        self.prompt_msg_id = None
        self.interactive = None
        self.interactive_hid = None
        self.interactive_msg_id = None
        self.interactive_question_sent = False
        self.interactive_out_buffer = []

    async def handle_callback(self, action: str, q, ctx):
        await q.answer()

        if action == 'main':
            return await self._show_card(q, ctx)
        if action == 'add':
            return await self._start_wizard(q, ctx)
        if action == 'hosts':
            return await self._show_hosts(q, ctx)
        if action == 'cancel':
            return await self._cancel(q, ctx)
        if action == 'port_default':
            return await self._wizard_port_default(q, ctx)
        if action == 'fp_accept':
            return await self._fp_accept(q, ctx)
        if action == 'fp_reject':
            return await self._fp_reject(q, ctx)
        if action.startswith('host:'):
            return await self._show_host(action[5:], q, ctx)
        if action.startswith('exec:'):
            return await self._start_exec(action[5:], q, ctx)
        if action.startswith('delete_ask:'):
            return await self._delete_ask(action[11:], q, ctx)
        if action.startswith('delete_ok:'):
            return await self._delete_ok(action[10:], q, ctx)
        if action == 'answer:y':
            return await self._answer_question(q, ctx, b'y\n')
        if action == 'answer:n':
            return await self._answer_question(q, ctx, b'n\n')
        if action == 'answer:enter':
            return await self._answer_question(q, ctx, b'\n')
        if action == 'answer:kill':
            return await self._kill_interactive(q, ctx)
        if action == 'abort':
            return await self._abort_interactive(q, ctx)
        if action == 'abort_script':
            return await self._abort_script(q, ctx)
    async def _show_card(self, q, ctx):
        hosts = load_hosts()
        text = (
            f'{self.icon} <b>{self.title}</b>\n'
            f'<i>{self.description}</i>\n'
            f'\n'
            f'Сохранённых хостов: <b>{len(hosts)}</b>'
        )
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('➕ Добавить хост', callback_data='ssh_control:add')],
            [InlineKeyboardButton('📋 Список хостов', callback_data='ssh_control:hosts')],
            [InlineKeyboardButton('🏠 Модули', callback_data='router:main')],
        ])
        await self._edit(q, text, kb)

    async def _show_hosts(self, q, ctx):
        hosts = load_hosts()
        if not hosts:
            text = (
                f'{self.icon} <b>Список хостов</b>\n\n'
                f'<i>Пусто. Добавьте первый хост.</i>'
            )
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('➕ Добавить хост', callback_data='ssh_control:add')],
                [
                    InlineKeyboardButton('⬅️ Назад', callback_data='ssh_control:main'),
                    InlineKeyboardButton('🏠 Модули', callback_data='router:main'),
                ],
            ])
            return await self._edit(q, text, kb)

        lines = [f'{self.icon} <b>Список хостов ({len(hosts)})</b>', '']
        rows = []
        for hid, h in hosts.items():
            label = f"🖥 {h['user']}@{h['ip']}:{h['port']}"
            rows.append([InlineKeyboardButton(
                label, callback_data=f'ssh_control:host:{hid}',
            )])
        rows.append([
            InlineKeyboardButton('➕ Добавить', callback_data='ssh_control:add'),
            InlineKeyboardButton('⬅️ Назад', callback_data='ssh_control:main'),
        ])
        rows.append([
            InlineKeyboardButton('🏠 Модули', callback_data='router:main'),
        ])
        await self._edit(q, '\n'.join(lines), InlineKeyboardMarkup(rows))

    async def _show_host(self, hid, q, ctx):
        h = get_host(hid)
        if not h:
            return await self._show_hosts(q, ctx)
        text = (
            f"🖥 <b>{_esc(h['user'])}@{_esc(h['ip'])}:{h['port']}</b>\n"
            f"<i>Добавлен: {_esc(h.get('added', '?'))}</i>"
        )
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('💬 Выполнить команду', callback_data=f'ssh_control:exec:{hid}')],
            [InlineKeyboardButton('🗑 Удалить', callback_data=f'ssh_control:delete_ask:{hid}')],
            [
                InlineKeyboardButton('⬅️ Назад', callback_data='ssh_control:hosts'),
                InlineKeyboardButton('🏠 Модули', callback_data='router:main'),
            ],
        ])
        await self._edit(q, text, kb)

    async def _delete_ask(self, hid, q, ctx):
        h = get_host(hid)
        if not h:
            return await self._show_hosts(q, ctx)
        text = (
            f"🗑 <b>Удалить хост?</b>\n\n"
            f"{_esc(h['user'])}@{_esc(h['ip'])}:{h['port']}\n"
            f"<i>Действие необратимо.</i>"
        )
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('🗑 Да, удалить', callback_data=f'ssh_control:delete_ok:{hid}')],
            [
                InlineKeyboardButton('⬅️ Отмена', callback_data=f'ssh_control:host:{hid}'),
                InlineKeyboardButton('🏠 Модули', callback_data='router:main'),
            ],
        ])
        await self._edit(q, text, kb)

    async def _delete_ok(self, hid, q, ctx):
        remove_host(hid)
        await self._show_hosts(q, ctx)

    async def _start_wizard(self, q, ctx):
        log.info('ssh_control _start_wizard: set state=wizard:ip')
        self.state = 'wizard:ip'
        self.temp = {}
        text = (
            f"➕ <b>Добавление SSH-хоста</b>\n\n"
            f"<b>Шаг 1/4.</b> Отправьте IP-адрес или hostname:\n"
            f"<i>Например: 192.168.1.1 или nas.local</i>"
        )
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('❌ Отмена', callback_data='ssh_control:cancel')],
        ])
        await self._edit(q, text, kb)

    async def _wizard_port_default(self, q, ctx):
        self.temp['port'] = 22
        self.state = 'wizard:user'
        await q.edit_message_text(
            f"<b>Шаг 3/4.</b> Отправьте имя пользователя:\n"
            f"<i>Например: root или admin</i>",
            parse_mode='HTML',
        )

    async def _cancel(self, q, ctx):
        self.state = 'idle'
        self.temp = {}
        await self._show_card(q, ctx)

    async def _start_exec(self, hid, q, ctx):
        h = get_host(hid)
        if not h:
            return await self._show_hosts(q, ctx)
        self.active_hid = hid
        self.state = f'exec:{hid}'
        text = (
            f"💬 <b>Команда для {_esc(h['user'])}@{_esc(h['ip'])}</b>\n\n"
            f"Одна строка → команда с интерактивом (y/n).\n"
            f"Несколько строк → единый скрипт (cd, переменные, &&).\n\n"
            f"<b>Примеры:</b>\n"
            f"<code>uname -a</code>\n"
            f"<code>cd /tmp\nmkdir test\nls -la</code>\n\n"
            f"⚠️ <b>Не используйте в командах:</b>\n"
            f"• тройные кавычки <code>\"\"\"</code> или <code>\x27\x27\x27</code> "
            f"— shell видит незакрытую кавычку и падает;\n"
            f"• тройные бэктики <code>```</code> — Telegram-клиент "
            f"срезает их как markdown-разметку до отправки.\n\n"
            f"Обычные одиночные и двойные кавычки работают нормально."
        )
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('🚪 Выйти из exec', callback_data=f'ssh_control:host:{hid}')],
            [InlineKeyboardButton('🏠 Модули', callback_data='router:main')],
        ])
        await self._edit(q, text, kb)

    async def _handle_text(self, update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        log.info('ssh_control _handle_text CALLED: state=%s', self.state)
        if not update.message:
            log.info('ssh_control _handle_text: no update.message')
            return
        text = (update.message.text or '').strip()
        if not text:
            return
        log.info('ssh_control _handle_text: text=%r, state=%s', text, self.state)
        if self.state == 'wizard:ip':
            return await self._wizard_ip(update, ctx, text)
        if self.state == 'wizard:port':
            return await self._wizard_port(update, ctx, text)
        if self.state == 'wizard:user':
            return await self._wizard_user(update, ctx, text)
        if self.state == 'wizard:pass':
            return await self._wizard_pass(update, ctx, text)
        if self.state.startswith('exec:'):
            hid = self.state[5:]
            return await self._exec_command(update, ctx, hid, text)
        log.info('ssh_control _handle_text: state %s ignored', self.state)

    async def _wizard_ip(self, update, ctx, text):
        self.temp['ip'] = text
        self.state = 'wizard:port'
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('✅ Порт 22 (по умолчанию)', callback_data='ssh_control:port_default')],
            [InlineKeyboardButton('❌ Отмена', callback_data='ssh_control:cancel')],
        ])
        await show_card(update, ctx,
            f"<b>Шаг 2/4.</b> Отправьте порт SSH или нажмите кнопку ниже:",
            kb)

    async def _wizard_port(self, update, ctx, text):
        try:
            port = int(text)
            if not (1 <= port <= 65535):
                raise ValueError
        except ValueError:
            await show_card(update, ctx, '❌ Порт должен быть числом 1–65535. Попробуйте снова.')
            return
        self.temp['port'] = port
        self.state = 'wizard:user'
        await show_card(update, ctx,
            f"<b>Шаг 3/4.</b> Отправьте имя пользователя:",
        )

    async def _wizard_user(self, update, ctx, text):
        self.temp['user'] = text
        self.state = 'wizard:pass'
        await show_card(update, ctx,
            f"<b>Шаг 4/4.</b> Отправьте пароль.\n\n"
            f"⚠️ Я сразу удалю его из чата.",
        )
    async def _wizard_pass(self, update, ctx, text):
        log.info('wizard:pass received password len=%d', len(text))
        self.temp['password'] = text
        # Удаляем сообщение с паролем (если ещё не удалено)
        try:
            await update.message.delete()
        except Exception:
            pass

        ip = self.temp.get('ip', '')
        port = self.temp.get('port', 22)
        log.info('wizard:pass probing %s:%s', ip, port)

        status_msg_id = await show_card(update, ctx,
            f'🔐 Проверяю SSH-хост...\n\n'
            f'<code>{_esc(ip)}:{port}</code>\n'
            f'<i>Может занять до 20 секунд.</i>',
        )
        if not status_msg_id:
            return

        try:
            probe = await probe_fingerprint(ip, port, timeout=20)
            log.info('wizard:pass probe result=%s', probe)
        except Exception as e:
            log.exception('wizard:pass probe raised: %s', e)
            probe = None

        if not probe:
            err = get_last_probe_error() or 'неизвестная ошибка'
            log.warning('wizard:pass FAIL: %s', err)
            self.state = 'idle'
            self.temp = {}
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id,
                    message_id=status_msg_id,
                    text=(
                        f'❌ <b>Не удалось подключиться</b>\n\n'
                        f'Хост: <code>{_esc(ip)}:{port}</code>\n'
                        f'Ошибка: <i>{_esc(err)}</i>'
                    ),
                    parse_mode='HTML',
                    reply_markup=InlineKeyboardMarkup([
                        [InlineKeyboardButton('🔁 Заново',
                                              callback_data='ssh_control:add')],
                        [InlineKeyboardButton('⬅️ К модулю',
                                              callback_data='ssh_control:main')],
                    ]),
                )
            except Exception as e:
                log.warning('edit error status: %s', e)
            return

        self.temp['fingerprint'] = probe['fingerprint']
        self.temp['key_type'] = probe['key_type']
        self.state = 'wizard:fp'
        log.info('wizard:pass OK fp=%s', probe['fingerprint'][:30])

        try:
            await ctx.bot.edit_message_text(
                chat_id=self.chat_id,
                message_id=status_msg_id,
                text=(
                    f'🔐 <b>Проверка SSH host key</b>\n\n'
                    f'Хост: <code>{_esc(ip)}:{port}</code>\n'
                    f'Юзер: <code>{_esc(self.temp.get("user",""))}</code>\n\n'
                    f'Тип: <code>{_esc(probe["key_type"] or "?")}</code>\n'
                    f'Fingerprint:\n<code>{_esc(probe["fingerprint"])}</code>\n\n'
                    f'✅ Принять и сохранить хост?'
                ),
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton('✅ Принять',
                                          callback_data='ssh_control:fp_accept')],
                    [InlineKeyboardButton('❌ Отмена',
                                          callback_data='ssh_control:cancel')],
                ]),
            )
        except Exception as e:
            log.warning('edit fp status: %s', e)

    async def _try_delete_msg(self, ctx, chat_id, msg_id):
        try:
            await ctx.bot.delete_message(chat_id=chat_id, message_id=msg_id)
        except Exception:
            pass
        return True

    async def _delete_retry(self, ctx):
        data = ctx.job.data
        await self._try_delete_msg(ctx, data['chat_id'], data['msg_id'])


    async def _fp_accept(self, q, ctx):
        ip = self.temp.get('ip')
        port = self.temp.get('port', 22)
        user = self.temp.get('user')
        password = self.temp.get('password')
        fingerprint = self.temp.get('fingerprint', '')
        key_type = self.temp.get('key_type', '')

        if not all([ip, user, password]):
            self.state = 'idle'
            self.temp = {}
            await q.answer('Данные потеряны, начните заново', show_alert=True)
            return

        hid = add_host(ip, port, user, password, fingerprint, key_type)
        self.state = 'idle'
        self.temp = {}
        await q.answer('✅ Хост сохранён')
        try:
            await q.edit_message_text(
                f'✅ <b>Хост добавлен</b>\n\n'
                f'<code>{_esc(user)}@{_esc(ip)}:{port}</code>',
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton('💬 Выполнить команду',
                                          callback_data=f'ssh_control:exec:{hid}')],
                    [InlineKeyboardButton('📋 Список хостов',
                                          callback_data='ssh_control:hosts')],
                    [InlineKeyboardButton('🏠 Модули',
                                          callback_data='router:main')],
                ]),
            )
        except Exception as e:
            log.warning('fp_accept edit failed: %s', e)

    async def _fp_reject(self, q, ctx):
        self.state = 'idle'
        self.temp = {}
        await q.answer('Отклонено')
        await self._show_card(q, ctx)

    async def _delete_retry(self, ctx):
        data = ctx.job.data
        await self._try_delete_msg(ctx, data['chat_id'], data['msg_id'])

    async def _exec_command(self, update, ctx, hid, command):
        h = get_host(hid)
        if not h:
            self.state = 'idle'
            self.active_hid = None
            await show_card(update, ctx, '❌ Хост не найден.')
            return

        if self.interactive:
            try:
                self.interactive.kill()
            except Exception:
                pass

        raw = command
        code = _extract_code_block(raw)
        is_script = _is_script(code)

        if is_script:
            await self._run_script_block(update, ctx, hid, h, code, raw)
            return

        self.state = f'exec:{hid}'
        self.active_hid = hid
        self.interactive_hid = hid
        self.interactive_question_sent = False
        self.interactive_out_buffer = []

        msg_id = await show_card(update, ctx,
            f"⏳ Выполняю: <code>{_esc(code[:200])}</code>",
            InlineKeyboardMarkup([
                [InlineKeyboardButton('🛑 Отменить', callback_data='ssh_control:abort')],
            ]),
        )
        self.interactive_msg_id = msg_id

        sess = InteractiveSSH(
            h['ip'], h['port'], h['user'], h['password'],
            code, h['fingerprint'], timeout=600,
        )

        async def on_data(chunk: bytes):
            await self._on_interactive_data(ctx, chunk)

        try:
            await sess.start(on_data)
            self.interactive = sess
        except Exception as e:
            try:
                await ctx.bot.edit_message_text(
                    chat_id=update.effective_chat.id,
                    message_id=msg_id,
                    text=f"❌ <b>Ошибка запуска</b>\n\n<i>{_esc(str(e))}</i>",
                    parse_mode='HTML',
                )
            except Exception:
                pass
            self.state = f'exec:{hid}'
            return

        asyncio.create_task(self._wait_interactive(ctx, update.effective_chat.id, sess, hid))

    async def _run_script_block(self, update, ctx, hid, h, script, raw):
        self.state = f'exec:{hid}'
        self.active_hid = hid

        status_msg_id = await show_card(update, ctx,
            f'⏳ Выполняю блок ({len(script.splitlines())} строк)...',
            InlineKeyboardMarkup([
                [InlineKeyboardButton('🛑 Отменить', callback_data='ssh_control:abort_script')],
            ]),
        )

        def _save_proc(p):
            self.current_script_proc = p

        try:
            out, err, rc = await run_script(
                h['ip'], h['port'], h['user'], h['password'],
                script, h['fingerprint'], timeout=180,
                on_proc=_save_proc,
            )
        except Exception as e:
            kb = InlineKeyboardMarkup([
                        [InlineKeyboardButton('⬅️ Назад', callback_data=f'ssh_control:host:{hid}'),
                 InlineKeyboardButton('🏠 Модули', callback_data='router:main')],
            ])
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id, message_id=status_msg_id,
                    text=f'❌ <b>Ошибка</b>\n\n<i>{_esc(str(e))}</i>',
                    parse_mode='HTML', reply_markup=kb,
                )
            except Exception:
                pass
            return

        out_clean = _filter_ssh_noise(out or '')
        err_clean = _filter_ssh_noise(err)
        body = out_clean
        if err_clean:
            body += ('\n' if body else '') + f'[stderr]\n{err_clean}'

        header = f'$ script [{len(script.splitlines())} lines]\n[exit code: {rc}]\n\n'
        full = header + body
        hint = 'Напишите текст — выполнится следующая команда.'

        kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('⬅️ Назад', callback_data=f'ssh_control:host:{hid}'),
             InlineKeyboardButton('🏠 Модули', callback_data='router:main')],
        ])

        try:
            if len(full) <= 3800:
                text_out = f"<pre>{_esc(full)}</pre>\n\n<i>{hint}</i>"
            else:
                text_out = (f"<pre>{_esc(full[:3600])}</pre>\n"
                            f"<i>…логи обрезаны. Полный лог: /opt/var/log/router_bot.log</i>\n\n"
                            f"<i>{hint}</i>")
            await ctx.bot.edit_message_text(
                chat_id=self.chat_id, message_id=status_msg_id,
                text=text_out, parse_mode='HTML', reply_markup=kb,
            )
        except Exception as e:
            log.debug('script block edit: %s', e)

        self.state = f'exec:{hid}'
        self.active_hid = hid

    async def _on_interactive_data(self, ctx, chunk: bytes):
        self.interactive_out_buffer.append(chunk)
        if self.interactive_msg_id:
            buf_text = b''.join(self.interactive_out_buffer).decode('utf-8', errors='replace')
            buf_text = _filter_ssh_noise(buf_text)
            preview = buf_text[-1500:] if len(buf_text) > 1500 else buf_text
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id,
                    message_id=self.interactive_msg_id,
                    text=f"<pre>{_esc(preview)}</pre>",
                    parse_mode='HTML',
                    reply_markup=InlineKeyboardMarkup([
                        [InlineKeyboardButton('🛑 Отменить', callback_data='ssh_control:abort')],
                    ]),
                )
            except Exception:
                pass

        if self.interactive_question_sent:
            return
        buf = b''.join(self.interactive_out_buffer)
        if detect_question(buf[-500:]):
            await self._send_question(ctx)

    async def _send_question(self, ctx):
        buf = b''.join(self.interactive_out_buffer).decode('utf-8', errors='replace')
        tail = buf[-400:] if len(buf) > 400 else buf
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('\u2705 Да (y)', callback_data='ssh_control:answer:y'),
             InlineKeyboardButton('\u274c Нет (n)', callback_data='ssh_control:answer:n')],
            [InlineKeyboardButton('\u23ce Enter', callback_data='ssh_control:answer:enter'),
             InlineKeyboardButton('\U0001f6d1 Прервать', callback_data='ssh_control:answer:kill')],
        ])
        if self.interactive_msg_id:
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id,
                    message_id=self.interactive_msg_id,
                    text=f"\u2753 <b>Требуется ответ</b>\n\n<pre>{_esc(tail)}</pre>",
                    parse_mode='HTML',
                    reply_markup=kb,
                )
                self.interactive_question_sent = True
                return
            except Exception as e:
                log.debug('send_question edit: %s', e)
        try:
            m = await ctx.bot.send_message(
                chat_id=self.chat_id,
                text=f"\u2753 <b>Требуется ответ</b>\n\n<pre>{_esc(tail)}</pre>",
                parse_mode='HTML',
                reply_markup=kb,
            )
            self.interactive_question_sent = True
            self.interactive_msg_id = m.message_id
        except Exception as e:
            log.warning('send_question failed: %s', e)

    async def _answer_question(self, q, ctx, data: bytes):
        if not self.interactive:
            await q.answer('Сессия уже завершена', show_alert=True)
            return
        await self.interactive.send(data)
        await q.answer(f'Отправлено: {data.decode().strip() or "Enter"}')
        try:
            await q.message.delete()
        except Exception:
            pass
        self.interactive_question_sent = False

    async def _kill_interactive(self, q, ctx):
        if self.interactive:
            try:
                self.interactive.kill()
            except Exception:
                pass
        await q.answer('Прервано')
        try:
            await q.message.delete()
        except Exception:
            pass

    async def _abort_interactive(self, q, ctx):
        if not self.interactive:
            await q.answer('Уже завершено', show_alert=False)
            return
        try:
            self.interactive.kill()
        except Exception:
            pass
        await q.answer('🛑 Прервано')

    async def _abort_script(self, q, ctx):
        if not self.current_script_proc:
            await q.answer('Уже завершено', show_alert=False)
            return
        try:
            self.current_script_proc.kill()
        except Exception:
            pass
        self.current_script_proc = None
        await q.answer('🛑 Прервано')

    async def _wait_interactive(self, ctx, chat_id, sess, hid):
        rc = await sess.wait(timeout=600)
        self.interactive = None
        self.interactive_question_sent = False

        full_text = b''.join(self.interactive_out_buffer).decode('utf-8', errors='replace')
        header = f"[exit code: {rc}]\n\n"
        body = header + full_text
        if not body.strip():
            body = header + '(пусто)'

        kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('⬅️ Назад', callback_data=f'ssh_control:host:{hid}'),
             InlineKeyboardButton('🏠 Модули', callback_data='router:main')],
        ])
        hint = 'Напишите текст — выполнится следующая команда.'

        if self.interactive_msg_id:
            try:
                if len(body) <= MAX_MSG:
                    text_out = f"<pre>{_esc(body)}</pre>\n\n<i>{hint}</i>"
                else:
                    text_out = (f"<pre>{_esc(body[:MAX_MSG - 400])}</pre>\n"
                                f"<i>…логи обрезаны. Полный лог: /opt/var/log/router_bot.log</i>\n\n"
                                f"<i>{hint}</i>")
                await ctx.bot.edit_message_text(
                    chat_id=chat_id,
                    message_id=self.interactive_msg_id,
                    text=text_out,
                    parse_mode='HTML',
                    reply_markup=kb,
                )
                self.interactive_msg_id = None
                self.interactive_out_buffer = []
                self.state = f'exec:{hid}'
                self.active_hid = hid
                return
            except Exception as e:
                log.debug('wait_interactive edit: %s', e)
                self.interactive_msg_id = None

        try:
            if len(body) <= MAX_MSG:
                text_out = f"<pre>{_esc(body)}</pre>\n\n<i>{hint}</i>"
            else:
                text_out = (f"<pre>{_esc(body[:MAX_MSG - 400])}</pre>\n"
                            f"<i>…логи обрезаны. Полный лог: /opt/var/log/router_bot.log</i>\n\n"
                            f"<i>{hint}</i>")
            msg = await ctx.bot.send_message(
                chat_id=chat_id, text=text_out,
                parse_mode='HTML', reply_markup=kb,
            )
            set_last_msg(chat_id, msg.message_id)
        except Exception as e:
            log.warning('wait_interactive send failed: %s', e)

        self.interactive_out_buffer = []
        self.state = f'exec:{hid}'
        self.active_hid = hid

    async def _send_block(self, update, text):
        try:
            await show_card(update, update.message.chat_id, f"<pre>{_esc(text)}</pre>")
        except Exception:
            pass

    async def _edit(self, q, text, kb):
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            set_last_msg(self.chat_id, q.message.message_id)
        except Exception as e:
            if 'not modified' in str(e).lower():
                return
            bot = q.get_bot() if hasattr(q, 'get_bot') else q.message.get_bot()
            msg = await bot.send_message(
                chat_id=self.chat_id, text=text, parse_mode='HTML', reply_markup=kb
            )
            set_last_msg(self.chat_id, msg.message_id)
RB_MODULES_SSH_CONTROL_MODULE_PY_EOF

echo "  → modules/ssh_control/ssh_client.py"
cat > /opt/router_bot/modules/ssh_control/ssh_client.py << 'RB_MODULES_SSH_CONTROL_SSH_CLIENT_PY_EOF'
"""SSH-клиент через OpenSSH (ssh, ssh-keygen). Без paramiko."""
import asyncio
import logging
import os
import re
import subprocess
import tempfile

log = logging.getLogger(__name__)

SSH = '/opt/bin/ssh'
SSH_KEYGEN = '/opt/bin/ssh-keygen'


def _run_sync(cmd):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        return p.stdout, p.stderr, p.returncode
    except Exception:
        return '', '', -1
async def _run(cmd, env=None, timeout=30):
    log.info('ssh_run: %s', ' '.join(cmd[:8]))
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env=env,
        start_new_session=True,
    )
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        log.warning('ssh_run TIMEOUT %sс, kill...', timeout)
        try:
            proc.kill()
        except Exception as e:
            log.warning('kill failed: %s', e)
        try:
            await asyncio.wait_for(proc.wait(), timeout=2)
        except asyncio.TimeoutError:
            log.warning('kill did not work, SIGKILL')
            import signal as _sig
            try:
                os.killpg(os.getpgid(proc.pid), _sig.SIGKILL)
            except Exception as e:
                log.warning('killpg failed: %s', e)
            try:
                await asyncio.wait_for(proc.wait(), timeout=2)
            except Exception:
                pass
        except Exception:
            pass
        raise TimeoutError(f'Таймаут {timeout}с')
    out_s = out.decode('utf-8', errors='replace')
    err_s = err.decode('utf-8', errors='replace')
    log.info('ssh_run: rc=%s out=%dB err=%dB', proc.returncode,
             len(out_s), len(err_s))
    if err_s.strip():
        log.info('ssh_run stderr: %s', err_s.strip()[:300])
    return out_s, err_s, proc.returncode




def _parse_known_hosts(path):
    """Возвращает (fingerprint_sha256, key_type)."""
    if not os.path.exists(path):
        return None, None
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split()
            if len(parts) < 3:
                continue
            key_type, b64 = parts[1], parts[2]
            with tempfile.NamedTemporaryFile('w', suffix='.pub', delete=False) as kf:
                kf.write(f'{key_type} {b64}\n')
                key_file = kf.name
            try:
                out, err, rc = _run_sync([SSH_KEYGEN, '-lf', key_file, '-E', 'sha256'])
                if out:
                    m = re.search(r'(SHA256:[A-Za-z0-9+/=]+)', out)
                    if m:
                        return m.group(1), key_type
            finally:
                try:
                    os.unlink(key_file)
                except Exception:
                    pass
    return None, None


_last_probe_error = ''

def get_last_probe_error() -> str:
    return _last_probe_error
async def probe_fingerprint(host, port=22, timeout=10):
    """Подключается, заставляет ssh записать host key, парсит fingerprint."""
    global _last_probe_error
    _last_probe_error = ''

    with tempfile.TemporaryDirectory() as tmp:
        kh = os.path.join(tmp, 'known_hosts')
        open(kh, 'w').close()

        env = os.environ.copy()
        env['SSH_ASKPASS'] = '/bin/true'
        env['SSH_ASKPASS_REQUIRE'] = 'force'
        env['DISPLAY'] = ':0'

        try:
            out, err, rc = await _run(
                [
                    SSH,
                    '-o', 'StrictHostKeyChecking=accept-new',
                    '-o', f'UserKnownHostsFile={kh}',
                    '-o', 'ConnectTimeout=5',
                    '-o', 'NumberOfPasswordPrompts=0',
                    '-o', 'BatchMode=yes',
                    '-o', 'PreferredAuthentications=none',
                    '-p', str(port),
                    f'probe@{host}',
                    'true',
                ],
                env=env,
                timeout=timeout,
            )
        except TimeoutError:
            _last_probe_error = f'Таймаут {timeout}с — хост не отвечает'
            log.warning('probe timeout %s:%s', host, port)
            return None
        except Exception as e:
            _last_probe_error = f'{type(e).__name__}: {e}'
            log.warning('probe error: %s', e)
            return None

        fp, kt = _parse_known_hosts(kh)
        if not fp:
            err_clean = (err or '').strip()
            low = err_clean.lower()
            if 'connection refused' in low:
                _last_probe_error = f'Соединение отклонено (порт {port} закрыт?)'
            elif 'no route to host' in low:
                _last_probe_error = 'Нет маршрута до хоста'
            elif 'timed out' in low or 'timeout' in low:
                _last_probe_error = 'Хост недоступен (timeout)'
            elif 'connection reset' in low:
                _last_probe_error = 'Соединение сброшено'
            elif 'permission denied' in low:
                _last_probe_error = 'Permission denied'
            elif err_clean:
                _last_probe_error = err_clean[:400]
            else:
                _last_probe_error = f'ssh rc={rc} без stderr (порт {port})'
            log.warning('probe FAIL %s:%s rc=%s err=%s',
                        host, port, rc, err_clean[:200])
            return None
        return {'fingerprint': fp, 'key_type': kt}




async def run_command(host, port, user, password, command,
                      expected_fp, timeout=60):
    """Выполняет команду. Возвращает (stdout, stderr, exit_code)."""
    with tempfile.TemporaryDirectory() as tmp:
        kh = os.path.join(tmp, 'known_hosts')
        askpass = os.path.join(tmp, 'askpass.sh')
        with open(askpass, 'w') as f:
            f.write('#!/bin/sh\nprintf \'%s\\n\' "$SSH_PASS"\n')
        os.chmod(askpass, 0o700)

        probe = await probe_fingerprint(host, port, timeout=10)
        if not probe:
            raise ConnectionError(f'Не удалось получить SSH host key от {host}:{port}')
        if expected_fp and probe['fingerprint'] != expected_fp:
            raise ConnectionError(
                f'⚠️ Fingerprint изменился!\n'
                f'Ожидали: {expected_fp}\n'
                f'Получили: {probe["fingerprint"]}'
            )

        env = os.environ.copy()
        env['SSH_PASS'] = password
        env['SSH_ASKPASS'] = askpass
        env['SSH_ASKPASS_REQUIRE'] = 'force'
        env['DISPLAY'] = ':0'

        out, err, rc = await _run(
            [
                SSH,
                '-o', 'StrictHostKeyChecking=accept-new',
                '-o', f'UserKnownHostsFile={kh}',
                '-o', 'NumberOfPasswordPrompts=1',
                '-o', 'ConnectTimeout=10',
                '-o', 'BatchMode=no',
                '-o', 'ServerAliveInterval=5',
                '-o', 'ServerAliveCountMax=2',
                '-p', str(port),
                f'{user}@{host}',
                command,
            ],
            env=env,
            timeout=timeout,
        )

        if rc != 0 and not out:
            low = (err or '').lower()
            if 'permission denied' in low or 'authentication failed' in low:
                raise PermissionError('Неверный логин или пароль')
            if 'connection refused' in low:
                raise ConnectionError('Соединение отклонено (порт закрыт?)')
            if 'no route to host' in low or 'timed out' in low or 'timeout' in low:
                raise ConnectionError('Хост недоступен')
            if 'host key verification failed' in low:
                raise ConnectionError('Не удалось проверить host key')

        return out, err, rc


# ==================== Interactive ====================

QUESTION_PATTERNS = [
    b'(y/n)', b'[y/n]', b'[Y/n]', b'[y/N]',
    b'(yes/no)', b'[yes/no]',
    b'Password:', b'password:',
    b'Are you sure', b'are you sure',
    b'Continue', b'continue?',
    b'Proceed', b'proceed?',
    b'Do you want',
]


def detect_question(buf: bytes):
    """Возвращает True если в буфере похоже на вопрос."""
    low = buf.lower()
    for p in QUESTION_PATTERNS:
        if p.lower() in low:
            return True
    return False


class InteractiveSSH:
    """Долгоживущая SSH-сессия с управлением stdin."""

    def __init__(self, host, port, user, password, command,
                 expected_fp, timeout=300):
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.command = command
        self.expected_fp = expected_fp
        self.timeout = timeout
        self.proc = None
        self.buffer = b''
        self._read_task = None
        self._on_data = None      # async callable(bytes)
        self._closed = False

    async def start(self, on_data):
        """Запускает ssh -tt. on_data(chunk) вызывается на каждый чанк."""
        import shutil
        self._on_data = on_data

        probe = await probe_fingerprint(self.host, self.port, timeout=10)
        if not probe:
            raise ConnectionError(
                f'Не удалось получить SSH host key от {self.host}:{self.port}')
        if self.expected_fp and probe['fingerprint'] != self.expected_fp:
            raise ConnectionError(
                f'⚠️ Fingerprint изменился! '
                f'Ожидали {self.expected_fp}, получили {probe["fingerprint"]}'
            )

        # ВАЖНО: директория живёт до конца сессии
        self._tmpdir = tempfile.mkdtemp(prefix='ssh_ctrl_')
        kh = os.path.join(self._tmpdir, 'known_hosts')
        askpass = os.path.join(self._tmpdir, 'askpass.sh')
        open(kh, 'w').close()
        with open(askpass, 'w') as f:
            f.write('#!/bin/sh\nprintf \'%s\\n\' "$SSH_PASS"\n')
        os.chmod(askpass, 0o700)

        env = os.environ.copy()
        env['SSH_PASS'] = self.password
        env['SSH_ASKPASS'] = askpass
        env['SSH_ASKPASS_REQUIRE'] = 'force'
        env['DISPLAY'] = ':0'

        self.proc = await asyncio.create_subprocess_exec(
            SSH,
            '-tt',
            '-o', 'StrictHostKeyChecking=accept-new',
            '-o', f'UserKnownHostsFile={kh}',
            '-o', 'NumberOfPasswordPrompts=1',
            '-o', 'ConnectTimeout=10',
            '-o', 'BatchMode=no',
            '-o', 'ServerAliveInterval=10',
            '-o', 'ServerAliveCountMax=3',
            '-p', str(self.port),
            f'{self.user}@{self.host}',
            self.command,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )

        self._read_task = asyncio.create_task(self._read_loop())


    async def _read_loop(self):
        try:
            while True:
                chunk = await asyncio.wait_for(
                    self.proc.stdout.read(256), timeout=self.timeout,
                )
                if not chunk:
                    break
                self.buffer += chunk
                if self._on_data:
                    try:
                        await self._on_data(chunk)
                    except Exception as e:
                        log.warning('on_data error: %s', e)
        except asyncio.TimeoutError:
            log.warning('interactive session timeout')
        except Exception as e:
            log.warning('read_loop error: %s', e)
        finally:
            self._closed = True

    async def send(self, data: bytes):
        """Пишет в stdin сессии."""
        if self.proc and self.proc.stdin and not self.proc.stdin.is_closing():
            self.proc.stdin.write(data)
            try:
                await self.proc.stdin.drain()
            except Exception as e:
                log.warning('send drain error: %s', e)

    async def wait(self, timeout=300):
        try:
            rc = await asyncio.wait_for(self.proc.wait(), timeout=timeout)
        except asyncio.TimeoutError:
            self.kill()
            return -1
        if self._read_task:
            try:
                await self._read_task
            except Exception:
                pass
        self._cleanup_tmp()
        return rc

    def _cleanup_tmp(self):
        import shutil
        if getattr(self, '_tmpdir', None):
            try:
                shutil.rmtree(self._tmpdir, ignore_errors=True)
            except Exception:
                pass
            self._tmpdir = None

    def kill(self):
        if self.proc:
            try:
                self.proc.kill()
            except Exception:
                pass
        self._cleanup_tmp()

    def is_running(self):
        return self.proc and self.proc.returncode is None


async def run_script(host, port, user, password, script,
                     expected_fp, timeout=90, shell='sh -s', on_proc=None):
    """Выполняет многострочный скрипт через ssh, передавая его в stdin.

    Использует `sh -s` (или `bash -s`) на удалённой стороне —
    скрипт читается из stdin. Так можно отправлять блоки команд.
    """
    with tempfile.TemporaryDirectory() as tmp:
        kh = os.path.join(tmp, 'known_hosts')
        askpass = os.path.join(tmp, 'askpass.sh')
        with open(askpass, 'w') as f:
            f.write('#!/bin/sh\nprintf \'%s\\n\' "$SSH_PASS"\n')
        os.chmod(askpass, 0o700)

        probe = await probe_fingerprint(host, port, timeout=10)
        if not probe:
            raise ConnectionError(f'Не удалось получить SSH host key от {host}:{port}')
        if expected_fp and probe['fingerprint'] != expected_fp:
            raise ConnectionError(
                f'⚠️ Fingerprint изменился!\n'
                f'Ожидали: {expected_fp}\n'
                f'Получили: {probe["fingerprint"]}'
            )

        env = os.environ.copy()
        env['SSH_PASS'] = password
        env['SSH_ASKPASS'] = askpass
        env['SSH_ASKPASS_REQUIRE'] = 'force'
        env['DISPLAY'] = ':0'

        proc = await asyncio.create_subprocess_exec(
            SSH,
            '-o', 'StrictHostKeyChecking=accept-new',
            '-o', f'UserKnownHostsFile={kh}',
            '-o', 'NumberOfPasswordPrompts=1',
            '-o', 'ConnectTimeout=10',
            '-o', 'BatchMode=no',
            '-o', 'ServerAliveInterval=10',
            '-o', 'ServerAliveCountMax=3',
            '-p', str(port),
            f'{user}@{host}',
            shell,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env,
            start_new_session=True,
        )

        # отдаём ссылку на процесс наружу — для возможности отмены
        if on_proc:
            try:
                on_proc(proc)
            except Exception:
                pass

        # Передаём скрипт через communicate — оно само пишет в stdin
        # и корректно закрывает поток.
        try:
            out, err = await asyncio.wait_for(
                proc.communicate(input=script.encode('utf-8')),
                timeout=timeout,
            )
        except asyncio.TimeoutError:
            proc.kill()
            try:
                await proc.wait()
            except Exception:
                pass
            raise TimeoutError(f'Таймаут {timeout}с')

        out_s = out.decode('utf-8', errors='replace')
        err_s = err.decode('utf-8', errors='replace')
        rc = proc.returncode

        if rc != 0 and not out_s:
            low = err_s.lower()
            if 'permission denied' in low or 'authentication failed' in low:
                raise PermissionError('Неверный логин или пароль')
            if 'connection refused' in low:
                raise ConnectionError('Соединение отклонено')
            if 'no route to host' in low or 'timed out' in low:
                raise ConnectionError('Хост недоступен')

        return out_s, err_s, rc
RB_MODULES_SSH_CONTROL_SSH_CLIENT_PY_EOF

echo "  → modules/ssh_control/storage.py"
cat > /opt/router_bot/modules/ssh_control/storage.py << 'RB_MODULES_SSH_CONTROL_STORAGE_PY_EOF'
"""Хранилище SSH-хостов."""
import json
import os
from datetime import datetime

DATA_DIR = '/opt/router_bot/data/ssh_control'
HOSTS_FILE = os.path.join(DATA_DIR, 'hosts.json')


def _ensure_dir():
    os.makedirs(DATA_DIR, exist_ok=True)


def load_hosts() -> dict:
    _ensure_dir()
    if not os.path.exists(HOSTS_FILE):
        return {}
    try:
        with open(HOSTS_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def save_hosts(hosts: dict):
    _ensure_dir()
    tmp = HOSTS_FILE + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(hosts, f, ensure_ascii=False, indent=2)
    os.replace(tmp, HOSTS_FILE)


def host_id(ip: str, port: int) -> str:
    return f'{ip}:{port}'


def add_host(ip, port, user, password, fingerprint, key_type) -> str:
    hosts = load_hosts()
    hid = host_id(ip, port)
    hosts[hid] = {
        'ip': ip,
        'port': int(port),
        'user': user,
        'password': password,
        'fingerprint': fingerprint,
        'key_type': key_type,
        'added': datetime.now().isoformat(timespec='seconds'),
    }
    save_hosts(hosts)
    return hid


def remove_host(hid: str) -> bool:
    hosts = load_hosts()
    if hid in hosts:
        del hosts[hid]
        save_hosts(hosts)
        return True
    return False


def get_host(hid: str):
    return load_hosts().get(hid)
RB_MODULES_SSH_CONTROL_STORAGE_PY_EOF

echo "  → modules/system/__init__.py"
cat > /opt/router_bot/modules/system/__init__.py << 'RB_MODULES_SYSTEM___INIT___PY_EOF'

RB_MODULES_SYSTEM___INIT___PY_EOF

echo "  → modules/system/module.py"
cat > /opt/router_bot/modules/system/module.py << 'RB_MODULES_SYSTEM_MODULE_PY_EOF'
"""Модуль System — состояние роутера."""
import asyncio
import json
import logging
import os
import subprocess
from datetime import datetime, timedelta

from telegram import InlineKeyboardButton, InlineKeyboardMarkup

from core.config import get as cfg
from core.utils import show_card, set_last_msg

log = logging.getLogger(__name__)


def _read_file(path):
    try:
        with open(path) as f:
            return f.read()
    except Exception:
        return ''


def _status_icon(value, warn, crit):
    """Возвращает 🟢 / 🟡 / 🔴 по порогам."""
    if value >= crit:
        return '\U0001f534'   # 🔴
    if value >= warn:
        return '\U0001f7e1'   # 🟡
    return '\U0001f7e2'       # 🟢


def _fmt_uptime(seconds):
    seconds = int(seconds)
    d, rem = divmod(seconds, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    parts = []
    if d: parts.append(f'{d}д')
    if h: parts.append(f'{h}ч')
    if m or not parts: parts.append(f'{m}м')
    return ' '.join(parts)


def get_system_info():
    info = {}
    info['cpu_cores'] = os.cpu_count() or 1

    up = _read_file('/proc/uptime').split()
    if up:
        try:
            info['uptime_sec'] = float(up[0])
            info['uptime'] = _fmt_uptime(float(up[0]))
        except Exception:
            pass

    la = _read_file('/proc/loadavg').split()
    if len(la) >= 3:
        info['load'] = f'{la[0]}, {la[1]}, {la[2]}'

    mem = {}
    for line in _read_file('/proc/meminfo').splitlines():
        parts = line.split(':')
        if len(parts) == 2:
            k = parts[0].strip()
            v = parts[1].strip().split()
            if v:
                mem[k] = int(v[0])

    total = mem.get('MemTotal', 0)
    avail = mem.get('MemAvailable', 0)
    if total:
        used = total - avail
        info['mem_total'] = total
        info['mem_used'] = used
        info['mem_pct'] = round(used / total * 100)

    st = mem.get('SwapTotal', 0)
    sf = mem.get('SwapFree', 0)
    if st:
        su = st - sf
        info['swap_total'] = st
        info['swap_used'] = su
        info['swap_pct'] = round(su / st * 100)

    try:
        s = os.statvfs('/opt')
        total_b = s.f_blocks * s.f_frsize
        free_b = s.f_bfree * s.f_frsize
        used_b = total_b - free_b
        info['disk_total_mb'] = total_b // (1024 * 1024)
        info['disk_used_mb'] = used_b // (1024 * 1024)
        info['disk_pct'] = round(used_b / total_b * 100) if total_b else 0
    except Exception as e:
        log.debug('statvfs /opt failed: %s', e)

    return info


CONFIG_PATH = '/opt/router_bot/config.env'


def _run_ndmc_pty(cmd: str, timeout: int = 30) -> str:
    """Выполняет ndmc через pty — надёжнее для интерактивных команд."""
    import pty, select, time
    try:
        master, slave = pty.openpty()
    except Exception as e:
        log.debug('pty.openpty failed: %s', e)
        # fallback без pty
        try:
            p = subprocess.run(
                ['/bin/ndmc', '-c', cmd],
                capture_output=True, text=True, timeout=timeout,
            )
            return (p.stdout or '') + (p.stderr or '')
        except Exception as e2:
            log.debug('fallback subprocess failed: %s', e2)
            return ''

    try:
        proc = subprocess.Popen(
            ['/bin/ndmc', '-c', cmd],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            close_fds=True,
            start_new_session=True,
        )
        os.close(slave)
        buf = b''
        start = time.time()
        while time.time() - start < timeout:
            try:
                r, _, _ = select.select([master], [], [], 0.5)
                if r:
                    data = os.read(master, 4096)
                    if not data:
                        break
                    buf += data
            except (OSError, IOError):
                break
            if proc.poll() is not None and not r:
                # процесс умер и нет данных — выходим
                break
        try:
            os.close(master)
        except Exception:
            pass
        if proc.poll() is None:
            try:
                proc.kill()
            except Exception:
                pass
        return buf.decode('utf-8', errors='replace')
    except Exception as e:
        log.debug('ndmc pty failed: %s', e)
        try:
            os.close(master)
        except Exception:
            pass
        return ''


def _parse_versions(text: str) -> dict:
    """Парсит вывод ndmc — устойчиво к ANSI и мусору."""
    import re as _re
    result = {}
    # Убираем ANSI
    text = _re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', text)
    text = _re.sub(r'\x1b\][^\x07]*\x07', '', text)
    text = text.replace('\r', '')
    for line in text.splitlines():
        if ':' not in line:
            continue
        k, v = line.split(':', 1)
        k = k.strip().lower()
        v = v.strip()
        if not v:
            continue
        if k in ('release', 'title', 'sandbox', 'update-available',
                 'checking', 'current-version', 'version'):
            result[k] = v
    return result


def _compare_versions(v1: str, v2: str) -> int:
    """-1 если v1 < v2, 0 если равны, 1 если v1 > v2."""
    import re as _re
    def parse(s):
        m = _re.findall(r'\d+', s)
        return [int(x) for x in m] if m else []
    a = parse(v1)
    b = parse(v2)
    for i in range(max(len(a), len(b))):
        x = a[i] if i < len(a) else 0
        y = b[i] if i < len(b) else 0
        if x < y:
            return -1
        if x > y:
            return 1
    return 0


def get_update_info():
    """Парсит `components check-update` + `show version` через pty."""
    result = {
        'channel': '',
        'title': '',
        'release': '',
        'current_version': '',
        'update_available': False,
        'checking': False,
    }

    # 1. Текущая версия
    text_cur = _run_ndmc_pty('show version', timeout=10)
    parsed_cur = _parse_versions(text_cur)
    result['current_version'] = parsed_cur.get('release', '')
    result['channel'] = parsed_cur.get('sandbox', '')

    # 2. Проверка обновлений
    text_upd = _run_ndmc_pty('components check-update', timeout=60)
    parsed_upd = _parse_versions(text_upd)

    if not result['channel']:
        result['channel'] = parsed_upd.get('sandbox', '')
    result['title'] = parsed_upd.get('title', '')
    if parsed_upd.get('release'):
        result['release'] = parsed_upd['release']
    if parsed_upd.get('update-available', '').lower() == 'yes':
        result['update_available'] = True
    if parsed_upd.get('checking', '').lower() == 'yes':
        result['checking'] = True

    # 3. Fallback по сравнению версий
    if (not result['update_available']
            and result['release'] and result['current_version']):
        cmp = _compare_versions(result['current_version'], result['release'])
        if cmp < 0:
            result['update_available'] = True

    # 4. Если release пуст, но title содержит номер — используем title
    if (not result['update_available'] and result['title']
            and result['current_version']):
        cmp = _compare_versions(result['current_version'], result['title'])
        if cmp < 0:
            result['update_available'] = True
            if not result['release']:
                result['release'] = result['title']

    return result


def get_router_info():
    """Парсит `show version` и возвращает модель, артикул, архитектуру."""
    result = {'hostname': '', 'model': '', 'hw_id': '', 'arch': '', 'firmware': ''}

    # hostname
    try:
        with open('/proc/sys/kernel/hostname') as f:
            result['hostname'] = f.read().strip()
    except Exception:
        pass

    # архитектура
    import platform
    result['arch'] = platform.machine()

    try:
        p = subprocess.run(
            ['/bin/ndmc', '-c', 'show version'],
            capture_output=True, text=True, timeout=5,
        )
        if p.returncode != 0 or not p.stdout:
            return result
        for line in p.stdout.splitlines():
            if ':' not in line:
                continue
            # не трогаем строки, которые начинаются с заголовков секций без значения
            k, v = line.split(':', 1)
            k = k.strip()
            v = v.strip()
            if not v:
                continue
            if k == 'model':
                result['model'] = v
            elif k == 'hw_id':
                result['hw_id'] = v
            elif k == 'title':
                result['firmware'] = v
            elif k == 'arch':
                result['arch'] = v
    except Exception as e:
        log.debug('show version failed: %s', e)

    return result


def get_ndmc_system():
    """Дополнительные данные из ndmc: cpuload и точные значения памяти."""
    result = {}
    try:
        p = subprocess.run(
            ['/bin/ndmc', '-c', 'show system'],
            capture_output=True, text=True, timeout=5,
        )
        if p.returncode != 0 or not p.stdout:
            return result
        for line in p.stdout.splitlines():
            line = line.strip()
            if ':' not in line:
                continue
            k, v = line.split(':', 1)
            k = k.strip()
            v = v.strip()
            if k == 'cpuload':
                try:
                    result['cpuload'] = int(v)
                except ValueError:
                    pass
        return result
    except Exception as e:
        log.debug('ndmc system failed: %s', e)
        return result


def build_system_card(upd=None):
    info = get_system_info()
    ndmc_info = get_ndmc_system()
    router = get_router_info()
    cores = info.get('cpu_cores', 1)

    lines = ['\U0001f5a5 <b>Система</b>', '']

    # Шапка: устройство
    hdr = []
    if router.get('model'):
        hdr.append(f'<b>{router["model"]}</b>')
    if router.get('hw_id'):
        hdr.append(f'<code>{router["hw_id"]}</code>')
    if hdr:
        lines.append(' \u2022 '.join(hdr))

    meta = []
    if router.get('hostname'):
        meta.append(router['hostname'])
    if router.get('arch'):
        meta.append(router['arch'])
    if meta:
        lines.append('<i>' + ' \u2022 '.join(meta) + '</i>')

    if router.get('firmware'):
        lines.append(f'\U0001f4e6 KeeneticOS: <code>{router["firmware"]}</code>')

    # Информация об обновлениях (переданная или вычисленная)
    if upd is None:
        upd = get_update_info()
    if upd.get('channel'):
        lines.append(f'⚙️ Канал: <code>{upd["channel"]}</code>')
    if upd.get('update_available'):
        cur = upd.get('current_version', '')
        new_v = upd.get('release', '') or upd.get('title', '')
        if cur and new_v:
            lines.append(f'⬆️ <b>Доступно:</b> <code>{new_v}</code>  <i>(сейчас {cur})</i>')
        else:
            lines.append('⬆️ <b>Доступно обновление!</b>')
    else:
        cur = upd.get('current_version', '')
        if cur:
            lines.append(f'✅ <i>Обновлений нет ({cur})</i>')

    lines.append('')

    # Метрики
    lines.append(f'\u23f1 Uptime: <b>{info.get("uptime", "?")}</b>')

    if 'cpuload' in ndmc_info:
        cpu = ndmc_info['cpuload']
        icon = _status_icon(cpu, 70, 90)
        lines.append(f'\U0001f525 CPU: <b>{cpu}%</b>  {icon}  <i>(ядер: {cores})</i>')

    if 'load' in info:
        load_vals = info['load'].split(', ')
        try:
            la1 = float(load_vals[0])
        except Exception:
            la1 = 0
        load_icon = _status_icon(la1, cores, cores * 2)
        lines.append(f'\u26a1 Load: <code>{info["load"]}</code>  {load_icon}')

    if 'mem_total' in info:
        mt = info['mem_total'] // 1024
        mu = info['mem_used'] // 1024
        pct = info['mem_pct']
        icon = _status_icon(pct, 70, 90)
        lines.append(f'\U0001f9e0 RAM: <b>{mu} / {mt} МБ</b> ({pct}%)  {icon}')

    if info.get('swap_total'):
        st = info['swap_total'] // 1024
        su = info['swap_used'] // 1024
        pct = info['swap_pct']
        icon = _status_icon(pct, 20, 50)
        lines.append(f'\U0001f4bd Swap: <b>{su} / {st} МБ</b> ({pct}%)  {icon}')

    if 'disk_total_mb' in info:
        dt = info['disk_total_mb']
        du = info['disk_used_mb']
        pct = info['disk_pct']
        icon = _status_icon(pct, 80, 90)
        lines.append(f'\U0001f4be /opt: <b>{du} / {dt} МБ</b> ({pct}%)  {icon}')

    lines.append('')
    lines.append(f'<i>Обновлено {datetime.now():%H:%M:%S}</i>')

    return '\n'.join(lines)




def _ndmc_interactive_commit(timeout_total: int = 300,
                             login: str = None, password: str = None):
    """Открывает ndmc в интерактивной сессии (без -c),
    логинится, отправляет `components commit` и держит сессию открытой,
    пока не начнётся обновление / перезагрузка / таймаут.

    Возвращает (ok: bool, log_tail: str).
    Если login/password не переданы — берутся из config.env.
    """
    import pty
    import select
    import time

    _login = login if login is not None else cfg('NDMC_LOGIN', 'admin')
    _password = password if password is not None else cfg('NDMC_PASSWORD', '')

    if not _password:
        log.warning('ndmc interactive: NDMC_PASSWORD не задан')
        return False, 'NDMC_PASSWORD не задан — не могу залогиниться в ndmc'

    master, slave = pty.openpty()
    proc = None
    buf = b''
    try:
        proc = subprocess.Popen(
            ['/bin/ndmc'],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            close_fds=True,
            start_new_session=True,
        )
        os.close(slave)
        slave = -1

        def _read_until(pattern, timeout=10):
            nonlocal buf
            start = time.time()
            while time.time() - start < timeout:
                r, _, _ = select.select([master], [], [], 0.3)
                if r:
                    try:
                        data = os.read(master, 4096)
                    except OSError:
                        return False
                    if not data:
                        return False
                    buf += data
                    if isinstance(pattern, bytes):
                        if pattern in buf:
                            return True
                    else:
                        if pattern in buf.decode('utf-8', errors='replace').lower():
                            return True
            return False

        # 1. Ждём "Login:"
        if not _read_until(b'Login:', timeout=10):
            log.warning('ndmc interactive: "Login:" not detected')
            # всё равно пробуем
        os.write(master, (_login + '\n').encode())
        log.info('ndmc interactive: sent login')
        time.sleep(0.3)

        # 2. Ждём "Password:"
        _read_until(b'Password:', timeout=5)
        os.write(master, (_password + '\n').encode())
        log.info('ndmc interactive: sent password')
        time.sleep(0.5)

        # 3. Ждём приглашение "(config)>" или ">"
        if not _read_until(b'(config)>', timeout=10):
            # пробуем любое приглашение с >
            if b'>' not in buf:
                log.warning('ndmc interactive: prompt not detected after login')
                return False, 'Не удалось войти в ndmc (проверьте NDMC_PASSWORD)'

        # 4. Отправляем commit
        os.write(master, b'components commit\n')
        log.info('ndmc interactive: sent "components commit"')

        # 5. Читаем ответ до "progress" > 0 / "interrupted" / таймаут
        start = time.time()
        answered_yn = False
        progress_seen = False
        while time.time() - start < timeout_total:
            r, _, _ = select.select([master], [], [], 0.5)
            if r:
                try:
                    data = os.read(master, 4096)
                except OSError:
                    break
                if not data:
                    break
                buf += data
                low = buf.lower()

                # подтверждение
                if not answered_yn and (
                    b'(y/n)' in low or b'[y/n]' in low
                    or b'continue' in low or b'are you sure' in low
                ):
                    os.write(master, b'y\n')
                    answered_yn = True
                    log.info('ndmc interactive: answered y')

                # признаки прогресса
                if b'update task started' in low or b'progress,' in low:
                    if not progress_seen:
                        log.info('ndmc interactive: update task started, progress seen')
                        progress_seen = True

                # перезагрузка / прерывание / завершение
                if (b'reboot' in low or b'restarting' in low
                        or b'update interrupted' in low
                        or b'update completed' in low):
                    log.info('ndmc interactive: update finishing (%s)',
                             'interrupted' if b'update interrupted' in low else 'ok')
                    break

                # если прогресс уже есть и он растёт — продолжаем читать,
                # пока не появится "interrupted" или "reboot"

            if proc and proc.poll() is not None:
                # процесс завершился — дочитываем
                try:
                    while True:
                        r, _, _ = select.select([master], [], [], 0.2)
                        if not r:
                            break
                        data = os.read(master, 4096)
                        if not data:
                            break
                        buf += data
                except OSError:
                    pass
                break

        return progress_seen, buf.decode('utf-8', errors='replace')[-3000:]
    except Exception as e:
        log.exception('ndmc interactive commit failed: %s', e)
        return False, f'{type(e).__name__}: {e}'
    finally:
        try:
            if slave != -1:
                os.close(slave)
        except Exception:
            pass
        try:
            os.close(proc.stdin) if proc and proc.stdin else None
        except Exception:
            pass


def start_firmware_update(login: str = None, password: str = None):
    """Запускает `components commit` через интерактивную сессию ndmc."""
    import threading
    import time

    def _worker():
        try:
            time.sleep(2)
            ok, tail = _ndmc_interactive_commit(
                timeout_total=300, login=login, password=password)
            if ok:
                log.info('Firmware update: commit sent. Tail:\n%s', tail)
            else:
                log.warning('Firmware update: failed. Tail:\n%s', tail)
        except Exception as e:
            log.exception('firmware update worker failed: %s', e)

    threading.Thread(target=_worker, daemon=True).start()
    log.info('Firmware update scheduled (interactive ndmc)')


def _kb(update_available: bool = False):
    rows = []
    if update_available:
        rows.append([InlineKeyboardButton(
            '\u2b06\ufe0f Установить обновление',
            callback_data='system:update_ask',
        )])
    rows.append([InlineKeyboardButton('\U0001f504 Обновить', callback_data='system:refresh')])
    rows.append([InlineKeyboardButton('\U0001f310 Зеркала Entware',
                                      callback_data='router:mirrors')])
    rows.append([InlineKeyboardButton('\U0001f3e0 Модули', callback_data='router:main')])
    return InlineKeyboardMarkup(rows)


UPDATE_STATE_FILE = '/opt/router_bot/data/system/update_state.json'


def _load_update_state():
    try:
        with open(UPDATE_STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def _save_update_state(data):
    try:
        os.makedirs(os.path.dirname(UPDATE_STATE_FILE), exist_ok=True)
        with open(UPDATE_STATE_FILE, 'w') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
    except Exception:
        pass


class SystemModule:
    name = 'system'
    title = 'System'
    icon = '\U0001f5a5'
    description = 'состояние роутера'
    commands = [('sys', '🖥 Система')]
    cleanup_paths = []
    cleanup_init = []

    def __init__(self, chat_id):
        self.chat_id = str(chat_id)
        self._app = None
        self._update_task = None
        self._fw_state = None      # None | 'login' | 'password'
        self._fw_login = None
        self._fw_password = None
        self._fw_msg_id = None

    async def startup(self, app):
        self._app = app
        from telegram.ext import MessageHandler, filters
        app.add_handler(MessageHandler(
            filters.TEXT & ~filters.COMMAND,
            self._handle_text,
        ), group=10)  # отдельная группа, чтобы не пересечься с другими
        self._update_task = asyncio.create_task(self._update_watch_loop())
        log.info('System module started')

    async def _handle_text(self, update, ctx):
        if str(update.effective_chat.id) != self.chat_id:
            return
        if getattr(self, '_fw_state', None) != 'password':
            return
        log.info('system: caught potential password')
        pwd = (update.message.text or '').strip()
        # удаляем сообщение с паролем
        try:
            await update.message.delete()
        except Exception:
            pass
        if not pwd:
            try:
                await ctx.bot.send_message(
                    chat_id=self.chat_id,
                    text='❌ Пустой пароль. Попробуйте снова: /sys',
                )
            except Exception:
                pass
            self._fw_state = None
            return
        self._fw_password = pwd
        self._fw_state = 'save'
        try:
            await ctx.bot.send_message(
                chat_id=self.chat_id,
                text=(
                    f'\U0001f510 Пароль получен.\n\n'
                    f'Логин: <code>{self._fw_login}</code>\n\n'
                    f'<b>Шаг 3/3.</b> Сохранить логин/пароль в config.env, '
                    f'чтобы не вводить при следующем обновлении?\n'
                    f'<i>Пароль хранится локально в файле с правами 600.</i>'
                ),
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [
                        InlineKeyboardButton('✅ Сохранить', callback_data='system:fw_save:yes'),
                        InlineKeyboardButton('❌ Не сохранять', callback_data='system:fw_save:no'),
                    ],
                ]),
            )
        except Exception as e:
            log.exception('send save dialog failed: %s', e)

    async def on_leave(self):
        if getattr(self, '_update_task', None):
            self._update_task.cancel()

    async def _update_watch_loop(self):
        # Первый опрос — через 2 минуты после старта (дать сети подняться)
        await asyncio.sleep(120)
        while True:
            try:
                await self._check_updates_and_notify()
            except Exception as e:
                log.debug('system update watch failed: %s', e)
            # Опрос раз в 2 часа (было 6) — для более быстрой реакции
            await asyncio.sleep(2 * 3600)

    async def _check_updates_and_notify(self):
        # Проверка идёт через актуальный канал (ndmc check-update
        # сам смотрит на текущий sandbox в системе)
        upd = await asyncio.to_thread(get_update_info)
        st = _load_update_state()
        st['last_check'] = datetime.now().isoformat()

        if not upd.get('update_available'):
            # Обновления нет — сбрасываем маркер «уже отправлено»,
            # чтобы после установки обновления и следующего релиза
            # уведомление снова пришло.
            st.pop('last_notified_version', None)
            st.pop('snoozed_until', None)
            _save_update_state(st)
            log.info('KeenOS update check: no update (cur=%s)',
                     upd.get('current_version', '?'))
            return

        log.info('KeenOS update available: cur=%s new=%s',
                 upd.get('current_version', '?'),
                 upd.get('release', '?') or upd.get('title', '?'))

        snoozed_until = st.get('snoozed_until', '')
        if snoozed_until:
            try:
                if datetime.now() < datetime.fromisoformat(snoozed_until):
                    log.info('update notification snoozed until %s', snoozed_until)
                    st['last_check'] = datetime.now().isoformat()
                    _save_update_state(st)
                    return
            except Exception as e:
                log.debug('snooze parse failed: %s', e)

        new_ver = (upd.get('release', '') or upd.get('title', '')
                   or '__update__')

        if st.get('last_notified_version') == new_ver:
            log.info('update notification skipped (already sent for %s)', new_ver)
            st['last_check'] = datetime.now().isoformat()
            _save_update_state(st)
            return

        await self._send_update_notification(upd)
        st['last_notified_version'] = new_ver
        st['last_check'] = datetime.now().isoformat()
        _save_update_state(st)

    async def _send_update_notification(self, upd):
        cur = upd.get('current_version', '')
        new_v = upd.get('release', '') or upd.get('title', '')

        lines = [
            '\U0001f195 <b>Доступно обновление KeeneticOS</b>',
            '',
            f'Сейчас: <code>{cur}</code>',
        ]
        if new_v:
            lines.append(f'Доступно: <code>{new_v}</code>')
        else:
            lines.append('Доступна <b>новая версия</b> <i>(номер не сообщён)</i>')

        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('\u2b06\ufe0f Установить сейчас',
                                  callback_data='system:update_ask')],
            [InlineKeyboardButton('\u23ed Позже (напомнить через 7 дней)',
                                  callback_data='system:update_later')],
        ])
        try:
            await self._app.bot.send_message(
                chat_id=self.chat_id,
                text='\n'.join(lines),
                parse_mode='HTML',
                reply_markup=kb,
            )
            log.info('System update notification sent: version=%s',
                     new_v or '<unknown>')
        except Exception as e:
            log.warning('update notification failed: %s', e)

    async def send_card_message(self, update, ctx):
        upd = get_update_info()
        text = build_system_card(upd=upd)
        await show_card(update, ctx, 
            text,
            kb=_kb(upd.get('update_available', False)),
        )

    async def handle_callback(self, action, q, ctx):
        # --- Обновление KeenOS: диалог логина/пароля (всегда первым) ---
        if action == 'update_go':
            log.info('update_go: triggered')
            _cfg_login = cfg('NDMC_LOGIN', '')
            _cfg_password = cfg('NDMC_PASSWORD', '')
            log.info('update_go: login=%s, has_password=%s',
                     _cfg_login or '(none)', bool(_cfg_password))

            if _cfg_password:
                await q.answer('Запускаю обновление...')
                try:
                    await q.edit_message_text(
                        '\u2b06\ufe0f <b>Обновление запущено</b>\n\n'
                        'Команда передана ядру KeeneticOS через ndmc.\n'
                        'Роутер начнёт обновление и перезагрузится '
                        'в течение 30–180 секунд.\n'
                        'Не выключайте питание.\n\n'
                        '<i>Если через 3 минуты роутер не перезагрузился — '
                        'проверьте вручную: Система → Обновление ПО.</i>\n'
                        '<i>После перезагрузки напишите /start.</i>',
                        parse_mode='HTML',
                    )
                except Exception as e:
                    log.warning('update_go edit failed: %s', e)
                start_firmware_update(login=_cfg_login or 'admin',
                                      password=_cfg_password)
                return

            # Нет кредов — показываем диалог
            self._fw_login = None
            self._fw_password = None
            self._fw_state = 'login'
            try:
                await q.answer('Авторизация в ndmc')
            except Exception as e:
                log.warning('update_go answer failed: %s', e)

            try:
                await q.edit_message_text(
                    '\U0001f510 <b>Авторизация в ndmc</b>',
                    parse_mode='HTML',
                    reply_markup=None,
                )
            except Exception as e:
                log.warning('update_go edit (cleanup) failed: %s', e)

            try:
                await ctx.bot.send_message(
                    chat_id=self.chat_id,
                    text=(
                        '\U0001f510 <b>Авторизация в ndmc</b>\n\n'
                        'Для запуска обновления нужен логин/пароль '
                        'веб-интерфейса Keenetic.\n\n'
                        '<b>Шаг 1/3.</b> Введите логин или нажмите кнопку '
                        '<code>admin</code>:'
                    ),
                    parse_mode='HTML',
                    reply_markup=InlineKeyboardMarkup([
                        [InlineKeyboardButton('admin', callback_data='system:fw_login:admin')],
                        [InlineKeyboardButton('\u274c Отмена', callback_data='system:refresh')],
                    ]),
                )
                log.info('update_go: login dialog sent')
            except Exception as e:
                log.exception('update_go send login dialog FAILED: %s', e)
            return

        if action.startswith('fw_login:'):
            try:
                _login = action[len('fw_login:'):] or 'admin'
                self._fw_login = _login
                self._fw_state = 'password'
                log.info('fw_login: selected login=%s, waiting for password', _login)

                try:
                    await q.answer(f'Логин: {_login}')
                except Exception:
                    pass

                try:
                    await q.edit_message_text(
                        f'\U0001f510 Логин: <code>{_login}</code>',
                        parse_mode='HTML',
                        reply_markup=None,
                    )
                except Exception:
                    pass

                await ctx.bot.send_message(
                    chat_id=self.chat_id,
                    text=(
                        f'\U0001f510 <b>Авторизация в ndmc</b>\n\n'
                        f'Логин: <code>{_login}</code>\n\n'
                        f'<b>Шаг 2/3.</b> Отправьте пароль следующим сообщением.\n'
                        f'<i>Сообщение с паролем будет сразу удалено.</i>'
                    ),
                    parse_mode='HTML',
                    reply_markup=InlineKeyboardMarkup([
                        [InlineKeyboardButton('\u274c Отмена', callback_data='system:refresh')],
                    ]),
                )
            except Exception as e:
                log.exception('fw_login processing failed: %s', e)
                try:
                    await q.answer('Ошибка при выборе логина', show_alert=True)
                except Exception:
                    pass
            return

        if action == 'update_later':
            await q.answer('Напомню через 7 дней')
            st = _load_update_state()
            until = (datetime.now() + timedelta(days=7)).isoformat(timespec='seconds')
            st['snoozed_until'] = until
            _save_update_state(st)
            log.info('update snoozed until %s', until)
            try:
                await q.edit_message_text(
                    '\u23ed <b>Напомню через 7 дней</b>\n\n'
                    f'До: <code>{until[:10]}</code>',
                    parse_mode='HTML',
                )
            except Exception as e:
                log.debug('snooze edit failed: %s', e)
            return

        if action in ('main', 'refresh', 'check_upd'):
            if action == 'check_upd':
                await q.answer('Проверяю обновления...')
            else:
                await q.answer()
            upd = get_update_info()
            text = build_system_card(upd=upd)
            try:
                await q.edit_message_text(
                    text, parse_mode='HTML',
                    reply_markup=_kb(upd.get('update_available', False)),
                )
            except Exception as e:
                if 'not modified' not in str(e).lower():
                    raise
            return

        if action == 'update_ask':
            await q.answer()
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2705 Да, установить', callback_data='system:update_go')],
                [InlineKeyboardButton('\u274c Отмена', callback_data='system:refresh')],
            ])
            text = (
                '\u2b06\ufe0f <b>Установить обновление?</b>\n\n'
                '\u26a0\ufe0f <b>Роутер перезагрузится.</b>\n'
                'Связь с ботом пропадёт на 2–5 минут.\n\n'
                'Продолжить?'
            )
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower():
                    raise
            return

        if action == 'fw_save:yes':
            try:
                await q.answer('Сохраняю...')
            except Exception:
                pass
            cfg_path = '/opt/router_bot/config.env'
            try:
                _upd_channel = cfg('UPDATE_CHANNEL', '')
                lines = []
                found_login = False
                found_pass = False
                if os.path.exists(cfg_path):
                    with open(cfg_path) as f:
                        for line in f:
                            if line.startswith('NDMC_LOGIN='):
                                lines.append(f"NDMC_LOGIN='{self._fw_login}'\n")
                                found_login = True
                            elif line.startswith('NDMC_PASSWORD='):
                                lines.append(f"NDMC_PASSWORD='{self._fw_password}'\n")
                                found_pass = True
                            else:
                                lines.append(line)
                if not found_login:
                    lines.append(f"\nNDMC_LOGIN='{self._fw_login}'\n")
                if not found_pass:
                    lines.append(f"NDMC_PASSWORD='{self._fw_password}'\n")
                tmp = cfg_path + '.tmp'
                with open(tmp, 'w') as f:
                    f.writelines(lines)
                os.replace(tmp, cfg_path)
                try:
                    import shutil
                    shutil.copy(cfg_path, cfg_path + '.bak')
                except Exception:
                    pass
                log.info('NDMC credentials saved to config.env')
            except Exception as e:
                log.warning('save ndmc creds failed: %s', e)
            await self._fw_start(q, ctx, self._fw_login, self._fw_password,
                                 save_msg='✅ Логин/пароль сохранены в config.env')
            return

        if action == 'fw_save:no':
            try:
                await q.answer()
            except Exception:
                pass
            await self._fw_start(q, ctx, self._fw_login, self._fw_password,
                                 save_msg='ℹ️ Логин/пароль не сохранены')
            return

    async def _fw_start(self, q, ctx, login, password, save_msg=''):
        """Запускает обновление KeeneticOS через ndmc с переданными кредами.
        Показывает пользователю сообщение о старте.
        """
        self._fw_state = None

        header = (
            '\u2b06\ufe0f <b>Обновление запущено</b>\n\n'
            'Команда передана ядру KeeneticOS через ndmc.\n'
            'Роутер начнёт обновление и перезагрузится '
            'в течение 30–180 секунд.\n'
            'Не выключайте питание.\n\n'
        )
        footer = (
            '<i>Если через 3 минуты роутер не перезагрузился — '
            'проверьте вручную: Система → Обновление ПО.</i>\n'
            '<i>После перезагрузки напишите /start.</i>'
        )
        if save_msg:
            text = header + save_msg + '\n\n' + footer
        else:
            text = header + footer

        try:
            await q.edit_message_text(text, parse_mode='HTML')
        except Exception as e:
            log.warning('_fw_start edit failed: %s', e)

        try:
            start_firmware_update(login=login or 'admin',
                                  password=password or '')
            log.info('_fw_start: firmware update scheduled (login=%s)',
                     login or 'admin')
        except Exception as e:
            log.exception('_fw_start: start_firmware_update failed: %s', e)
RB_MODULES_SYSTEM_MODULE_PY_EOF

echo "  → modules/hydraroute/__init__.py"
cat > /opt/router_bot/modules/hydraroute/__init__.py << 'RB_MODULES_HYDRAROUTE___INIT___PY_EOF'

RB_MODULES_HYDRAROUTE___INIT___PY_EOF

echo "  → modules/hydraroute/module.py"
cat > /opt/router_bot/modules/hydraroute/module.py << 'RB_MODULES_HYDRAROUTE_MODULE_PY_EOF'
"""Модуль HydraRoute — установка/управление через бота."""
import asyncio
import html
import logging
import os
import pty
import re
import subprocess
import time

from telegram import InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import MessageHandler, filters, ContextTypes

from .actions import (
    ACTIONS, is_installed, is_running, get_installed_version,
    UNINSTALL_TARGETS, SCAN_PATTERNS,
    get_hr_web_url, get_router_ip, get_versions, check_updates,
    load_last_seen, save_last_seen, get_update_status,
)
from core.utils import set_last_msg

log = logging.getLogger(__name__)
from core.utils import (
    existing_targets, sync_opts, build_uninstall_menu,
    collect_uninstall_cmd, toggle_opt,
    scan_leftovers, build_leftovers_message,
    ui_edit_q, ui_edit_or_send,
    show_card,
)

MAX_MSG = 3500
QUESTION_PATTERNS = [
    b'(y/n)', b'[y/n]', b'[Y/n]', b'[y/N]',
    b'(yes/no)', b'are you sure', b'continue?',
    b'proceed?', b'do you want',
]


def _esc(s: str) -> str:
    return html.escape(s or '')


def _has_question(buf: bytes) -> bool:
    low = buf.lower()
    for p in QUESTION_PATTERNS:
        if p.lower() in low:
            return True
    return False


def _split(text, size=MAX_MSG):
    if not text:
        return ['']
    chunks, cur = [], ''
    for line in text.splitlines(keepends=True):
        if len(cur) + len(line) > size:
            if cur:
                chunks.append(cur)
            cur = line
            while len(cur) > size:
                chunks.append(cur[:size])
                cur = cur[size:]
        else:
            cur += line
    if cur:
        chunks.append(cur)
    return chunks


class HydraRouteModule:
    name = 'hydraroute'
    title = 'HydraRoute'
    icon = '🐍'
    description = 'установка и управление HydraRoute'
    category = 'services'
    category_title = 'Сервис'
    category_icon = '🛠'
    commands = [('hr', '🐍 HydraRoute')]
    cleanup_paths = [
        '/opt/sbin/hrneo',
        '/opt/bin/hrneo',
        '/opt/sbin/hrweb',
        '/opt/bin/hrweb',
        '/opt/sbin/hrdns',
        '/opt/bin/hrdns',
        '/opt/etc/HydraRoute',
        '/opt/var/log/hydraroute*',
        '/opt/var/log/hrneo*',
        '/opt/var/log/hrdns*',
        '/opt/var/run/hrneo*',
        '/opt/var/run/hrdns*',
    ]
    cleanup_init = ['S99hrneo', 'S99hrweb', 'S99hrdns']

    def __init__(self, chat_id):
        self._token_editing = False
        self._match_editing = False
        self._app = None
        self.chat_id = str(chat_id)
        self._proc = None
        self._master_fd = None
        self._running = False
        self._status_msg_id = None
        self._awaiting_answer = False
        self._question_msg_id = None
        self._last_action = None
        self._uninstall_opts = {
            'xray': True,
            'adguard': True,
            'phobos': True,
            'logs': True,
        }

    async def startup(self, app):
        self._app = app
        app.add_handler(MessageHandler(
            filters.TEXT & ~filters.COMMAND,
            self._handle_text,
        ), group=-1)
        self._watch_task = asyncio.create_task(
            self._update_watch_loop())
        log.info('HydraRoute module started')

    async def on_leave(self):
        if getattr(self, '_watch_task', None):
            self._watch_task.cancel()
        self._token_editing = False
        self._match_editing = False
        self._kill()

    async def _update_watch_loop(self):
        # Даём кэшу opkg обновиться при старте
        await asyncio.sleep(180)
        while True:
            try:
                await self._check_and_notify()
            except Exception as e:
                log.debug('hr update watch failed: %s', e)
            # Проверка раз в 2 часа (было 12)
            await asyncio.sleep(2 * 3600)

    async def _check_and_notify(self):
        if not is_installed():
            return
        info = await asyncio.to_thread(check_updates)
        last = load_last_seen()
        newly = {}
        for pkg in ('hrneo', 'hrweb', 'hrdns'):
            d = info.get(pkg, {})
            ins = d.get('installed', '')
            lat = d.get('latest', '')
            has_update = d.get('update', False)
            # Ключ сравнения: latest если есть обновление, иначе installed
            key = lat if has_update else ins
            if has_update and key and last.get(pkg) != key:
                newly[pkg] = {'installed': ins, 'latest': lat}
        if newly:
            log.info('HR update notification: %s', list(newly.keys()))
            await self._send_update_notification(newly)
        # Не теряем старые ключи, обновляем только непустые
        new_state = dict(last)
        for pkg in ('hrneo', 'hrweb', 'hrdns'):
            d = info.get(pkg, {})
            ins = d.get('installed', '')
            lat = d.get('latest', '')
            key = lat if d.get('update') else ins
            if key:
                new_state[pkg] = key
        save_last_seen(new_state)

    async def _send_update_notification(self, newly):
        lines = ['🆕 <b>Доступны обновления HydraRoute</b>', '']
        for pkg, d in newly.items():
            lines.append(f'⬆️ <b>{pkg}</b>: '
                         f'<code>{d["installed"]}</code> → '
                         f'<code>{d["latest"]}</code>')
        lines.append('')
        lines.append('<i>Обновить сейчас?</i>')
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('⬆️ Обновить сейчас',
                                  callback_data='hydraroute:go:update')],
            [InlineKeyboardButton('📋 Открыть карточку',
                                  callback_data='hydraroute:main')],
            [InlineKeyboardButton('⏭ Позже',
                                  callback_data='hydraroute:main')],
        ])
        try:
            await self._app.bot.send_message(
                chat_id=self.chat_id,
                text='\n'.join(lines),
                parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            log.warning('hr update notification failed: %s', e)

    def _kill(self):
        if self._proc:
            try:
                self._proc.kill()
            except Exception:
                pass
            self._proc = None
        if self._master_fd is not None:
            try:
                os.close(self._master_fd)
            except Exception:
                pass
            self._master_fd = None
        self._running = False
        self._awaiting_answer = False

    async def send_card_message(self, update, ctx):
        text, kb = self._build_card()
        await show_card(update, ctx, text, kb=kb)

    conflicts_with = {
        'xkeen': 'оба используют /opt/etc/xray и запускают демон xray',
    }

    def get_installed(self) -> bool:
        return is_installed()

    def get_status_short(self) -> str:
        if not is_installed():
            return '❌'
        return '🟢' if is_running() else '🔴'

    def _build_card(self):
        installed = is_installed()
        lines = [f'{self.icon} <b>{self.title}</b>', '']
        if installed:
            running = is_running()
            vs = get_versions()
            neo = vs.get('neo')   or '—'
            web = vs.get('web')   or '—'
            dns = vs.get('hrdns') or '—'
            lines.append('✅ Установлен')
            lines.append(f'📦 Neo: <code>{neo}</code>')
            lines.append(f'🖥️ Web: <code>{web}</code>')
            lines.append(f'📡 hrdns: <code>{dns}</code>')
            lines.append('Сервис: ' + ('🟢 работает' if running else '🔴 остановлен'))
            url = get_hr_web_url()
            lines.append(f'Web UI: <a href="{url}">{url}</a>')
            _upd_st = get_update_status()
            if _upd_st.get('has_updates'):
                lines.append('')
                lines.append('⬆️ <b>Доступно обновление:</b>')
                for p, d in _upd_st.get('packages', {}).items():
                    if d.get('update'):
                        lines.append(f'  • {p}: <code>{d["installed"]}</code> → <code>{d["latest"]}</code>')
        else:
            lines.append('❌ Не установлен')
        if not installed:
            try:
                import os as _os
                _xk_marker = _os.path.isdir('/opt/sbin/.xkeen')
                _xk_proc = False
                try:
                    import subprocess as _sp
                    _r = _sp.run(
                        ['sh', '-c', 'ps w | grep -q "[x]keen" && echo yes'],
                        capture_output=True, text=True, timeout=3,
                    )
                    _xk_proc = 'yes' in (_r.stdout or '')
                except Exception:
                    pass
                if _xk_marker and _xk_proc:
                    lines.append('⚠️ <b>Конфликт с XKeen!</b>')
                    lines.append('<i>Удалите XKeen перед установкой HydraRoute.</i>')
                    lines.append('')
            except Exception:
                pass

        lines.append('')

        if self._running:
            lines.append('⏳ <b>Выполняется операция...</b>')
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('🛑 Отменить', callback_data='hydraroute:kill')],
                [
                    InlineKeyboardButton('⬅️ Назад', callback_data='router:cat:services'),
                    InlineKeyboardButton('🏠 Модули', callback_data='router:main'),
                ],
            ])
            return '\n'.join(lines), kb

        rows = []
        if not installed:
            rows.append([InlineKeyboardButton(
                '⬇️ Установить', callback_data='hydraroute:ask:install')])
        else:
            rows.append([InlineKeyboardButton(
                '🔍 Проверить обновления',
                callback_data='hydraroute:ask:check_updates')])
            rows.append([InlineKeyboardButton(
                '⬆️ Обновить', callback_data='hydraroute:ask:update')])
            rows.append([InlineKeyboardButton(
                '🗑 Удалить (стандартное)',
                callback_data='hydraroute:ask:uninstall_std')])
            rows.append([InlineKeyboardButton(
                '🗑 Удалить (полное)',
                callback_data='hydraroute:ask:uninstall_full')])
            rows.append([
                InlineKeyboardButton('📊 Диагностика',
                                     callback_data='hydraroute:ask:diag'),
                InlineKeyboardButton('📄 Версия',
                                     callback_data='hydraroute:ask:version'),
            ])
            rows.append([InlineKeyboardButton(
                '❓ Справка',
                callback_data='hydraroute:ask:help')])
            rows.append([InlineKeyboardButton(
                '📋 Watchlist',
                callback_data='hydraroute:ask:watchlist')])
            rows.append([InlineKeyboardButton(
                '🎯 Куда идёт домен',
                callback_data='hydraroute:ask:match')])
            rows.append([InlineKeyboardButton(
                '📝 Сгенерировать конфиг',
                callback_data='hydraroute:ask:genconfig')])
            rows.append([InlineKeyboardButton(
                '🔑 Записать токен Keenetic',
                callback_data='hydraroute:ask:keenetic')])
        rows.append([InlineKeyboardButton(
            '🔄 Обновить карточку', callback_data='hydraroute:main')])
        rows.append([
            InlineKeyboardButton('⬅️ Назад', callback_data='router:cat:services'),
            InlineKeyboardButton('🏠 Модули', callback_data='router:main'),
        ])
        return '\n'.join(lines), InlineKeyboardMarkup(rows)
    async def handle_callback(self, action, q, ctx):
        if action in ('main',):
            await q.answer()
            text, kb = self._build_card()
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' in str(e).lower():
                    return
                try:
                    await ctx.bot.send_message(
                        chat_id=self.chat_id,
                        text=text, parse_mode='HTML', reply_markup=kb)
                except Exception as e2:
                    log.warning('main fallback failed: %s', e2)
            return

        if action == 'cleanup:all':
            await q.answer()
            return await self._do_cleanup(q, ctx)

        if action in ('ask:uninstall_std', 'ask:uninstall_full', 'ask:uninstall'):
            await q.answer()
            return await self._show_uninstall_menu(q, ctx)

        if action.startswith('opt:'):
            return await self._handle_opt(q, ctx, action[4:])

        if action == 'ask:check_updates':
            await q.answer('Проверяю...')
            return await self._do_check_updates(q, ctx)

        if action == 'ask:keenetic':
            await q.answer()
            return await self._ask_keenetic(q, ctx)

        if action == 'ask:match':
            await q.answer()
            return await self._ask_match(q, ctx)

        if action == 'ask:help':
            await q.answer()
            from .actions import build_help_text
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('⬅️ Назад',
                                      callback_data='hydraroute:main')],
            ])
            try:
                await q.edit_message_text(
                    build_help_text(),
                    parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower():
                    raise
            return

        if action.startswith('ask:'):
            key = action[4:]
            await q.answer()
            a = ACTIONS.get(key)
            if not a:
                await q.answer('Неизвестное действие', show_alert=True)
                return
            desc = a['desc']
            if key == 'install':
                desc = desc.replace('&lt;router-ip&gt;', get_router_ip())
                _xk_proc = False
                try:
                    import subprocess as _sp
                    _r = _sp.run(['sh', '-c', 'ps w | grep -q "[x]keen" && echo yes'], capture_output=True, text=True, timeout=3)
                    _xk_proc = 'yes' in (_r.stdout or '')
                except Exception:
                    pass
                if _xk_proc:
                    desc += '\n\n⚠️ <b>Внимание:</b> XKeen сейчас <b>запущен</b>. Они используют те же ядра/маршрутизацию. Установка может вызвать конфликт.'
            text = (
                f'{a["icon"]} <b>{a["title"]}</b>\n\n'
                f'{desc}\n\n'
                f'Подтвердить?'
            )
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('✅ Подтвердить',
                                      callback_data=f'hydraroute:go:{key}')],
                [InlineKeyboardButton('❌ Отмена',
                                      callback_data='hydraroute:main')],
            ])
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower():
                    raise
            return

        if action.startswith('go:'):
            key = action[3:]
            await q.answer()
            a = ACTIONS.get(key)
            if not a:
                return
            await self._start_action(q, ctx, key, a)
            return

        if action == 'kill':
            await q.answer('Прерываю...')
            self._kill()
            await q.edit_message_text(
                '🛑 Операция прервана.\n\nНапишите /start для возврата в меню.',
            )
            return

        if action == 'ans:y':
            await self._answer(q, b'y\r')
            return
        if action == 'ans:n':
            await self._answer(q, b'n\r')
            return
        if action == 'ans:enter':
            await self._answer(q, b'\r')
            return

        await q.answer()

    async def _check_leftovers(self, ctx):
        try:
            leftovers = scan_leftovers(SCAN_PATTERNS)
        except Exception as e:
            log.debug('scan_leftovers failed: %s', e)
            return
        if not leftovers:
            return
        self._leftovers = leftovers
        text, kb = build_leftovers_message(leftovers, prefix='hydraroute')
        try:
            await ctx.bot.send_message(
                chat_id=self.chat_id,
                text=text,
                parse_mode='HTML',
                reply_markup=kb,
            )
        except Exception as e:
            log.warning('send leftovers failed: %s', e)

    async def _do_cleanup(self, q, ctx):
        if not getattr(self, '_leftovers', None):
            await q.answer('Нечего удалять', show_alert=True)
            return

        parts = []
        total = len(self._leftovers)
        for p in self._leftovers:
            safe = p.replace("'", "'\\''")
            parts.append(f"echo 'Удаляю: {safe}' ; rm -rf '{safe}'")
        parts.append(f"echo '' ; echo 'Готово: удалено {total} элементов'")
        cmd = ' ; '.join(parts)
        self._leftovers = []

        self._running = True
        self._last_action = 'cleanup'
        self._awaiting_answer = False
        action = {
            'icon': '🗑',
            'title': 'Удаление остатков HydraRoute',
            'cmd': cmd,
        }
        msg = await ctx.bot.send_message(
            chat_id=self.chat_id,
            text='🗑 <b>Удаление остатков HydraRoute</b>\n\n<pre>запуск...</pre>',
            parse_mode='HTML',
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton('🛑 Отменить',
                                      callback_data='hydraroute:kill')],
            ]),
        )
        self._status_msg_id = msg.message_id
        set_last_msg(self.chat_id, msg.message_id)
        asyncio.create_task(self._run_action(ctx, action))

    async def _show_uninstall_menu(self, q, ctx):
        targets = existing_targets(UNINSTALL_TARGETS)
        self._uninstall_opts = sync_opts(targets, self._uninstall_opts)

        text, kb = build_uninstall_menu(
            targets,
            self._uninstall_opts,
            title='Удаление HydraRoute',
            always_msg=(
                'Пакет <code>hrneo</code> и зависимости удаляются '
                'всегда командой <code>opkg remove</code>.'
            ),
            prefix='hydraroute',
        )
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise

    async def _handle_opt(self, q, ctx, key):
        if key in self._uninstall_opts:
            toggle_opt(self._uninstall_opts, key)
            state = 'вкл' if self._uninstall_opts[key] else 'выкл'
            await q.answer(f'{state}: {key}')
            await self._show_uninstall_menu(q, ctx)
            return

        if key == 'go':
            await q.answer()
            targets = existing_targets(UNINSTALL_TARGETS)
            base_cmd = ('opkg remove --force-removal-of-dependent-packages '
                        '--autoremove hrneo hrweb 2>&1 || true')
            cmd = collect_uninstall_cmd(targets, self._uninstall_opts, base_cmd)
            self._uninstall_opts = {}

            self._running = True
            self._last_action = 'uninstall'
            self._awaiting_answer = False
            action = {
                'icon': '🗑',
                'title': 'Удаление HydraRoute',
                'cmd': cmd,
            }
            msg = await ctx.bot.send_message(
                chat_id=self.chat_id,
                text='🗑 <b>Удаление HydraRoute</b>\n\n<pre>запуск...</pre>',
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton('🛑 Отменить',
                                          callback_data='hydraroute:kill')],
                ]),
            )
            self._status_msg_id = msg.message_id
            set_last_msg(self.chat_id, msg.message_id)
            asyncio.create_task(self._run_action(ctx, action))
            return

        await q.answer()

    async def _do_check_updates(self, q, ctx):
        info = await asyncio.to_thread(check_updates)
        lines = ['🔍 <b>Проверка обновлений HydraRoute</b>', '']
        any_update = False
        for pkg in ('hrneo', 'hrweb', 'hrdns'):
            d = info.get(pkg, {})
            ins = d.get('installed', '') or '—'
            lat = d.get('latest', '') or '—'
            if d.get('update'):
                lines.append(f'🟡 <b>{pkg}</b>: <code>{ins}</code> → <code>{lat}</code>')
                any_update = True
            else:
                lines.append(f'🟢 <b>{pkg}</b>: <code>{ins}</code>')
                if ins != lat and lat != '—':
                    lines.append(f'   <i>(в репо: {lat})</i>')
        lines.append('')
        if any_update:
            lines.append('Доступны обновления.')
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('⬆️ Обновить',
                                      callback_data='hydraroute:ask:update')],
                [InlineKeyboardButton('⬅️ Назад',
                                      callback_data='hydraroute:main')],
            ])
        else:
            lines.append('Всё актуально.')
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('⬅️ Назад',
                                      callback_data='hydraroute:main')],
            ])
        try:
            await q.edit_message_text('\n'.join(lines),
                                      parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise

    async def _handle_text(self, update, ctx):
        if str(update.effective_chat.id) != self.chat_id:
            return
        text = (update.message.text or '').strip()
        if not text:
            return
        if self._token_editing:
            self._token_editing = False
            from .actions import build_keenetic_cmd
            cmd = build_keenetic_cmd(text)
            try:
                await update.message.delete()
            except Exception:
                pass
            await self._start_action(None, ctx, 'keenetic',
                {'icon': '🔑', 'title': 'Keenetic token', 'cmd': cmd})
            return
        if self._match_editing:
            self._match_editing = False
            from .actions import build_match_cmd
            cmd = build_match_cmd(text)
            try:
                await update.message.delete()
            except Exception:
                pass
            await self._start_action(None, ctx, 'match',
                {'icon': '🎯', 'title': f'Match {text}', 'cmd': cmd})
            return

    async def _ask_keenetic(self, q, ctx):
        self._token_editing = True
        self._match_editing = False
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('❌ Отмена',
                                  callback_data='hydraroute:main')],
        ])
        try:
            await q.edit_message_text(
                '🔑 <b>Пришли Keenetic RCI токен</b>\n\n'
                'Следующим сообщением отправь токен.\n'
                'Текущий конфиг будет сохранён.',
                parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise

    async def _ask_match(self, q, ctx):
        self._match_editing = True
        self._token_editing = False
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('❌ Отмена',
                                  callback_data='hydraroute:main')],
        ])
        try:
            await q.edit_message_text(
                '🎯 <b>Куда идёт домен</b>\n\n'
                'Пришли домен или IP — узнаем, '
                'через какой интерфейс он пойдёт.',
                parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise
    async def _start_action(self, q, ctx, key, action):
        if self._running:
            return
        self._running = True
        self._last_action = key
        self._buf = b''
        self._last_edit = 0.0
        self._awaiting_yn = False

        status_text = f'{action["icon"]} <b>{action["title"]}</b>\n\n<pre>Запускаю...</pre>'
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('\U0001f6d1 Отменить', callback_data='hydraroute:kill')],
        ])
    
        if q is not None:
            self._status_msg_id = await ui_edit_q(q, status_text, kb=kb)
        else:
            msg = await ctx.bot.send_message(
                chat_id=self.chat_id, text=status_text,
                parse_mode='HTML', reply_markup=kb,
            )
            self._status_msg_id = msg.message_id
            set_last_msg(self.chat_id, msg.message_id)

        async def _safe_run():
            try:
                await self._run_action(ctx, action)
            except Exception as e:
                log.exception('hydraroute _run_action failed: %s', e)
                self._running = False
                if self._status_msg_id:
                    try:
                        await ctx.bot.edit_message_text(
                            chat_id=self.chat_id,
                            message_id=self._status_msg_id,
                            text=f'❌ <b>Ошибка выполнения</b>\n<pre>{_esc(str(e))}</pre>',
                            parse_mode='HTML',
                        )
                    except Exception:
                        pass

        asyncio.create_task(_safe_run())

    async def _run_action(self, ctx, action):
        import pty, subprocess, time, os
        cmd = action['cmd']
        log.info('hydraroute action cmd: %s', cmd)

        master, slave = pty.openpty()
        try:
            proc = subprocess.Popen(
                ['sh', '-c', cmd],
                stdin=slave, stdout=slave, stderr=slave,
                close_fds=True, start_new_session=True,
                env={**os.environ, 'DEBIAN_FRONTEND': 'noninteractive'},
            )
        except Exception as e:
            os.close(master); os.close(slave)
            await self._finish(ctx, f'Не удалось запустить: {e}'.encode(), -1)
            return

        os.close(slave)
        self._proc = proc
        self._master_fd = master

        try:
            import fcntl
            fcntl.fcntl(master, fcntl.F_SETFL, os.O_NONBLOCK)
        except Exception as e:
            log.warning('nonblock set failed: %s', e)

        buf = b''
        last_update = time.time()
        start_time = time.time()
        timeout_total = 30 if self._last_action == "match" else 120

        # Принудительно отправляем первое обновление статуса (убираем "Запускаю...")
        await self._update_status(ctx, buf)

        try:
            while True:
                if self._proc is None: break
                ret = proc.poll()
                if ret is not None:
                    buf += self._drain_master(master)
                    break

                if time.time() - start_time > timeout_total:
                    buf += b'\n[!] Timeout\n'
                    proc.kill()
                    break

                try:
                    data = os.read(master, 4096)
                    if data:
                        buf += data
                        if len(buf) > 600000: buf = buf[-500000:]
                        self._buf = buf
                except BlockingIOError:
                    pass
                except OSError:
                    break

                now = time.time()
                if now - last_update >= 1.2:
                    last_update = now
                    await self._update_status(ctx, buf)

                if not getattr(self, '_awaiting_yn', False) and _has_question(buf[-500:]):
                    await self._ask_question(ctx, buf)

                await asyncio.sleep(0.15)
        except Exception as e:
            log.exception('hydraroute run error: %s', e)
        finally:
            try: os.close(master)
            except Exception: pass
            self._master_fd = None

        try:
            rc = proc.wait(timeout=2)
        except Exception:
            proc.kill()
            rc = -1
        self._proc = None
        await self._finish(ctx, buf, rc)

    def _drain_master(self, master) -> bytes:
        import select as _select
        extra = b''
        try:
            while True:
                r, _, _ = _select.select([master], [], [], 0.3)
                if not r:
                    break
                try:
                    data = os.read(master, 4096)
                except (BlockingIOError, OSError):
                    break
                if not data:
                    break
                extra += data
        except Exception as e:
            log.debug('drain_master: %s', e)
        return extra

    async def _update_status(self, ctx, buf):
        if not self._status_msg_id: return
        text_buf = buf.decode('utf-8', errors='replace')
        tail = text_buf[-1800:] if len(text_buf) > 1800 else text_buf
    
        if getattr(self, '_awaiting_yn', False):
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2705 Да (y)', callback_data='hydraroute:ans:y'),
                 InlineKeyboardButton('\u274c Нет (n)', callback_data='hydraroute:ans:n')],
                [InlineKeyboardButton('\u23ce Enter', callback_data='hydraroute:ans:enter'),
                 InlineKeyboardButton('\U0001f6d1 Прервать', callback_data='hydraroute:kill')],
            ])
        else:
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить', callback_data='hydraroute:kill')],
            ])
        
        try:
            await ctx.bot.edit_message_text(
                chat_id=self.chat_id,
                message_id=self._status_msg_id,
                text=f'\u23f3 <b>Выполняется...</b>\n\n<pre>{_esc(tail)}</pre>',
                parse_mode='HTML', reply_markup=kb,
            )
        except Exception as e:
            if 'not modified' not in str(e).lower():
                log.debug('edit status: %s', e)

    async def _ask_question(self, ctx, buf):
        if getattr(self, '_awaiting_yn', False): return
        self._awaiting_yn = True
        await self._update_status(ctx, buf)

    async def _answer(self, q, payload: bytes):
        if not getattr(self, '_proc', None) or self._master_fd is None:
            await q.answer('Сессия завершена', show_alert=False)
            return
        try:
            os.write(self._master_fd, payload)
            await q.answer(f'Отправлено: {payload.decode(errors="replace").strip() or "Enter"}')
        except OSError as e:
            log.warning('write failed: %s', e)
            await q.answer(f'Ошибка: {e}', show_alert=True)
            return
        self._awaiting_yn = False
        # _run_action сам перерисует статус через 1.2с

    async def _finish(self, ctx, buf, rc):
        self._running = False
        self._awaiting_yn = False
        was_uninstall = (self._last_action == 'uninstall')
        was_cleanup = (self._last_action == 'cleanup')
        was_match = (self._last_action == 'match')
        was_watchlist = (self._last_action == 'watchlist')

        text = buf.decode('utf-8', errors='replace')
        text = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', text)
        text = re.sub(r'\r', '', text)
        text = text.strip()

        if rc == 0 and 'Collected errors' in text:
            new_lines, skip = [], False
            for ln in text.split('\n'):
                if 'Collected errors' in ln:
                    skip = True; continue
                if skip:
                    if ln.strip().startswith('*'):
                        if 'is not installed' in ln: continue
                        new_lines.append(ln); continue
                    else:
                        skip = False
                new_lines.append(ln)
            text = '\n'.join(new_lines).strip()

        offer_start = (getattr(self, '_last_action', None) == 'install' and rc == 0 and is_installed())
        self._last_action = None

        if self._question_msg_id:
            try: await ctx.bot.delete_message(chat_id=self.chat_id, message_id=self._question_msg_id)
            except Exception: pass
            self._question_msg_id = None

        icon = '✅' if rc == 0 else '❌'

        # --- WATCHLIST ---
        if was_watchlist and self._status_msg_id:
            lines = text.splitlines()
            total = len(lines)
            if total > 100:
                preview = '\n'.join(lines[:50] + ['', f'... (опущено {total-100} строк) ...', ''] + lines[-50:])
            else:
                preview = text
            if len(preview) > 3500: preview = preview[:3500] + '\n...'
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id, message_id=self._status_msg_id,
                    text=f'📋 <b>Watchlist</b> — {total} строк\n\n<pre>{_esc(preview)}</pre>',
                    parse_mode='HTML', reply_markup=None,
                )
            except Exception as e: log.debug('watchlist M1 edit failed: %s', e)
        
            try:
                from telegram import InputFile
                import io as _io
                fbuf = _io.BytesIO(text.encode('utf-8'))
                fbuf.name = 'watchlist.txt'
                await ctx.bot.send_document(
                    chat_id=self.chat_id,
                    document=InputFile(fbuf, filename='watchlist.txt'),
                    caption=f'📋 Watchlist — полный список ({total} строк)',
                    reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton('⬅️ Назад', callback_data='hydraroute:main')]]),
                )
            except Exception as e: log.warning('watchlist file send failed: %s', e)
            self._status_msg_id = None
            return

        # --- MATCH ---
        if was_match and self._status_msg_id:
            stripped = text.strip() if text else ''
            if stripped.startswith('OK'):
                parts = stripped.split(None, 3)
                if len(parts) >= 4:
                    final = f'🟢 <b>Маршрутизируется через HR</b>\n\nДомен: <code>{_esc(parts[3])}</code>\nПолитика: <b>{_esc(parts[1])}</b>'
                else:
                    final = f'🟢 <b>OK</b>\n\n<pre>{_esc(stripped)}</pre>'
            elif stripped.startswith('NO'):
                final = '⚪ <b>Не найдено в HR</b>\n<i>Пойдёт напрямую через WAN.</i>'
            else:
                final = '🎯 <b>Match</b>'
                if stripped: final += f'\n\n<pre>{_esc(stripped[-1500:])}</pre>'
        
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('🔄 Ещё', callback_data='hydraroute:ask:match')],
                [InlineKeyboardButton('⬅️ Назад', callback_data='hydraroute:main')],
            ])
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id, message_id=self._status_msg_id,
                    text=final, parse_mode='HTML', reply_markup=kb,
                )
            except Exception as e:
                log.debug('final match M1 failed: %s', e)
            self._status_msg_id = None
            return

        # --- UNINSTALL / INSTALL / OTHER ---
        if self._status_msg_id:
            if was_cleanup: m1_title = '🗑 <b>Удаление остатков</b>'
            elif was_uninstall: m1_title = '🗑 <b>Удаление HydraRoute</b>'
            elif offer_start: m1_title = '📦 <b>Установка HydraRoute</b>'
            else: m1_title = '⚙️ <b>Операция</b>'
            tail_m1 = text[-3500:] if len(text) > 3500 else text
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id, message_id=self._status_msg_id,
                    text=f'{m1_title}\n\n<pre>{_esc(tail_m1)}</pre>',
                    parse_mode='HTML', reply_markup=None,
                )
            except Exception as e: log.debug('final M1 update failed: %s', e)
            self._status_msg_id = None

        if offer_start:
            header = f'{icon} <b>Установка HydraRoute завершена</b>\n<i>exit code: {rc}</i>'
            kb = InlineKeyboardMarkup([[InlineKeyboardButton('⬅️ Назад', callback_data='hydraroute:main')]])
        elif was_cleanup:
            header = f'{icon} <b>Остатки удалены</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([[InlineKeyboardButton('⬅️ Назад', callback_data='hydraroute:main')]])
        else:
            header = f'{icon} <b>Завершено</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([[InlineKeyboardButton('⬅️ Назад', callback_data='hydraroute:main')]])

        body = header
        if rc != 0 and text and not was_match:
            err_tail = '\n'.join(text.split('\n')[-15:])
            body += f'\n\n<pre>{_esc(err_tail[-1500:])}</pre>'

        try:
            await ctx.bot.send_message(chat_id=self.chat_id, text=body, parse_mode='HTML', reply_markup=kb)
        except Exception as e: log.warning('final M2 send failed: %s', e)
    
        if rc == 0 and was_uninstall: await self._check_leftovers(ctx)
RB_MODULES_HYDRAROUTE_MODULE_PY_EOF

echo "  → modules/hydraroute/actions.py"
cat > /opt/router_bot/modules/hydraroute/actions.py << 'RB_MODULES_HYDRAROUTE_ACTIONS_PY_EOF'
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
    """Проверяет, установлен ли HydraRoute.
    Ищет hrneo/hrweb/hrdns в opkg И файлы на диске
    (для случая, когда пакет поставлен вручную, не через opkg)."""
    import subprocess
    import os as _os
    # 1. opkg
    for pkg in ('hrneo', 'hrweb', 'hrdns'):
        try:
            r = subprocess.run(
                ['sh', '-c',
                 f'opkg list-installed 2>/dev/null | grep -qE "^{pkg}([ -]|$)"'],
                timeout=5,
            )
            if r.returncode == 0:
                return True
        except Exception:
            pass
    # 2. Файлы — установка вручную (install-neo.sh)
    for f in ('/opt/sbin/hrneo', '/opt/bin/hrneo',
              '/opt/etc/init.d/S99hrneo', '/opt/etc/HydraRoute'):
        if _os.path.exists(f):
            return True
    return False


def get_installed_version() -> str:
    """Версия HydraRoute: из opkg, иначе из hrneo --version."""
    import subprocess
    # 1. opkg
    for pkg in ('hrneo', 'hrweb', 'hrdns'):
        try:
            p = subprocess.run(
                ['sh', '-c',
                 f'opkg list-installed 2>/dev/null | grep -E "^{pkg}([ -]|$)"'],
                capture_output=True, text=True, timeout=5,
            )
            for line in (p.stdout or '').splitlines():
                parts = line.split()
                if len(parts) >= 3 and parts[0] == pkg:
                    return parts[2]
        except Exception:
            pass
    # 2. hrneo --version (для ручной установки)
    for path in ('/opt/bin/hrneo', '/opt/sbin/hrneo'):
        try:
            r = subprocess.run(
                [path, '--version'],
                capture_output=True, text=True, timeout=5,
            )
            out = ((r.stdout or '') + (r.stderr or '')).strip()
            if out and 'v' in out.lower():
                # 'hrneo v3.24.0-1' → '3.24.0-1'
                import re as _re
                m = _re.search(r'v?([0-9][0-9A-Za-z.\-]+)', out)
                if m:
                    return m.group(1)
        except Exception:
            pass
    return ''


def is_running() -> bool:
    """Запущен ли hrneo или hrweb."""
    import subprocess
    try:
        r = subprocess.run(
            ['sh', '-c', 'ps w | grep -E "[h]rneo|[h]rweb" | grep -v grep | wc -l'],
            capture_output=True, text=True, timeout=5,
        )
        return int((r.stdout or '0').strip()) > 0
    except Exception:
        return False



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
    """Версии компонентов HR: из opkg или из бинарников."""
    import re
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
    if not v['neo']:
        try:
            r = _sp.run(['/opt/bin/hrneo', '--version'], capture_output=True, text=True, timeout=3)
            out = (r.stdout or '') + (r.stderr or '')
            m = re.search(r'v?([0-9][0-9A-Za-z.\-]+)', out)
            if m: v['neo'] = m.group(1)
        except Exception: pass
    if not v['web']:
        try:
            r = _sp.run(['/opt/bin/hrweb', '--version'], capture_output=True, text=True, timeout=3)
            out = (r.stdout or '') + (r.stderr or '')
            m = re.search(r'v?([0-9][0-9A-Za-z.\-]+)', out)
            if m: v['web'] = m.group(1)
            else:
                r = _sp.run(['/opt/bin/hrweb'], capture_output=True, text=True, timeout=3)
                out = (r.stdout or '') + (r.stderr or '')
                m = re.search(r'v?([0-9][0-9A-Za-z.\-]+)', out)
                if m: v['web'] = m.group(1)
        except Exception: pass
    if not v['hrdns']:
        try:
            r = _sp.run(['/opt/bin/hrdns', '--version'], capture_output=True, text=True, timeout=3)
            out = (r.stdout or '') + (r.stderr or '')
            m = re.search(r'v?([0-9][0-9A-Za-z.\-]+)', out)
            if m: v['hrdns'] = m.group(1)
            else:
                r = _sp.run(['/opt/bin/hrdns'], capture_output=True, text=True, timeout=3)
                out = (r.stdout or '') + (r.stderr or '')
                m = re.search(r'v?([0-9][0-9A-Za-z.\-]+)', out)
                if m: v['hrdns'] = m.group(1)
        except Exception: pass
    return v


UPDATE_STATUS_FILE = '/opt/router_bot/data/hydraroute/update_status.json'

def get_update_status() -> dict:
    import json, os
    if os.path.exists(UPDATE_STATUS_FILE):
        try:
            with open(UPDATE_STATUS_FILE) as f:
                data = json.load(f)
            # Сверяем сохранённые installed-версии с реально установленными
            # Если они изменились (пользователь обновился), пересчитываем статус
            current_vers = get_versions()
            pkgs = data.get('packages', {})
            has_updates = False
            for p, d in pkgs.items():
                if p == 'hrneo': d['installed'] = current_vers['neo'] or d.get('installed', '')
                elif p == 'hrweb': d['installed'] = current_vers['web'] or d.get('installed', '')
                elif p == 'hrdns': d['installed'] = current_vers['hrdns'] or d.get('installed', '')
                
                ins = d.get('installed', '')
                lat = d.get('latest', '')
                if ins and lat and ins != lat:
                    d['update'] = True
                    has_updates = True
                else:
                    d['update'] = False
            data['has_updates'] = has_updates
            return data
        except Exception:
            pass
    return {}

def save_update_status(data: dict):
    import json, os
    os.makedirs(os.path.dirname(UPDATE_STATUS_FILE), exist_ok=True)
    try:
        with open(UPDATE_STATUS_FILE, 'w') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
    except Exception:
        pass

def check_updates() -> dict:
    """Проверка обновлений через локальный кэш opkg или прямой curl."""
    import glob, os, subprocess, threading
    pkgs = ('hrneo', 'hrweb', 'hrdns')
    result = {p: {'installed': '', 'latest': '', 'update': False} for p in pkgs}

    # 1. Установленные версии
    vers = get_versions()
    result['hrneo']['installed'] = vers['neo']
    result['hrweb']['installed'] = vers['web']
    result['hrdns']['installed'] = vers['hrdns']

    # 2. Запускаем opkg update в фоне, чтобы кэш был свежим
    def _bg_update():
        try:
            subprocess.run(['sh', '-c', 'opkg update >/dev/null 2>&1'], timeout=60)
        except Exception:
            pass
    threading.Thread(target=_bg_update, daemon=True).start()

    # 3. Читаем локальный кэш opkg (моментально, без интернета)
    pkg_data = {}
    for fpath in glob.glob('/opt/var/opkg-lists/*ground-zerro*'):
        try:
            with open(fpath, 'r', errors='replace') as f:
                current_pkg = None
                for line in f:
                    if line.startswith('Package: '):
                        current_pkg = line[9:].strip()
                    elif line.startswith('Version: ') and current_pkg:
                        pkg_data[current_pkg] = line[9:].strip()
                        current_pkg = None
        except Exception:
            pass

    # 4. Если локальный кэш пуст, скачиваем через curl
    if not pkg_data:
        import gzip
        try:
            r = subprocess.run(
                ['curl', '-sL', '--max-time', '15', 'https://git.zerrolabs.org/Ground-Zerro/release/pages/keenetic/mipselsf-k3.4/Packages.gz'],
                capture_output=True
            )
            if r.returncode == 0 and r.stdout:
                data = gzip.decompress(r.stdout).decode('utf-8', errors='replace')
                current_pkg = None
                for line in data.splitlines():
                    if line.startswith('Package: '):
                        current_pkg = line[9:].strip()
                    elif line.startswith('Version: ') and current_pkg:
                        pkg_data[current_pkg] = line[9:].strip()
                        current_pkg = None
        except Exception:
            pass

    # 5. Сопоставляем пакеты
    for p in pkgs:
        if p in pkg_data:
            result[p]['latest'] = pkg_data[p]
        else:
            for k, v in pkg_data.items():
                if k == p or k.startswith(p + '-') or k.startswith(p + '_'):
                    result[p]['latest'] = v
                    break

    # 6. Сравнение версий
    has_updates = False
    for p in pkgs:
        ins = result[p]['installed']
        lat = result[p]['latest']
        if ins and lat and ins != lat:
            result[p]['update'] = True
            has_updates = True

    save_update_status({'has_updates': has_updates, 'packages': result})
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
RB_MODULES_HYDRAROUTE_ACTIONS_PY_EOF

echo "  → modules/flashkeen/__init__.py"
cat > /opt/router_bot/modules/flashkeen/__init__.py << 'RB_MODULES_FLASHKEEN___INIT___PY_EOF'

RB_MODULES_FLASHKEEN___INIT___PY_EOF

echo "  → modules/flashkeen/module.py"
cat > /opt/router_bot/modules/flashkeen/module.py << 'RB_MODULES_FLASHKEEN_MODULE_PY_EOF'
"""Модуль Flashkeen — интерактивный терминал в Telegram."""
import asyncio
import fcntl
import html
import logging
import os
import pty
import re
import subprocess
import time

from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import MessageHandler, filters, ContextTypes

from .actions import (
    INSTALL_CMD, UNINSTALL_CMD, UPDATE_ENTWARE_CMD,
    FLASHKEEN_LAUNCH, find_flashkeen,
    UNINSTALL_TARGETS,
    SCAN_PATTERNS,
)

from core.utils import (
    existing_targets, sync_opts, build_uninstall_menu,
    collect_uninstall_cmd, toggle_opt,
    scan_leftovers, build_leftovers_message,
    ui_edit_q, ui_edit_or_send,
    show_card,
    show_card,
    ui_edit_q,
)
from core.utils import set_last_msg

log = logging.getLogger(__name__)

MAX_MSG = 3500


def _esc(s: str) -> str:
    return html.escape(s or '')


def _strip_ansi(s: str) -> str:
    s = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', s)
    s = re.sub(r'\x1b\][^\x07]*\x07', '', s)
    s = re.sub(r'\x1b[=>]', '', s)
    return s


def _has_question(buf: bytes) -> bool:
    low = buf.lower()
    for p in (b'(y/n)', b'[y/n]', b'[Y/n]', b'[y/N]', b'yes/no',
              b'are you sure', b'continue?', b'proceed?'):
        if p in low:
            return True
    return False


def _split(text, size=MAX_MSG):
    if not text:
        return ['']
    chunks, cur = [], ''
    for line in text.splitlines(keepends=True):
        if len(cur) + len(line) > size:
            if cur:
                chunks.append(cur)
            cur = line
            while len(cur) > size:
                chunks.append(cur[:size])
                cur = cur[size:]
        else:
            cur += line
    if cur:
        chunks.append(cur)
    return chunks


MENU_ITEM_RE = re.compile(r'^\s*[\[\(]?(\d{1,2})[\]\)\.]\s+\S', re.MULTILINE)


def _detect_menu_items(text: str):
    tail = text[-1500:]
    items = MENU_ITEM_RE.findall(tail)
    nums = sorted({int(n) for n in items})
    return [n for n in nums if 0 <= n <= 12]


class FlashkeenModule:
    name = 'flashkeen'
    title = 'Flashkeen'
    icon = '\U0001f4be'
    description = 'менеджер дисков и Entware'
    category = 'services'
    category_title = 'Сервис'
    category_icon = '\U0001f6e0'
    commands = [('fk', '💾 Flashkeen')]
    cleanup_paths = [
        '/opt/bin/f',
        '/opt/sbin/f',
        '/opt/bin/flashkeen',
        '/opt/sbin/flashkeen',
        '/opt/etc/flashkeen',
        '/opt/var/log/flashkeen*',
        '/opt/var/run/flashkeen*',
    ]
    cleanup_init = []

    def __init__(self, chat_id):
        self.chat_id = str(chat_id)
        self._proc_pid = None
        self._master = None
        self._running = False
        self._mode = 'idle'
        self._status_msg_id = None
        self._last_edit = 0.0
        self._buf = b''
        self._text_input_mode = False
        self._question_msg_id = None
        self._awaiting_yn = False
        self._last_action = None
        self._uninstall_opts = {
            'bin': True,
            'configs': True,
            'logs': True,
        }

    async def startup(self, app):
        app.add_handler(MessageHandler(
            filters.TEXT & ~filters.COMMAND,
            self._handle_text,
        ))
        log.info('Flashkeen module started')

    async def on_leave(self):
        self._kill()

    def _kill(self):
        import signal
        pid = getattr(self, '_proc_pid', None)
        if pid:
            # Убиваем всю группу процессов (pty.fork создаёт новую сессию)
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(os.getpgid(pid), sig)
                except ProcessLookupError:
                    break
                except Exception as e:
                    log.debug('killpg %s: %s', sig, e)
                    # fallback — одиночный kill
                    try:
                        os.kill(pid, sig)
                    except Exception:
                        pass
                time.sleep(0.5)
            # подстраховка: убить через waitpid, если остался зомби
            try:
                os.waitpid(pid, os.WNOHANG)
            except Exception:
                pass
            self._proc_pid = None
        if self._master is not None:
            try:
                os.close(self._master)
            except Exception:
                pass
            self._master = None
        self._running = False
        self._mode = 'idle'
        self._text_input_mode = False
        self._awaiting_yn = False

    # ================= UI =================

    def _build_card(self):
        path = find_flashkeen()
        installed = bool(path)

        lines = [f'{self.icon} <b>{self.title}</b>', '']
        if installed:
            lines.append(f'✅ Установлен: <code>{_esc(path)}</code>')
        else:
            lines.append('❌ Не установлен')
        lines.append('')

        if self._running:
            lines.append('⏳ <b>Сессия активна</b>')
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Закрыть сессию',
                                      callback_data='flashkeen:kill')],
                [
                    InlineKeyboardButton('\u2b05\ufe0f Назад', callback_data='router:cat:services'),
                    InlineKeyboardButton('\U0001f3e0 Модули',
                                         callback_data='router:main'),
                ],
            ])
            return '\n'.join(lines), kb

        rows = []
        if installed:
            rows.append([InlineKeyboardButton(
                '\u25b6\ufe0f Запустить Flashkeen',
                callback_data='flashkeen:run')])
        else:
            rows.append([InlineKeyboardButton(
                '\u2b07\ufe0f Установить Flashkeen',
                callback_data='flashkeen:ask:install')])
        rows.append([InlineKeyboardButton(
            '\u2b06\ufe0f Обновить Entware',
            callback_data='flashkeen:ask:update')])
        if installed:
            rows.append([InlineKeyboardButton(
                '\U0001f5d1 Удалить Flashkeen',
                callback_data='flashkeen:ask:uninstall')])
        rows.append([InlineKeyboardButton(
            '\U0001f504 Обновить карточку',
            callback_data='flashkeen:main')])
        rows.append([
            InlineKeyboardButton('\u2b05\ufe0f Назад', callback_data='router:cat:services'),
            InlineKeyboardButton('\U0001f3e0 Модули', callback_data='router:main'),
        ])
        return '\n'.join(lines), InlineKeyboardMarkup(rows)

    async def send_card_message(self, update, ctx):
        text, kb = self._build_card()
        await show_card(update, ctx, text, kb=kb)

    # --- статус для карточки «Сервис» ---
    conflicts_with = {}

    def get_installed(self) -> bool:
        return bool(find_flashkeen())

    def get_status_short(self) -> str:
        return '✅' if find_flashkeen() else '❌'

    async def handle_callback(self, action, q, ctx):
        if action == 'main':
            await q.answer()
            text, kb = self._build_card()
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower():
                    raise
            return

        if action == 'cleanup:all':
            await q.answer()
            return await self._do_cleanup(q, ctx)

        if action == 'ask:uninstall':
            await q.answer()
            return await self._show_uninstall_menu(q, ctx)

        if action.startswith('opt:'):
            return await self._handle_opt(q, ctx, action[4:])

        if action.startswith('ask:'):
            key = action[4:]
            await q.answer()
            titles = {
                'install': ('\u2b07\ufe0f Установка Flashkeen',
                            'Будет скачан и запущен установочный скрипт с GitHub.\n'
                            '<code>github.com/miha75vu-bit/Flashkeen</code>'),
                'update': ('\u2b06\ufe0f Обновление Entware',
                           'Команда: <code>opkg update &amp;&amp; opkg upgrade</code>\n\n'
                           'Может занять от 1 до 30 минут.'),
                'uninstall': ('\U0001f5d1 Удаление Flashkeen',
                              'Запустится официальный uninstall.sh.\n'
                              'Данные на дисках не тронутся.'),
            }
            t = titles.get(key)
            if not t:
                return
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2705 Подтвердить',
                                      callback_data=f'flashkeen:go:{key}')],
                [InlineKeyboardButton('\u274c Отмена',
                                      callback_data='flashkeen:main')],
            ])
            await q.edit_message_text(
                f'{t[0]}\n\n{t[1]}\n\nПодтвердить?',
                parse_mode='HTML', reply_markup=kb,
            )
            return

        if action.startswith('go:'):
            key = action[3:]
            await q.answer()
            cmds = {
                'install': INSTALL_CMD,
                'update': UPDATE_ENTWARE_CMD,
                'uninstall': UNINSTALL_CMD,
            }
            cmd = cmds.get(key)
            if not cmd:
                return
            await self._start_action(q, ctx, key, cmd)
            return

        if action == 'run':
            await q.answer('Запускаю...')
            await self._start_interactive(q, ctx)
            return

        if action == 'kill':
            await q.answer('Закрываю...')
            self._kill()
            try:
                await q.edit_message_text(
                    '\U0001f6d1 Сессия закрыта.\n\nНапишите /start для возврата.',
                )
            except Exception:
                pass
            return

        if action.startswith('send:'):
            data = action[5:]
            payload = {
                'y': b'y\r', 'n': b'n\r', 'enter': b'\r',
                'esc': b'\x1b', 'tab': b'\t',
            }.get(data)
            if payload is None and data.isdigit():
                payload = (data + '\r').encode()
            if payload is None:
                return
            await self._send_input(q, ctx, payload)
            return

        if action.startswith('menu:'):
            n = action[5:]
            payload = (n + '\r').encode()
            await self._send_input(q, ctx, payload)
            return

        if action == 'text_input':
            await q.answer('Напишите текст следующим сообщением')
            self._text_input_mode = True
            try:
                await q.edit_message_reply_markup(
                    InlineKeyboardMarkup([
                        [InlineKeyboardButton('\u274c Отмена',
                                              callback_data='flashkeen:text_cancel')],
                    ]),
                )
            except Exception:
                pass
            return

        if action == 'text_cancel':
            await q.answer()
            self._text_input_mode = False
            await self._refresh_interactive(ctx)
            return

        if action == 'refresh':
            await q.answer()
            await self._refresh_interactive(ctx)
            return

        await q.answer()

    # ================= actions (стриминг) =================

    # ================= удаление остатков =================

    async def _check_leftovers(self, ctx):
        try:
            leftovers = scan_leftovers(SCAN_PATTERNS)
        except Exception as e:
            log.debug('scan_leftovers failed: %s', e)
            return
        if not leftovers:
            return
        self._leftovers = leftovers
        text, kb = build_leftovers_message(leftovers, prefix='flashkeen')
        try:
            await ctx.bot.send_message(
                chat_id=self.chat_id,
                text=text,
                parse_mode='HTML',
                reply_markup=kb,
            )
        except Exception as e:
            log.warning('send leftovers failed: %s', e)

    async def _do_cleanup(self, q, ctx):
        if not getattr(self, '_leftovers', None):
            await q.answer('Нечего удалять', show_alert=True)
            return

        parts = []
        total = len(self._leftovers)
        for p in self._leftovers:
            safe = p.replace("'", "'\\''")
            parts.append(f"echo 'Удаляю: {safe}' ; rm -rf '{safe}'")
        parts.append(f"echo '' ; echo 'Готово: удалено {total} элементов'")
        cmd = ' ; '.join(parts)
        self._leftovers = []

        self._buf = b''
        self._last_edit = 0.0
        self._running = True
        self._mode = 'action'
        self._last_action = 'cleanup'
        self._status_msg_id = await ui_edit_q(
                q,
                '\U0001f5d1 <b>Удаление остатков Flashkeen</b>\n\n<pre>запуск...</pre>',
                kb=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='flashkeen:kill')],
            ]),
            )

        pid, master = pty.fork()
        if pid == 0:
            try:
                os.environ['TERM'] = 'dumb'
                os.execv('/bin/sh', ['sh', '-c', cmd])
            except Exception:
                os._exit(1)
        self._proc_pid = pid
        self._master = master
        asyncio.create_task(self._reader_loop_action(ctx, pid, master))

    # ================= меню удаления =================

    async def _show_uninstall_menu(self, q, ctx):
        targets = existing_targets(UNINSTALL_TARGETS)
        self._uninstall_opts = sync_opts(targets, self._uninstall_opts)

        text, kb = build_uninstall_menu(
            targets,
            self._uninstall_opts,
            title='Удаление Flashkeen',
            always_msg=(
                'Будет запущен официальный uninstall.sh с GitHub.'
            ),
            prefix='flashkeen',
        )
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise
    async def _handle_opt(self, q, ctx, key):
        if key in self._uninstall_opts:
            toggle_opt(self._uninstall_opts, key)
            state = 'вкл' if self._uninstall_opts[key] else 'выкл'
            await q.answer(f'{state}: {key}')
            await self._show_uninstall_menu(q, ctx)
            return

        if key == 'go':
            await q.answer()
            targets = existing_targets(UNINSTALL_TARGETS)
            base_cmd = UNINSTALL_CMD
            cmd = collect_uninstall_cmd(targets, self._uninstall_opts, base_cmd)
            self._uninstall_opts = {}

            self._buf = b''
            self._last_edit = 0.0
            self._running = True
            self._mode = 'action'
            self._last_action = 'uninstall'
            self._status_msg_id = await ui_edit_q(
                q,
                '\U0001f5d1 <b>Удаление Flashkeen</b>\n\n<pre>запуск...</pre>',
                kb=InlineKeyboardMarkup([
                    [InlineKeyboardButton('\U0001f6d1 Отменить',
                                          callback_data='flashkeen:kill')],
                ]),
            )

            pid, master = pty.fork()
            if pid == 0:
                try:
                    os.environ['TERM'] = 'dumb'
                    os.execv('/bin/sh', ['sh', '-c', cmd])
                except Exception:
                    os._exit(1)
            self._proc_pid = pid
            self._master = master
            asyncio.create_task(self._reader_loop_action(ctx, pid, master))
            return

        await q.answer()
    async def _start_action(self, q, ctx, key, cmd):
        if self._running:
            return
        self._running = True
        self._last_action = key
        self._mode = 'action'
        self._buf = b''
        self._last_edit = 0.0

        self._status_msg_id = await ui_edit_q(
            q,
            '\u23f3 <b>Выполняется...</b>\n\n<pre>запуск...</pre>',
            kb=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='flashkeen:kill')],
            ]),
        )

        pid, master = pty.fork()
        if pid == 0:
            try:
                os.environ['DEBIAN_FRONTEND'] = 'noninteractive'
                os.environ['TERM'] = 'dumb'
                os.execv('/bin/sh', ['sh', '-c', cmd])
            except Exception:
                os._exit(1)
        self._proc_pid = pid
        self._master = master
        asyncio.create_task(self._reader_loop_action(ctx, pid, master))

    def _drain_master(self, master):
        """Дочитывает остаток из pty после смерти процесса."""
        import select as _select
        try:
            while True:
                r, _, _ = _select.select([master], [], [], 0.3)
                if not r:
                    break
                try:
                    data = os.read(master, 4096)
                except (BlockingIOError, OSError):
                    break
                if not data:
                    break
                self._buf += data
        except Exception as e:
            log.debug('drain_master: %s', e)

    async def _reader_loop_action(self, ctx, pid, master):
        try:
            import fcntl
            fcntl.fcntl(master, fcntl.F_SETFL, os.O_NONBLOCK)
        except Exception as e:
            log.warning('set nonblock failed: %s', e)

        idle_start = time.time()
        start_time = time.time()
        timeout_total = 180
        try:
            while True:
                if time.time() - start_time > timeout_total:
                    log.warning('Timeout %ss, killing process', timeout_total)
                    try:
                        os.kill(pid, 9)
                    except Exception:
                        pass
                    self._buf += b'\n[!] Timeout: process killed\n'
                    break
                try:
                    wpid, _ws = os.waitpid(pid, os.WNOHANG)
                    if wpid == pid:
                        self._drain_master(master)
                        break
                except ChildProcessError:
                    self._drain_master(master)
                    break
                except Exception:
                    pass

                try:
                    data = os.read(master, 4096)
                    idle_start = time.time()
                except BlockingIOError:
                    if time.time() - idle_start > 2.0:
                        try:
                            wpid, _ws = os.waitpid(pid, os.WNOHANG)
                            if wpid == pid:
                                self._drain_master(master)
                                break
                        except Exception:
                            pass
                    await asyncio.sleep(0.1)
                    continue
                except OSError:
                    break
                if not data:
                    break
                self._buf += data
                if len(self._buf) > 60000:
                    self._buf = self._buf[-50000:]
                now = time.time()
                if now - self._last_edit >= 1.0:
                    self._last_edit = now
                    await self._edit_status(ctx, self._buf, tail=2000)
                if not self._awaiting_yn and _has_question(self._buf[-500:]):
                    await self._ask_yn(ctx, self._buf)
        finally:
            try:
                os.close(master)
            except Exception:
                pass
            self._master = None
        try:
            _, status = os.waitpid(pid, 0)
            rc = os.waitstatus_to_exitcode(status)
        except ChildProcessError:
            rc = 0
        except Exception:
            rc = -1
        self._proc_pid = None
        await self._finish_action(ctx, self._buf, rc)
    async def _edit_status(self, ctx, buf, tail=2000):
        if not self._status_msg_id:
            return
        text = _strip_ansi(buf.decode('utf-8', errors='replace'))
        text = text[-tail:] if len(text) > tail else text
        try:
            await ctx.bot.edit_message_text(
                chat_id=self.chat_id,
                message_id=self._status_msg_id,
                text=f'⏳ <b>Выполняется...</b>\n\n<pre>{_esc(text)}</pre>',
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton('\U0001f6d1 Отменить',
                                          callback_data='flashkeen:kill')],
                ]),
            )
        except Exception as e:
            if 'not modified' not in str(e).lower():
                log.debug('edit status: %s', e)

    async def _ask_yn(self, ctx, buf):
        if self._awaiting_yn:
            return
        self._awaiting_yn = True
        if not self._status_msg_id:
            return
        text = _strip_ansi(buf.decode('utf-8', errors='replace'))
        tail = text[-1800:] if len(text) > 1800 else text
        try:
            await ctx.bot.edit_message_text(
                chat_id=self.chat_id,
                message_id=self._status_msg_id,
                text=f'\u2753 <b>Требуется ответ</b>\n\n<pre>{_esc(tail)}</pre>',
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton('\u2705 Да (y)', callback_data='flashkeen:send:y'),
                     InlineKeyboardButton('\u274c Нет (n)', callback_data='flashkeen:send:n')],
                    [InlineKeyboardButton('\u23ce Enter', callback_data='flashkeen:send:enter'),
                     InlineKeyboardButton('\U0001f6d1 Прервать', callback_data='flashkeen:kill')],
                ]),
            )
        except Exception as e:
            if 'not modified' not in str(e).lower():
                log.debug('ask_yn edit: %s', e)

    async def _send_input(self, q, ctx, payload: bytes):
        if not getattr(self, '_proc_pid', None) or self._master is None:
            await q.answer('Сессия завершена', show_alert=True)
            return
        try:
            os.write(self._master, payload)
            await q.answer(f'Отправлено: {payload.decode(errors="replace").strip() or "Enter"}')
        except OSError as e:
            log.warning('write failed: %s', e)
            await q.answer('Ошибка отправки', show_alert=True)
            return
        if self._question_msg_id:
            try:
                await ctx.bot.delete_message(
                    chat_id=self.chat_id, message_id=self._question_msg_id,
                )
            except Exception:
                pass
            self._question_msg_id = None
        self._awaiting_yn = False
        self._text_input_mode = False
        asyncio.create_task(self._refresh_interactive(ctx))

    async def _finish_action(self, ctx, buf, rc):
        self._running = False
        self._mode = 'idle'
        was_uninstall = (self._last_action == 'uninstall')
        was_cleanup = (self._last_action == 'cleanup')
        text = _strip_ansi(buf.decode('utf-8', errors='replace'))

        if self._question_msg_id:
            try:
                await ctx.bot.delete_message(
                    chat_id=self.chat_id, message_id=self._question_msg_id,
                )
            except Exception:
                pass
            self._question_msg_id = None
        self._awaiting_yn = False

        # Фильтр шума opkg
        if rc == 0 and 'Collected errors' in text:
            new_lines = []
            skip = False
            for ln in text.split('\n'):
                if 'Collected errors' in ln:
                    skip = True
                    continue
                if skip:
                    if ln.strip().startswith('*'):
                        if 'is not installed' in ln:
                            continue
                        new_lines.append(ln)
                        continue
                    else:
                        skip = False
                new_lines.append(ln)
            text = '\n'.join(new_lines).strip()

        offer_start = (
            self._last_action == 'install'
            and rc == 0
            and find_flashkeen()
        )
        self._last_action = None

        icon = '\u2705' if rc == 0 else '\u274c'
        # M1 — полным логом с заголовком
        if self._status_msg_id:
            if was_cleanup:
                m1_title = '\U0001f5d1 <b>Удаление остатков</b>'
            elif was_uninstall:
                m1_title = '\U0001f5d1 <b>Удаление Flashkeen</b>'
            elif offer_start:
                m1_title = '\U0001f4e6 <b>Установка Flashkeen</b>'
            else:
                m1_title = '\u2699\ufe0f <b>Операция</b>'

            tail_m1 = text[-3500:] if len(text) > 3500 else text
            m1_text = f'{m1_title}\n\n<pre>{_esc(tail_m1)}</pre>'
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id,
                    message_id=self._status_msg_id,
                    text=m1_text,
                    parse_mode='HTML',
                    reply_markup=None,
                )
            except Exception as e:
                log.debug('final M1 update failed: %s', e)
            self._status_msg_id = None

        if offer_start:
            header = (
                f'{icon} <b>Установка Flashkeen завершена</b>\n'
                f'<i>exit code: {rc}</i>'
            )
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u25b6\ufe0f Запустить сейчас',
                                      callback_data='flashkeen:run')],
                [InlineKeyboardButton('\u23ed Позже',
                                      callback_data='flashkeen:main')],
            ])
        elif was_cleanup:
            header = f'{icon} <b>Остатки удалены</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                      callback_data='flashkeen:main')],
            ])
        else:
            header = f'{icon} <b>Завершено</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                      callback_data='flashkeen:main')],
            ])

        body = header
        if rc != 0 and text.strip():
            err_tail = '\n'.join(text.strip().split('\n')[-15:])
            if len(err_tail) > 1500:
                err_tail = err_tail[-1500:]
            body += f'\n\n<pre>{_esc(err_tail)}</pre>'

        try:
            await ctx.bot.send_message(
                chat_id=self.chat_id,
                text=body,
                parse_mode='HTML',
                reply_markup=kb,
            )
        except Exception as e:
            log.warning('final M2 send failed: %s', e)

        if rc == 0 and was_uninstall:
            await self._check_leftovers(ctx)
    async def _start_interactive(self, q, ctx):
        if self._running:
            return
        self._running = True
        self._mode = 'interactive'
        self._buf = b''
        self._last_edit = 0.0

        launch = find_flashkeen() or FLASHKEEN_LAUNCH

        self._status_msg_id = await ui_edit_q(
            q,
            '\u23f3 <b>Запускаю Flashkeen...</b>',
            kb=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Закрыть',
                                      callback_data='flashkeen:kill')],
            ]),
        )

        pid, master = pty.fork()
        if pid == 0:
            try:
                os.environ['TERM'] = 'dumb'
                os.execv('/bin/sh', ['sh', '-c', f'exec {launch}'])
            except Exception:
                os._exit(1)

        self._proc_pid = pid
        self._master = master
        asyncio.create_task(self._reader_loop_interactive(ctx, pid, master))

    async def _reader_loop_interactive(self, ctx, pid, master):
        try:
            fcntl.fcntl(master, fcntl.F_SETFL, os.O_NONBLOCK)
        except Exception as e:
            log.warning('set nonblock failed: %s', e)

        log.info('interactive reader started')
        idle_start = time.time()
        try:
            while True:
                try:
                    wpid, _ws = os.waitpid(pid, os.WNOHANG)
                    if wpid == pid:
                        self._drain_master(master)
                        break
                except ChildProcessError:
                    self._drain_master(master)
                    break
                except Exception:
                    pass

                try:
                    data = os.read(master, 4096)
                    idle_start = time.time()
                except BlockingIOError:
                    if time.time() - idle_start > 2.0:
                        try:
                            wpid, _ws = os.waitpid(pid, os.WNOHANG)
                            if wpid == pid:
                                self._drain_master(master)
                                break
                        except Exception:
                            pass
                    await asyncio.sleep(0.15)
                    continue
                except OSError:
                    break
                if not data:
                    break
                self._buf += data
                if len(self._buf) > 60000:
                    self._buf = self._buf[-50000:]
                _now = time.time()
                if _now - self._last_edit >= 1.0:
                    self._last_edit = _now
                    await self._refresh_interactive(ctx)
        finally:
            try:
                os.close(master)
            except Exception:
                pass
            self._master = None
        log.info('interactive reader finished, buf=%d bytes', len(self._buf))
        try:
            _, status = os.waitpid(pid, 0)
            rc = os.waitstatus_to_exitcode(status)
        except ChildProcessError:
            rc = 0
        except Exception:
            rc = -1
        self._proc_pid = None
        await self._finish_interactive(ctx, self._buf, rc)
    async def _refresh_interactive(self, ctx):
        if not self._status_msg_id:
            return
        text = _strip_ansi(self._buf.decode('utf-8', errors='replace'))
        tail = text[-1800:] if len(text) > 1800 else text

        items = _detect_menu_items(text)
        rows = []
        if items:
            row = []
            for n in items:
                row.append(InlineKeyboardButton(str(n),
                                                callback_data=f'flashkeen:menu:{n}'))
                if len(row) == 4:
                    rows.append(row)
                    row = []
            if row:
                rows.append(row)
        rows.append([
            InlineKeyboardButton('\u2705 y', callback_data='flashkeen:send:y'),
            InlineKeyboardButton('\u274c n', callback_data='flashkeen:send:n'),
            InlineKeyboardButton('\u23ce', callback_data='flashkeen:send:enter'),
        ])
        rows.append([
            InlineKeyboardButton('\u2328\ufe0f Ввести текст', callback_data='flashkeen:text_input'),
            InlineKeyboardButton('\U0001f6d1 Закрыть', callback_data='flashkeen:kill'),
        ])

        hint = '\u2328\ufe0f Напишите текст следующим сообщением' if self._text_input_mode else ''
        text_out = f'<b>Flashkeen</b>\n\n<pre>{_esc(tail)}</pre>'
        if hint:
            text_out += f'\n<i>{hint}</i>'
        try:
            await ctx.bot.edit_message_text(
                chat_id=self.chat_id,
                message_id=self._status_msg_id,
                text=text_out,
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup(rows),
            )
        except Exception as e:
            if 'not modified' not in str(e).lower():
                log.debug('refresh interactive: %s', e)

    async def _finish_interactive(self, ctx, buf, rc):
        self._running = False
        self._mode = 'idle'
        self._text_input_mode = False

        # Удаляем "живое" сообщение, не спамим буфером.
        if self._status_msg_id:
            try:
                await ctx.bot.delete_message(
                    chat_id=self.chat_id, message_id=self._status_msg_id,
                )
            except Exception:
                pass
            self._status_msg_id = None

        # Одно краткое сообщение, что сессия закрыта
        try:
            await ctx.bot.send_message(
                chat_id=self.chat_id,
                text='ℹ️ Сессия Flashkeen закрыта.',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton('⬅️ Назад',
                                          callback_data='flashkeen:main')],
                ]),
            )
        except Exception:
            pass

    # ================= текст от пользователя =================

    async def _handle_text(self, update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        if str(update.effective_chat.id) != self.chat_id:
            return
        if not self._running or self._mode != 'interactive':
            return
        if not self._text_input_mode:
            return
        text = update.message.text or ''
        try:
            os.write(self._master, (text + '\n').encode('utf-8'))
        except Exception as e:
            log.warning('write text failed: %s', e)
            await update.message.reply_text('\u274c Ошибка отправки')
            return
        self._text_input_mode = False
        try:
            await update.message.delete()
        except Exception:
            pass
        await self._refresh_interactive(ctx)
RB_MODULES_FLASHKEEN_MODULE_PY_EOF

echo "  → modules/flashkeen/actions.py"
cat > /opt/router_bot/modules/flashkeen/actions.py << 'RB_MODULES_FLASHKEEN_ACTIONS_PY_EOF'
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
RB_MODULES_FLASHKEEN_ACTIONS_PY_EOF

echo "  → modules/xkeen/__init__.py"
cat > /opt/router_bot/modules/xkeen/__init__.py << 'RB_MODULES_XKEEN___INIT___PY_EOF'

RB_MODULES_XKEEN___INIT___PY_EOF

echo "  → modules/xkeen/module.py"
cat > /opt/router_bot/modules/xkeen/module.py << 'RB_MODULES_XKEEN_MODULE_PY_EOF'
"""Модуль XKeen — установка/управление XKeen."""
import asyncio
import html
import logging
import os
import pty
import re
import subprocess
import time

from telegram import InlineKeyboardButton, InlineKeyboardMarkup

from .actions import (
    ACTIONS, is_installed, get_version, get_service_status, find_xkeen,
    UNINSTALL_TARGETS,
    SCAN_PATTERNS,
)

from core.utils import (
    existing_targets, sync_opts, build_uninstall_menu,
    collect_uninstall_cmd, toggle_opt,
    scan_leftovers, build_leftovers_message,
    ui_edit_q, ui_edit_or_send,
    show_card,
    show_card,
    ui_edit_q,
)
from core.utils import set_last_msg

log = logging.getLogger(__name__)

MAX_MSG = 3500
QUESTION_PATTERNS = [
    b'(y/n)', b'[y/n]', b'[Y/n]', b'[y/N]',
    b'(yes/no)', b'are you sure', b'continue?',
    b'proceed?', b'do you want',
]


def _esc(s: str) -> str:
    return html.escape(s or '')


def _strip_ansi(s: str) -> str:
    s = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', s)
    s = re.sub(r'\x1b\][^\x07]*\x07', '', s)
    s = re.sub(r'\x1b[=>]', '', s)
    return s


def _has_question(buf: bytes) -> bool:
    low = buf.lower()
    for p in QUESTION_PATTERNS:
        if p in low:
            return True
    # Русские подстроки (UTF-8)
    for p in (b'\xd0\xb2\xd1\x8b\xd0\xb1\xd0\xb5\xd1\x80',   # выбер
              b'\xd0\xb2\xd0\xb2\xd0\xb5\xd0\xb4\xd0\xb8',   # введи
              b'\xd0\xbf\xd0\xbe\xd0\xb4\xd1\x82\xd0\xb2\xd0\xb5\xd1\x80',  # подтве
              b'\xd0\xbf\xd1\x80\xd0\xbe\xd0\xb4\xd0\xbe\xd0\xbb\xd0\xb6'): # продол
        if p in low:
            return True
    # Меню с пунктами вида "1)" тоже повод показать кнопки
    text = buf.decode('utf-8', errors='replace')
    if MENU_ITEM_RE.search(text[-2500:]):
        # Проверяем, есть ли признаки меню — например, в конце ":"
        tail = text[-500:].rstrip()
        if tail.endswith(':') or ': ' in tail[-100:]:
            return True
    return False


def _split(text, size=MAX_MSG):
    if not text:
        return ['']
    chunks, cur = [], ''
    for line in text.splitlines(keepends=True):
        if len(cur) + len(line) > size:
            if cur:
                chunks.append(cur)
            cur = line
            while len(cur) > size:
                chunks.append(cur[:size])
                cur = cur[size:]
        else:
            cur += line
    if cur:
        chunks.append(cur)
    return chunks


MENU_ITEM_RE = re.compile(r'^\s*[\[\(]?(\d{1,2})[\]\)\.]\s+\S', re.MULTILINE)


def _detect_menu_items(text: str):
    """Ищет номера пунктов меню в последних строках вывода."""
    tail = text[-2500:]
    items = MENU_ITEM_RE.findall(tail)
    nums = sorted({int(n) for n in items})
    return [n for n in nums if 0 <= n <= 15]


def _menu_row_buttons(items):
    """Строит ряды кнопок по номерам пунктов (по 4 в ряд)."""
    rows = []
    row = []
    for n in items:
        row.append(InlineKeyboardButton(
            str(n), callback_data=f'xkeen:ans:{n}',
        ))
        if len(row) == 4:
            rows.append(row)
            row = []
    if row:
        rows.append(row)
    return rows


class XKeenModule:
    name = 'xkeen'
    title = 'XKeen'
    icon = '\U0001f43e'  # 🐾
    description = 'маршрутизация через Xray/Mihomo'
    category = 'services'
    category_title = 'Сервис'
    category_icon = '\U0001f6e0'
    commands = [('xk', '🐾 XKeen')]
    cleanup_paths = [
        '/opt/sbin/xkeen',
        '/opt/bin/xkeen',
        '/opt/sbin/.xkeen',
        '/opt/etc/xkeen',
        '/opt/var/log/xkeen*',
        '/opt/var/run/xkeen*',
    ]
    cleanup_init = ['S99xkeen']

    def __init__(self, chat_id):
        self.chat_id = str(chat_id)
        self._proc = None
        self._proc_pid = None
        self._master = None
        self._running = False
        self._status_msg_id = None
        self._last_edit = 0.0
        self._buf = b''
        self._awaiting_yn = False
        self._submenu = None  # 'service' | 'updates' | None

    async def startup(self, app):
        log.info('XKeen module started')

    async def on_leave(self):
        self._kill()
        self._submenu = None

    def _kill(self):
        import signal
        pid = getattr(self, '_proc_pid', None)
        if pid:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(os.getpgid(pid), sig)
                except ProcessLookupError:
                    break
                except Exception:
                    try:
                        os.kill(pid, sig)
                    except Exception:
                        pass
                time.sleep(0.4)
            try:
                os.waitpid(pid, os.WNOHANG)
            except Exception:
                pass
            self._proc_pid = None
        if self._master is not None:
            try:
                os.close(self._master)
            except Exception:
                pass
            self._master = None
        self._running = False
        self._awaiting_yn = False

    # ================= UI =================

    def _build_card(self):
        installed = is_installed()
        status = get_service_status()
        version = get_version() if installed else ''

        lines = [f'{self.icon} <b>{self.title}</b>', '']
        if installed:
            v = f' · <code>{version}</code>' if version else ''
            lines.append(f'✅ Установлен{v}')
            if status == 'running':
                lines.append('Сервис: 🟢 работает')
            elif status == 'stopped':
                lines.append('Сервис: 🔴 остановлен')
            else:
                lines.append('Сервис: ⚪ статус неизвестен')
        else:
            lines.append('❌ Не установлен')
        # Проверка конфликта с HydraRoute
        if not installed:
            try:
                import subprocess as _sp
                _hr_proc = False
                _r = _sp.run(['sh', '-c', 'ps w | grep -q "[h]rneo" && echo yes'],
                             capture_output=True, text=True, timeout=3)
                _hr_proc = 'yes' in (_r.stdout or '')
                if _hr_proc:
                    lines.append('\u26a0\ufe0f <b>Конфликт с HydraRoute!</b>')
                    lines.append('<i>Оба используют /opt/etc/xray и запускают демон xray.</i>')
                    lines.append('<i>Удалите HydraRoute перед установкой XKeen.</i>')
                    lines.append('')
            except Exception:
                pass

        lines.append('')

        if self._running:
            lines.append('⏳ <b>Выполняется операция...</b>')
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='xkeen:kill')],
                [
                    InlineKeyboardButton('\u2b05\ufe0f Назад',
                                         callback_data='router:cat:services'),
                    InlineKeyboardButton('\U0001f3e0 Модули',
                                         callback_data='router:main'),
                ],
            ])
            return '\n'.join(lines), kb

        rows = []
        if not installed:
            rows.append([InlineKeyboardButton(
                '\u2b07\ufe0f Установить XKeen',
                callback_data='xkeen:ask:install')])
        else:
            rows.append([InlineKeyboardButton(
                '\u25b6\ufe0f Управление сервисом',
                callback_data='xkeen:service_menu')])
            rows.append([InlineKeyboardButton(
                '\u2699\ufe0f Обновления и канал',
                callback_data='xkeen:updates_menu')])
            rows.append([InlineKeyboardButton(
                '\U0001f527 Системные настройки',
                callback_data='xkeen:system_menu')])
            rows.append([InlineKeyboardButton(
                '\U0001f4ca Диагностика',
                callback_data='xkeen:ask:diag')])
            rows.append([InlineKeyboardButton(
                '\U0001f5d1 Удалить XKeen',
                callback_data='xkeen:ask:uninstall')])
        rows.append([InlineKeyboardButton(
            '\U0001f504 Обновить карточку', callback_data='xkeen:main')])
        rows.append([
            InlineKeyboardButton('\u2b05\ufe0f Назад',
                                 callback_data='router:cat:services'),
            InlineKeyboardButton('\U0001f3e0 Модули',
                                 callback_data='router:main'),
        ])
        return '\n'.join(lines), InlineKeyboardMarkup(rows)

    def _build_service_menu(self):
        status = get_service_status()
        status_str = {
            'running': '🟢 работает',
            'stopped': '🔴 остановлен',
            'unknown': '⚪ неизвестно',
        }.get(status, '⚪ неизвестно')

        lines = [
            f'{self.icon} <b>Управление сервисом</b>',
            '',
            f'Текущий статус: {status_str}',
            '',
        ]
        rows = [
            [InlineKeyboardButton('\u25b6\ufe0f Запустить',
                                  callback_data='xkeen:ask:start')],
            [InlineKeyboardButton('\u23f9 Остановить',
                                  callback_data='xkeen:ask:stop')],
            [InlineKeyboardButton('\U0001f504 Перезапустить',
                                  callback_data='xkeen:ask:restart')],
            [
                InlineKeyboardButton('\u2b05\ufe0f Назад',
                                     callback_data='xkeen:main'),
                InlineKeyboardButton('\U0001f3e0 Модули',
                                     callback_data='router:main'),
            ],
        ]
        return '\n'.join(lines), InlineKeyboardMarkup(rows)

    def _build_updates_menu(self):
        lines = [
            f'{self.icon} <b>Обновления и канал</b>',
            '',
            'Выберите действие:',
        ]
        rows = [
            [InlineKeyboardButton('⬆️ Обновить ядро Xray',
                                  callback_data='xkeen:ask:update_xray')],
            [InlineKeyboardButton('⬆️ Обновить ядро Mihomo',
                                  callback_data='xkeen:ask:update_mihomo')],
            [InlineKeyboardButton('\U0001f30d Обновить геофайлы',
                                  callback_data='xkeen:ask:update_geo')],
            [InlineKeyboardButton('⬆️ Обновить XKeen',
                                  callback_data='xkeen:ask:update_xkeen')],
            [InlineKeyboardButton('\U0001f504 Настроить автообновления',
                                  callback_data='xkeen:ask:update_auto')],
            [InlineKeyboardButton('\u2699\ufe0f Сменить канал (Stable/Dev)',
                                  callback_data='xkeen:ask:channel')],
            [
                InlineKeyboardButton('\u2b05\ufe0f Назад',
                                     callback_data='xkeen:main'),
                InlineKeyboardButton('\U0001f3e0 Модули',
                                     callback_data='router:main'),
            ],
        ]
        return '\n'.join(lines), InlineKeyboardMarkup(rows)

    def _build_system_menu(self):
        lines = [
            f'{self.icon} <b>Системные настройки XKeen</b>',
            '',
            'Выберите действие:',
        ]
        rows = [
            [InlineKeyboardButton('\U0001f517 Зарегистрировать Xray',
                                  callback_data='xkeen:ask:register_xray')],
            [InlineKeyboardButton('\U0001f517 Зарегистрировать XKeen',
                                  callback_data='xkeen:ask:register_xkeen')],
            [InlineKeyboardButton('\U0001f4c4 Пересоздать init-скрипт',
                                  callback_data='xkeen:ask:register_init')],
            [InlineKeyboardButton('\U0001f50c Показать порты прокси',
                                  callback_data='xkeen:ask:ports_show')],
            [InlineKeyboardButton('\U0001f6ab Показать исключённые порты',
                                  callback_data='xkeen:ask:ports_excl_show')],
            [InlineKeyboardButton('\U0001f50d Тест соединения',
                                  callback_data='xkeen:ask:test_conn')],
            [InlineKeyboardButton('\U0001f4ca Управление дескрипторами',
                                  callback_data='xkeen:ask:fd_toggle')],
            [InlineKeyboardButton('\u2699\ufe0f Автозапуск при загрузке',
                                  callback_data='xkeen:ask:auto_toggle')],
            [
                InlineKeyboardButton('\u2b05\ufe0f Назад',
                                     callback_data='xkeen:main'),
                InlineKeyboardButton('\U0001f3e0 Модули',
                                     callback_data='router:main'),
            ],
        ]
        return '\n'.join(lines), InlineKeyboardMarkup(rows)

    async def send_card_message(self, update, ctx):
        text, kb = self._build_card()
        await show_card(update, ctx, text, kb=kb)

    # --- статус для карточки «Сервис» ---
    conflicts_with = {
        'hydraroute': 'оба используют /opt/etc/xray и запускают демон xray',
    }

    def get_installed(self) -> bool:
        return is_installed()

    def get_status_short(self) -> str:
        if not is_installed():
            return '❌'
        st = get_service_status()
        if st == 'running':
            return '🟢'
        if st == 'stopped':
            return '🔴'
        return '✅'

    async def handle_callback(self, action, q, ctx):
        if action == 'main':
            await q.answer()
            self._submenu = None
            text, kb = self._build_card()
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower():
                    raise
            return

        if action == 'service_menu':
            await q.answer()
            self._submenu = 'service'
            text, kb = self._build_service_menu()
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower():
                    raise
            return

        if action == 'system_menu':
            await q.answer()
            self._submenu = 'system'
            text, kb = self._build_system_menu()
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower():
                    raise
            return

        if action == 'updates_menu':
            await q.answer()
            self._submenu = 'updates'
            text, kb = self._build_updates_menu()
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower():
                    raise
            return

        if action == 'cleanup:all':
            await q.answer()
            return await self._do_cleanup(q, ctx)

        if action == 'ask:uninstall':
            await q.answer()
            return await self._show_uninstall_menu(q, ctx)

        if action.startswith('opt:'):
            return await self._handle_opt(q, ctx, action[4:])

        if action.startswith('ask:'):
            key = action[4:]
            await q.answer()
            a = ACTIONS.get(key)
            if not a:
                await q.answer('Неизвестное действие', show_alert=True)
                return
            desc = a['desc']
            if key == 'install':
                import subprocess as _sp
                def _proc_run(p):
                    try:
                        _r = _sp.run(['sh', '-c', f'ps w | grep -q "[{p[0]}]{p[1:]}" && echo yes'], capture_output=True, text=True, timeout=3)
                        return 'yes' in (_r.stdout or '')
                    except Exception: return False
                warns = []
                if _proc_run('xkeen'): warns.append('XKeen')
                if _proc_run('hrneo'): warns.append('HydraRoute')
                if warns:
                    desc += f'\n\n⚠️ <b>Внимание:</b> сейчас запущен { " и ".join(warns) }. Они занимают маршрутизацию эксклюзивно.'
            text = (
                f'{a["icon"]} <b>{a["title"]}</b>\n\n'
                f'{desc}\n\n'
                f'Подтвердить?'
            )
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2705 Подтвердить',
                                      callback_data=f'xkeen:go:{key}')],
                [InlineKeyboardButton('\u274c Отмена',
                                      callback_data='xkeen:main')],
            ])
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower():
                    raise
            return

        if action.startswith('go:'):
            key = action[3:]
            await q.answer()
            a = ACTIONS.get(key)
            if not a:
                return
            await self._start_action(q, ctx, key, a)
            return

        if action == 'kill':
            await q.answer('Прерываю...')
            self._kill()
            try:
                await q.edit_message_text(
                    '\U0001f6d1 Операция прервана.',
                    reply_markup=InlineKeyboardMarkup([
                        [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                              callback_data='xkeen:main')],
                    ]),
                )
            except Exception:
                pass
            return

        # Кнопки y/n для интерактивных вопросов
        if action == 'ans:y':
            await self._answer(q, b'y\r')
            return
        if action == 'ans:n':
            await self._answer(q, b'n\r')
            return
        if action == 'ans:enter':
            await self._answer(q, b'\r')
            return
        # Цифровые пункты меню
        if action.startswith('ans:'):
            digit = action[4:]
            if digit.isdigit():
                await self._answer(q, (digit + '\r').encode())
                return

        await q.answer()

    async def _answer(self, q, payload: bytes):
        if not getattr(self, '_proc_pid', None) or self._master is None:
            await q.answer('Сессия завершена', show_alert=False)
            return
        try:
            os.write(self._master, payload)
            await q.answer(
                f'Отправлено: {payload.decode(errors="replace").strip() or "Enter"}',
            )
        except OSError as e:
            log.warning('write failed: %s', e)
            await q.answer(f'Ошибка: {e}', show_alert=True)
            return
        self._awaiting_yn = False
        await self._update_status(bot=q.bot)
    # ================= удаление остатков =================

    async def _check_leftovers(self, ctx):
        try:
            leftovers = scan_leftovers(SCAN_PATTERNS)
        except Exception as e:
            log.debug('scan_leftovers failed: %s', e)
            return
        if not leftovers:
            return
        self._leftovers = leftovers
        text, kb = build_leftovers_message(leftovers, prefix='xkeen')
        try:
            await ctx.bot.send_message(
                chat_id=self.chat_id,
                text=text,
                parse_mode='HTML',
                reply_markup=kb,
            )
        except Exception as e:
            log.warning('send leftovers failed: %s', e)

    async def _do_cleanup(self, q, ctx):
        if not getattr(self, '_leftovers', None):
            await q.answer('Нечего удалять', show_alert=True)
            return

        parts = []
        total = len(self._leftovers)
        for p in self._leftovers:
            safe = p.replace("'", "'\\''")
            parts.append(f"echo 'Удаляю: {safe}' ; rm -rf '{safe}'")
        parts.append(f"echo '' ; echo 'Готово: удалено {total} элементов'")
        cmd = ' ; '.join(parts)
        self._leftovers = []

        self._buf = b''
        self._last_edit = 0.0
        self._running = True
        self._last_action = 'cleanup'
        msg = await ctx.bot.send_message(
            chat_id=self.chat_id,
            text='\U0001f5d1 <b>Удаление остатков XKeen</b>\n\n<pre>запуск...</pre>',
            parse_mode='HTML',
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='xkeen:kill')],
            ]),
        )
        self._status_msg_id = msg.message_id
        set_last_msg(self.chat_id, msg.message_id)

        pid, master = pty.fork()
        if pid == 0:
            try:
                os.environ['TERM'] = 'dumb'
                os.execv('/bin/sh', ['sh', '-c', cmd])
            except Exception:
                os._exit(1)
        self._proc_pid = pid
        self._master = master
        asyncio.create_task(self._reader_loop(ctx, pid, master))

    # ================= меню удаления =================

    async def _show_uninstall_menu(self, q, ctx):
        targets = existing_targets(UNINSTALL_TARGETS)
        self._uninstall_opts = sync_opts(targets, self._uninstall_opts)

        text, kb = build_uninstall_menu(
            targets,
            self._uninstall_opts,
            title='Удаление XKeen',
            always_msg=(
                'Пакет <code>xkeen</code> и зависимости удаляются '
                'всегда командой <code>xkeen -remove</code>.'
            ),
            prefix='xkeen',
        )
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise
    async def _handle_opt(self, q, ctx, key):
        if key in self._uninstall_opts:
            toggle_opt(self._uninstall_opts, key)
            state = 'вкл' if self._uninstall_opts[key] else 'выкл'
            await q.answer(f'{state}: {key}')
            await self._show_uninstall_menu(q, ctx)
            return

        if key == 'go':
            await q.answer()
            targets = existing_targets(UNINSTALL_TARGETS)
            base_cmd = ('xkeen -remove 2>&1 || true ; '
                        'opkg remove --force-removal-of-dependent-packages '
                        '--autoremove xkeen 2>&1 || true')
            cmd = collect_uninstall_cmd(targets, self._uninstall_opts, base_cmd)
            self._uninstall_opts = {}
            self._leftovers = []

            self._buf = b''
            self._last_edit = 0.0
            self._running = True
            self._last_action = 'uninstall'
            msg = await ctx.bot.send_message(
                chat_id=self.chat_id,
                text='\U0001f5d1 <b>Удаление XKeen</b>\n\n<pre>запуск...</pre>',
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton('\U0001f6d1 Отменить',
                                          callback_data='xkeen:kill')],
                ]),
            )
            self._status_msg_id = msg.message_id
            set_last_msg(self.chat_id, msg.message_id)

            pid, master = pty.fork()
            if pid == 0:
                try:
                    os.environ['TERM'] = 'dumb'
                    os.execv('/bin/sh', ['sh', '-c', cmd])
                except Exception:
                    os._exit(1)
            self._proc_pid = pid
            self._master = master
            asyncio.create_task(self._reader_loop(ctx, pid, master))
            return

        await q.answer()
    async def _start_action(self, q, ctx, key, action):
        if self._running:
            return
        self._running = True
        self._last_action = key
        self._buf = b''
        self._last_edit = 0.0
        self._awaiting_yn = False

        self._status_msg_id = await ui_edit_q(
            q,
            f'{action["icon"]} <b>{action["title"]}</b>\n\n<pre>запуск...</pre>',
            kb=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='xkeen:kill')],
            ]),
        )

        pid, master = pty.fork()
        if pid == 0:
            try:
                os.environ['TERM'] = 'dumb'
                os.environ['DEBIAN_FRONTEND'] = 'noninteractive'
                os.execv('/bin/sh', ['sh', '-c', action['cmd']])
            except Exception:
                os._exit(1)
        self._proc_pid = pid
        self._master = master
        asyncio.create_task(self._reader_loop(ctx, pid, master))

    def _drain_master(self, master):
        """Дочитывает остаток из pty после смерти процесса."""
        import select as _select
        try:
            while True:
                r, _, _ = _select.select([master], [], [], 0.3)
                if not r:
                    break
                try:
                    data = os.read(master, 4096)
                except (BlockingIOError, OSError):
                    break
                if not data:
                    break
                self._buf += data
        except Exception as e:
            log.debug('drain_master: %s', e)

    async def _reader_loop(self, ctx, pid, master):
        try:
            import fcntl
            fcntl.fcntl(master, fcntl.F_SETFL, os.O_NONBLOCK)
        except Exception as e:
            log.warning('nonblock set failed: %s', e)

        idle_start = time.time()
        start_time = time.time()
        timeout_total = 180
        try:
            while True:
                if time.time() - start_time > timeout_total:
                    log.warning('Timeout %ss, killing process', timeout_total)
                    try:
                        os.kill(pid, 9)
                    except Exception:
                        pass
                    self._buf += b'\n[!] Timeout: process killed\n'
                    break
                try:
                    wpid, _ws = os.waitpid(pid, os.WNOHANG)
                    if wpid == pid:
                        self._drain_master(master)
                        break
                except ChildProcessError:
                    self._drain_master(master)
                    break
                except Exception:
                    pass

                try:
                    data = os.read(master, 4096)
                    idle_start = time.time()
                except BlockingIOError:
                    if time.time() - idle_start > 2.0:
                        try:
                            wpid, _ws = os.waitpid(pid, os.WNOHANG)
                            if wpid == pid:
                                self._drain_master(master)
                                break
                        except Exception:
                            pass
                    await asyncio.sleep(0.15)
                    continue
                except OSError:
                    break
                if not data:
                    break
                self._buf += data
                if len(self._buf) > 60000:
                    self._buf = self._buf[-50000:]

                now = time.time()
                if now - self._last_edit >= 1.5:
                    self._last_edit = now
                    await self._update_status(ctx)

                if not self._awaiting_yn and _has_question(self._buf[-500:]):
                    await self._ask_question(ctx)
        finally:
            try:
                os.close(master)
            except Exception:
                pass
            self._master = None

        try:
            _, status = os.waitpid(pid, 0)
            rc = os.waitstatus_to_exitcode(status)
        except ChildProcessError:
            rc = 0
        except Exception:
            rc = -1
        self._proc_pid = None
        await self._finish(ctx, self._buf, rc)

    async def _update_status(self, ctx=None, bot=None):
        if bot is None and ctx is not None:
            bot = ctx.bot
        if bot is None or not self._status_msg_id:
            return
        text = _strip_ansi(self._buf.decode('utf-8', errors='replace'))
        tail = text[-1800:] if len(text) > 1800 else text
        if getattr(self, '_awaiting_yn', False):
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2705 Да (y)', callback_data='xkeen:ans:y'),
                 InlineKeyboardButton('\u274c Нет (n)', callback_data='xkeen:ans:n')],
                [InlineKeyboardButton('\u23ce Enter', callback_data='xkeen:ans:enter'),
                 InlineKeyboardButton('\U0001f6d1 Прервать', callback_data='xkeen:kill')],
            ])
        else:
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='xkeen:kill')],
            ])
        try:
            await bot.edit_message_text(
                chat_id=self.chat_id,
                message_id=self._status_msg_id,
                text=f'\u23f3 <b>Выполняется...</b>\n\n<pre>{_esc(tail)}</pre>',
                parse_mode='HTML',
                reply_markup=kb,
            )
        except Exception as e:
            if 'not modified' not in str(e).lower():
                log.debug('update_status: %s', e)
    async def _ask_question(self, ctx, buf=None):
        if self._awaiting_yn:
            return
        self._awaiting_yn = True
        await self._update_status(ctx)
    async def _finish(self, ctx, buf, rc):
        self._running = False
        self._awaiting_yn = False
        was_uninstall = (self._last_action == 'uninstall')
        was_cleanup = (self._last_action == 'cleanup')
        text = _strip_ansi(buf.decode('utf-8', errors='replace'))

        if rc == 0 and 'Collected errors' in text:
            new_lines, skip = [], False
            for ln in text.split('\n'):
                if 'Collected errors' in ln:
                    skip = True
                    continue
                if skip:
                    if ln.strip().startswith('*'):
                        if 'is not installed' in ln:
                            continue
                        new_lines.append(ln)
                        continue
                    else:
                        skip = False
                new_lines.append(ln)
            text = '\n'.join(new_lines).strip()

        offer_start = (
            self._last_action == 'install'
            and rc == 0
            and (get_service_status() != 'unknown')
            and not (get_service_status() == 'running')
        )
        self._last_action = None
        icon = '\u2705' if rc == 0 else '\u274c'

        if offer_start:
            header = (f'{icon} <b>Установка завершена</b>\n'
                      f'<i>exit code: {rc}</i>')
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u25b6\ufe0f Запустить сейчас',
                                      callback_data='xkeen:ask:start')],
                [InlineKeyboardButton('\u23ed Позже',
                                      callback_data='xkeen:main')],
            ])
        elif was_cleanup:
            header = f'{icon} <b>Остатки удалены</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                      callback_data='xkeen:main')],
            ])
        else:
            header = f'{icon} <b>Операция завершена</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                      callback_data='xkeen:main')],
            ])

        body = header
        if text.strip():
            tail = '\n'.join(text.strip().split('\n')[-20:])
            if len(tail) > 1800:
                tail = '\u2026' + tail[-1800:]
            body += f'\n\n<pre>{_esc(tail)}</pre>'
            body += '\n\n<i>Полный лог: /opt/var/log/router_bot.log</i>'

        if rc == 0 and was_uninstall:
            try:
                leftovers = scan_leftovers(SCAN_PATTERNS)
            except Exception:
                leftovers = []
            if leftovers:
                self._leftovers = leftovers
                body += f'\n\n\U0001f50d <b>Найдено {len(leftovers)} остатков.</b>'
                kb = InlineKeyboardMarkup([
                    [InlineKeyboardButton(
                        f'\U0001f5d1 Удалить все ({len(leftovers)})',
                        callback_data='xkeen:cleanup:all')],
                    [InlineKeyboardButton('\u2705 Оставить',
                                          callback_data='xkeen:main')],
                ])

        if self._status_msg_id:
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id,
                    message_id=self._status_msg_id,
                    text=body,
                    parse_mode='HTML',
                    reply_markup=kb,
                )
                self._status_msg_id = None
                return
            except Exception as e:
                log.debug('final edit failed: %s', e)
                self._status_msg_id = None

        msg = await ctx.bot.send_message(            chat_id=self.chat_id, text=body,
            parse_mode='HTML', reply_markup=kb,
        )

        set_last_msg(self.chat_id, msg.message_id)
RB_MODULES_XKEEN_MODULE_PY_EOF

echo "  → modules/xkeen/actions.py"
cat > /opt/router_bot/modules/xkeen/actions.py << 'RB_MODULES_XKEEN_ACTIONS_PY_EOF'
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
RB_MODULES_XKEEN_ACTIONS_PY_EOF

echo "  → modules/bird/__init__.py"
cat > /opt/router_bot/modules/bird/__init__.py << 'RB_MODULES_BIRD___INIT___PY_EOF'

RB_MODULES_BIRD___INIT___PY_EOF

echo "  → modules/bird/module.py"
cat > /opt/router_bot/modules/bird/module.py << 'RB_MODULES_BIRD_MODULE_PY_EOF'
"""Модуль BIRD — динамическая маршрутизация (BGP/OSPF)."""
import asyncio
import html
import logging
import os
import pty
import re
import time

from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import MessageHandler, filters, ContextTypes

from .actions import (
    ACTIONS, BIRD_CONF, is_installed, is_running, get_version,
    get_status_short, BIRDC_CONFIGURE,
    UNINSTALL_TARGETS, existing_targets,
    SCAN_PATTERNS,
)

from core.utils import (
    existing_targets, sync_opts, build_uninstall_menu,
    collect_uninstall_cmd, toggle_opt,
    scan_leftovers, build_leftovers_message,
    ui_edit_q, ui_edit_or_send,
    show_card,
    show_card,
    ui_edit_q,
)
from core.utils import set_last_msg

log = logging.getLogger(__name__)

MAX_MSG = 3500


def _esc(s: str) -> str:
    return html.escape(s or '')


def _strip_ansi(s: str) -> str:
    s = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', s)
    s = re.sub(r'\x1b\][^\x07]*\x07', '', s)
    s = re.sub(r'\x1b[=>]', '', s)
    return s


def _split(text, size=MAX_MSG):
    if not text:
        return ['']
    chunks, cur = [], ''
    for line in text.splitlines(keepends=True):
        if len(cur) + len(line) > size:
            if cur:
                chunks.append(cur)
            cur = line
            while len(cur) > size:
                chunks.append(cur[:size])
                cur = cur[size:]
        else:
            cur += line
    if cur:
        chunks.append(cur)
    return chunks


class BirdModule:
    name = 'bird'
    title = 'BIRD'
    icon = '\U0001f426'  # 🐦
    description = 'динамическая маршрутизация (BGP/OSPF)'
    category = 'services'
    category_title = 'Сервис'
    category_icon = '\U0001f6e0'
    conflicts_with = {
        'hydraroute': 'оба меняют системные маршруты через ndmc/iptables',
        'xkeen': 'оба меняют системные маршруты через ndmc/iptables',
    }
    commands = [('bd', '🐦 BIRD')]
    cleanup_paths = [
        '/opt/sbin/bird',
        '/opt/sbin/birdc',
        '/opt/bin/bird',
        '/opt/bin/birdc',
        '/opt/etc/bird.conf',
        '/opt/etc/bird.conf.bak',
        '/opt/var/log/bird*',
        '/opt/var/run/bird*',
    ]
    cleanup_init = ['S70bird']

    def __init__(self, chat_id):
        self.chat_id = str(chat_id)
        self._proc_pid = None
        self._master = None
        self._running = False
        self._status_msg_id = None
        self._buf = b''
        self._last_edit = 0.0
        self._editing = False
        self._edit_msg_id = None
        self._uninstall_opts = {}  # динамически заполняется из existing_targets()
        self._leftovers = []
        self._last_action = None

    async def startup(self, app):
        app.add_handler(MessageHandler(
            filters.TEXT & ~filters.COMMAND,
            self._handle_text,
        ))
        log.info('BIRD module started')

    async def on_leave(self):
        self._kill()
        self._editing = False

    def _kill(self):
        import signal
        pid = getattr(self, '_proc_pid', None)
        if pid:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(os.getpgid(pid), sig)
                except ProcessLookupError:
                    break
                except Exception:
                    try:
                        os.kill(pid, sig)
                    except Exception:
                        pass
                time.sleep(0.4)
            try:
                os.waitpid(pid, os.WNOHANG)
            except Exception:
                pass
            self._proc_pid = None
        if self._master is not None:
            try:
                os.close(self._master)
            except Exception:
                pass
            self._master = None
        self._running = False

    # ================= статус =================

    def get_installed(self) -> bool:
        return is_installed()

    def get_status_short(self) -> str:
        return get_status_short()

    # ================= UI =================

    def _build_card(self):
        installed = is_installed()
        running = is_running()
        version = get_version() if installed else ''

        lines = [f'{self.icon} <b>{self.title}</b>', '']
        if installed:
            v = f' · <code>{version}</code>' if version else ''
            lines.append(f'✅ Установлен{v}')
            lines.append('Сервис: ' + ('🟢 работает' if running else '🔴 остановлен'))
        else:
            lines.append('❌ Не установлен')
        lines.append('')

        if self._running:
            lines.append('⏳ <b>Выполняется операция...</b>')
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить', callback_data='bird:kill')],
                [
                    InlineKeyboardButton('\u2b05\ufe0f Назад', callback_data='router:cat:services'),
                    InlineKeyboardButton('\U0001f3e0 Модули', callback_data='router:main'),
                ],
            ])
            return '\n'.join(lines), kb

        rows = []
        # Предупреждения о конфликтах
        if not installed:
            import subprocess as _sp
            def _proc_running(pname):
                try:
                    _r = _sp.run(['sh', '-c', f'ps w | grep -q "[{pname[0]}]{pname[1:]}" && echo yes'], capture_output=True, text=True, timeout=3)
                    return 'yes' in (_r.stdout or '')
                except Exception: return False
            if _proc_running('hrneo'):
                lines.append('\u26a0\ufe0f <b>Конфликт с HydraRoute</b>')
                lines.append('<i>Оба меняют системные маршруты через ndmc/iptables.</i>')
                lines.append('')
            if _proc_running('xkeen'):
                lines.append('\u26a0\ufe0f <b>Конфликт с XKeen</b>')
                lines.append('<i>Оба меняют системные маршруты через ndmc/iptables.</i>')
                lines.append('')

        if not installed:
            rows.append([InlineKeyboardButton(
                '\u2b07\ufe0f Установить BIRD',
                callback_data='bird:ask:install')])
        else:
            if running:
                rows.append([InlineKeyboardButton(
                    '\u23f9 Остановить', callback_data='bird:ask:stop')])
                rows.append([InlineKeyboardButton(
                    '\U0001f504 Перезапустить', callback_data='bird:ask:restart')])
            else:
                rows.append([InlineKeyboardButton(
                    '\u25b6\ufe0f Запустить', callback_data='bird:ask:start')])
            rows.append([InlineKeyboardButton(
                '📄 Перечитать конфиг', callback_data='bird:ask:reload_conf')])
            rows.append([
                InlineKeyboardButton('\U0001f4ca Статус', callback_data='bird:ask:show_status'),
                InlineKeyboardButton('\U0001f517 Протоколы', callback_data='bird:ask:show_protocols'),
            ])
            rows.append([
                InlineKeyboardButton('\U0001f5fa Маршруты', callback_data='bird:ask:show_routes'),
                InlineKeyboardButton('\U0001f4e1 Интерфейсы', callback_data='bird:ask:show_interfaces'),
            ])
            rows.append([
                InlineKeyboardButton('\U0001f523 Символы', callback_data='bird:ask:show_symbols'),
                InlineKeyboardButton('\U0001f4cc Статические', callback_data='bird:ask:show_static'),
            ])
            rows.append([
                InlineKeyboardButton('\U0001f4e1 BFD-сессии', callback_data='bird:ask:show_bfd'),
            ])
            rows.append([
                InlineKeyboardButton('\u2705 Вкл. все', callback_data='bird:ask:enable_all'),
                InlineKeyboardButton('\u274c Откл. все', callback_data='bird:ask:disable_all'),
            ])
            rows.append([InlineKeyboardButton(
                '✏️ Редактировать конфиг', callback_data='bird:edit_config')])
            rows.append([InlineKeyboardButton(
                '\U0001f5d1 Удалить BIRD', callback_data='bird:ask:uninstall')])
        rows.append([InlineKeyboardButton(
            '\U0001f504 Обновить карточку', callback_data='bird:main')])
        rows.append([
            InlineKeyboardButton('\u2b05\ufe0f Назад', callback_data='router:cat:services'),
            InlineKeyboardButton('\U0001f3e0 Модули', callback_data='router:main'),
        ])
        return '\n'.join(lines), InlineKeyboardMarkup(rows)

    async def send_card_message(self, update, ctx):
        text, kb = self._build_card()
        await show_card(update, ctx, text, kb=kb)

    async def handle_callback(self, action, q, ctx):
        if action == 'main':
            await q.answer()
            self._editing = False
            text, kb = self._build_card()
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower():
                    raise
            return

        if action == 'kill':
            await q.answer('Прерываю...')
            self._kill()
            try:
                await q.edit_message_text(
                    '\U0001f6d1 Операция прервана.',
                    reply_markup=InlineKeyboardMarkup([
                        [InlineKeyboardButton('\u2b05\ufe0f Назад', callback_data='bird:main')],
                    ]),
                )
            except Exception:
                pass
            return

        if action == 'edit_config':
            await q.answer()
            await self._show_config(q, ctx)
            return

        if action == 'cleanup:all':
            await q.answer()
            return await self._do_cleanup(q, ctx)

        if action == 'ask:uninstall':
            await q.answer()
            return await self._show_uninstall_menu(q, ctx)

        if action.startswith('opt:'):
            return await self._handle_opt(q, ctx, action[4:])

        if action.startswith('ask:'):
            key = action[4:]
            await q.answer()
            a = ACTIONS.get(key)
            if not a:
                await q.answer('Неизвестное действие', show_alert=True)
                return
            desc = a['desc']
            text = (
                f'{a["icon"]} <b>{a["title"]}</b>\n\n'
                f'{desc}\n\n'
                f'Подтвердить?'
            )
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2705 Подтвердить',
                                      callback_data=f'bird:go:{key}')],
                [InlineKeyboardButton('\u274c Отмена',
                                      callback_data='bird:main')],
            ])
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower():
                    raise
            return

        if action.startswith('go:'):
            key = action[3:]
            await q.answer()
            a = ACTIONS.get(key)
            if not a:
                return
            await self._start_action(q, ctx, key, a)
            return

        await q.answer()

    def _drain_master(self, master):
        """Дочитывает все доступные данные из pty перед закрытием."""
        import select as _select
        try:
            while True:
                r, _, _ = _select.select([master], [], [], 0.3)
                if not r:
                    break
                try:
                    data = os.read(master, 4096)
                except (BlockingIOError, OSError):
                    break
                if not data:
                    break
                self._buf += data
        except Exception as e:
            log.debug('drain_master: %s', e)

    # ================= удаление остатков =================

    async def _check_leftovers(self, ctx):
        """Сканирует систему и, если что-то осталось, предлагает удалить."""
        try:
            leftovers = scan_leftovers(SCAN_PATTERNS)
        except Exception as e:
            log.debug('scan_leftovers failed: %s', e)
            return
        if not leftovers:
            return
        self._leftovers = leftovers
        text, kb = build_leftovers_message(leftovers, prefix='bird')
        try:
            await ctx.bot.send_message(
                chat_id=self.chat_id,
                text=text,
                parse_mode='HTML',
                reply_markup=kb,
            )
        except Exception as e:
            log.warning('send leftovers failed: %s', e)

    async def _do_cleanup(self, q, ctx):
        if not getattr(self, '_leftovers', None):
            await q.answer('Нечего удалять', show_alert=True)
            return
        # Формируем rm-команду с echo для наглядности
        parts = []
        total = len(self._leftovers)
        for p in self._leftovers:
            safe = p.replace("'", "'\\''")
            parts.append(f"echo 'Удаляю: {safe}' ; rm -rf '{safe}'")
        parts.append(f"echo '' ; echo 'Готово: удалено {total} элементов'")
        cmd = ' ; '.join(parts)
        self._leftovers = []

        self._buf = b''
        self._last_edit = 0.0
        self._running = True
        self._last_action = 'cleanup'
        self._status_msg_id = await ui_edit_q(
                q,
                '\U0001f5d1 <b>Удаляю остатки...</b>\n\n<pre>запуск...</pre>',
                kb=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='bird:kill')],
            ]),
            )

        pid, master = pty.fork()
        if pid == 0:
            try:
                os.environ['TERM'] = 'dumb'
                os.execv('/bin/sh', ['sh', '-c', cmd])
            except Exception:
                os._exit(1)
        self._proc_pid = pid
        self._master = master
        asyncio.create_task(self._reader_loop(ctx, pid, master))

    # ================= меню удаления =================

    async def _show_uninstall_menu(self, q, ctx):
        targets = existing_targets(UNINSTALL_TARGETS)
        self._uninstall_opts = sync_opts(targets, self._uninstall_opts)

        text, kb = build_uninstall_menu(
            targets,
            self._uninstall_opts,
            title='Удаление BIRD',
            always_msg='Пакет <code>bird2 bird2c</code> удаляется всегда.',
            prefix='bird',
        )
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise
    async def _handle_opt(self, q, ctx, key):
        # Переключение чекбокса
        if key in self._uninstall_opts:
            toggle_opt(self._uninstall_opts, key)
            state = 'вкл' if self._uninstall_opts[key] else 'выкл'
            await q.answer(f'{state}: {key}')
            await self._show_uninstall_menu(q, ctx)
            return

        if key == 'go':
            await q.answer()
            targets = existing_targets(UNINSTALL_TARGETS)
            base_cmd = ('opkg remove --force-removal-of-dependent-packages '
                        '--autoremove bird2c bird2 2>&1 || true')
            cmd = collect_uninstall_cmd(targets, self._uninstall_opts, base_cmd)
            self._uninstall_opts = {}

            self._buf = b''
            self._last_edit = 0.0
            self._running = True
            self._last_action = 'uninstall'
            self._status_msg_id = await ui_edit_q(
                q,
                '\U0001f5d1 <b>Удаление BIRD</b>\n\n<pre>запуск...</pre>',
                kb=InlineKeyboardMarkup([
                    [InlineKeyboardButton('\U0001f6d1 Отменить',
                                          callback_data='bird:kill')],
                ]),
            )

            pid, master = pty.fork()
            if pid == 0:
                try:
                    os.environ['TERM'] = 'dumb'
                    os.execv('/bin/sh', ['sh', '-c', cmd])
                except Exception:
                    os._exit(1)
            self._proc_pid = pid
            self._master = master
            asyncio.create_task(self._reader_loop(ctx, pid, master))
            return

        await q.answer()
    async def _show_config(self, q, ctx):
        """Показывает текущий конфиг и даёт кнопку «Прислать новый»."""
        try:
            if os.path.exists(BIRD_CONF):
                with open(BIRD_CONF) as f:
                    content = f.read()
            else:
                content = '(файл /opt/etc/bird.conf не найден)'
        except Exception as e:
            content = f'(ошибка чтения: {e})'

        if len(content) > 3000:
            content = content[:3000] + '\n... (сокращено)'

        text = (
            f'\U0001f4c4 <b>Конфиг BIRD</b> — <code>{BIRD_CONF}</code>\n\n'
            f'<pre>{_esc(content)}</pre>'
        )
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('\u270f\ufe0f Прислать новый конфиг',
                                  callback_data='bird:edit_new')],
            [InlineKeyboardButton('\u2b05\ufe0f Назад', callback_data='bird:main')],
        ])
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise

    async def _ask_new_config(self, q, ctx):
        self._editing = True
        text = (
            '\u270f\ufe0f <b>Пришлите новый конфиг BIRD</b>\n\n'
            'Следующим сообщением отправьте полный текст файла '
            '<code>/opt/etc/bird.conf</code>.\n\n'
            '⚠️ Перед записью текущий конфиг будет сохранён в '
            '<code>bird.conf.bak</code>.\n'
            'После записи конфиг не применяется автоматически — '
            'нужно будет нажать «Перечитать конфиг».'
        )
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('\u274c Отмена', callback_data='bird:main')],
        ])
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise

    async def _handle_text(self, update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        if str(update.effective_chat.id) != self.chat_id:
            return
        if not self._editing:
            return

        text = update.message.text or ''
        if not text.strip():
            return

        # Сохраняем бэкап
        try:
            if os.path.exists(BIRD_CONF):
                import shutil
                shutil.copy(BIRD_CONF, BIRD_CONF + '.bak')
            with open(BIRD_CONF, 'w') as f:
                f.write(text)
            self._editing = False
            await update.message.reply_text(
                f'✅ Конфиг сохранён в <code>{BIRD_CONF}</code>\n'
                f'Резервная копия: <code>{BIRD_CONF}.bak</code>\n\n'
                f'Примените через «Перечитать конфиг» в карточке BIRD.',
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton('\U0001f4c4 Перечитать',
                                          callback_data='bird:ask:reload_conf')],
                    [InlineKeyboardButton('\u2b05\ufe0f Назад', callback_data='bird:main')],
                ]),
            )
        except Exception as e:
            self._editing = False
            log.exception('save bird config failed: %s', e)
            await update.message.reply_text(f'❌ Не удалось сохранить: {e}')

    # ================= запуск операций =================

    async def _start_action(self, q, ctx, key, action):
        if self._running:
            return
        self._running = True
        self._last_action = key
        self._buf = b''
        self._last_edit = 0.0
        self._awaiting_yn = False

        self._status_msg_id = await ui_edit_q(
            q,
            f'{action["icon"]} <b>{action["title"]}</b>\n\n<pre>запуск...</pre>',
            kb=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='bird:kill')],
            ]),
        )

        pid, master = pty.fork()
        if pid == 0:
            try:
                os.environ['TERM'] = 'dumb'
                os.environ['DEBIAN_FRONTEND'] = 'noninteractive'
                os.execv('/bin/sh', ['sh', '-c', action['cmd']])
            except Exception:
                os._exit(1)
        self._proc_pid = pid
        self._master = master
        asyncio.create_task(self._reader_loop(ctx, pid, master))

    async def _reader_loop(self, ctx, pid, master):
        try:
            import fcntl
            fcntl.fcntl(master, fcntl.F_SETFL, os.O_NONBLOCK)
        except Exception as e:
            log.warning('nonblock failed: %s', e)

        idle_start = time.time()
        proc_exited = False
        try:
            while True:
                # Проверяем, жив ли ещё дочерний процесс
                try:
                    wpid, wstatus = os.waitpid(pid, os.WNOHANG)
                    if wpid == pid:
                        # Процесс мёртв — дочитываем остаток из master
                        self._drain_master(master)
                        proc_exited = True
                        break
                except ChildProcessError:
                    self._drain_master(master)
                    proc_exited = True
                    break
                except Exception:
                    pass

                try:
                    data = os.read(master, 4096)
                    idle_start = time.time()
                except BlockingIOError:
                    # Если процесс завершён и нет данных 1 сек — выходим
                    if time.time() - idle_start > 2.0:
                        # ещё раз проверим процесс
                        try:
                            wpid, wstatus = os.waitpid(pid, os.WNOHANG)
                            if wpid == pid:
                                proc_exited = True
                                break
                        except Exception:
                            pass
                    await asyncio.sleep(0.15)
                    continue
                except OSError:
                    break
                if not data:
                    break
                self._buf += data
                if len(self._buf) > 60000:
                    self._buf = self._buf[-50000:]
                now = time.time()
                if now - self._last_edit >= 1.2:
                    self._last_edit = now
                    await self._update_status(ctx)
        finally:
            try:
                os.close(master)
            except Exception:
                pass
            self._master = None

        try:
            _, status = os.waitpid(pid, 0)
            rc = os.waitstatus_to_exitcode(status)
        except ChildProcessError:
            # уже забрали статус раньше
            rc = 0
        except Exception:
            rc = -1
        self._proc_pid = None
        await self._finish(ctx, self._buf, rc)

    async def _update_status(self, ctx=None, bot=None):
        if bot is None and ctx is not None:
            bot = ctx.bot
        if bot is None or not self._status_msg_id:
            return
        text = _strip_ansi(self._buf.decode('utf-8', errors='replace'))
        tail = text[-1800:] if len(text) > 1800 else text
        if getattr(self, '_awaiting_yn', False):
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2705 Да (y)', callback_data='bird:ans:y'),
                 InlineKeyboardButton('\u274c Нет (n)', callback_data='bird:ans:n')],
                [InlineKeyboardButton('\u23ce Enter', callback_data='bird:ans:enter'),
                 InlineKeyboardButton('\U0001f6d1 Прервать', callback_data='bird:kill')],
            ])
        else:
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='bird:kill')],
            ])
        try:
            await bot.edit_message_text(
                chat_id=self.chat_id,
                message_id=self._status_msg_id,
                text=f'\u23f3 <b>Выполняется...</b>\n\n<pre>{_esc(tail)}</pre>',
                parse_mode='HTML',
                reply_markup=kb,
            )
        except Exception as e:
            if 'not modified' not in str(e).lower():
                log.debug('update_status: %s', e)

    async def _finish(self, ctx, buf, rc):
        self._running = False
        self._awaiting_yn = False
        was_uninstall = (self._last_action == 'uninstall')
        was_cleanup = (self._last_action == 'cleanup')
        text = _strip_ansi(buf.decode('utf-8', errors='replace'))

        if rc == 0 and 'Collected errors' in text:
            new_lines, skip = [], False
            for ln in text.split('\n'):
                if 'Collected errors' in ln:
                    skip = True
                    continue
                if skip:
                    if ln.strip().startswith('*'):
                        if 'is not installed' in ln:
                            continue
                        new_lines.append(ln)
                        continue
                    else:
                        skip = False
                new_lines.append(ln)
            text = '\n'.join(new_lines).strip()

        offer_start = (
            self._last_action == 'install'
            and rc == 0
            and (is_installed())
            and not (is_running())
        )
        self._last_action = None
        icon = '\u2705' if rc == 0 else '\u274c'

        if offer_start:
            header = (f'{icon} <b>Установка завершена</b>\n'
                      f'<i>exit code: {rc}</i>')
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u25b6\ufe0f Запустить сейчас',
                                      callback_data='bird:ask:start')],
                [InlineKeyboardButton('\u23ed Позже',
                                      callback_data='bird:main')],
            ])
        elif was_cleanup:
            header = f'{icon} <b>Остатки удалены</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                      callback_data='bird:main')],
            ])
        else:
            header = f'{icon} <b>Операция завершена</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                      callback_data='bird:main')],
            ])

        body = header
        if text.strip():
            tail = '\n'.join(text.strip().split('\n')[-20:])
            if len(tail) > 1800:
                tail = '\u2026' + tail[-1800:]
            body += f'\n\n<pre>{_esc(tail)}</pre>'
            body += '\n\n<i>Полный лог: /opt/var/log/router_bot.log</i>'

        if rc == 0 and was_uninstall:
            try:
                leftovers = scan_leftovers(SCAN_PATTERNS)
            except Exception:
                leftovers = []
            if leftovers:
                self._leftovers = leftovers
                body += f'\n\n\U0001f50d <b>Найдено {len(leftovers)} остатков.</b>'
                kb = InlineKeyboardMarkup([
                    [InlineKeyboardButton(
                        f'\U0001f5d1 Удалить все ({len(leftovers)})',
                        callback_data='bird:cleanup:all')],
                    [InlineKeyboardButton('\u2705 Оставить',
                                          callback_data='bird:main')],
                ])

        if self._status_msg_id:
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id,
                    message_id=self._status_msg_id,
                    text=body,
                    parse_mode='HTML',
                    reply_markup=kb,
                )
                self._status_msg_id = None
                return
            except Exception as e:
                log.debug('final edit failed: %s', e)
                self._status_msg_id = None

        msg = await ctx.bot.send_message(            chat_id=self.chat_id, text=body,
            parse_mode='HTML', reply_markup=kb,
        )

        set_last_msg(self.chat_id, msg.message_id)

    async def _ask_question(self, ctx, buf=None):
        if self._awaiting_yn:
            return
        self._awaiting_yn = True
        await self._update_status(ctx)

    async def _answer(self, q, payload: bytes):
        if not getattr(self, '_proc_pid', None) or self._master is None:
            await q.answer('Сессия завершена', show_alert=False)
            return
        try:
            os.write(self._master, payload)
            await q.answer(
                f'Отправлено: {payload.decode(errors="replace").strip() or "Enter"}',
            )
        except OSError as e:
            log.warning('write failed: %s', e)
            await q.answer(f'Ошибка: {e}', show_alert=True)
            return
        self._awaiting_yn = False
        await self._update_status(bot=q.bot)
RB_MODULES_BIRD_MODULE_PY_EOF

echo "  → modules/bird/actions.py"
cat > /opt/router_bot/modules/bird/actions.py << 'RB_MODULES_BIRD_ACTIONS_PY_EOF'
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
RB_MODULES_BIRD_ACTIONS_PY_EOF

echo "  → modules/mtproxy/__init__.py"
cat > /opt/router_bot/modules/mtproxy/__init__.py << 'RB_MODULES_MTPROXY___INIT___PY_EOF'

RB_MODULES_MTPROXY___INIT___PY_EOF

echo "  → modules/mtproxy/module.py"
cat > /opt/router_bot/modules/mtproxy/module.py << 'RB_MODULES_MTPROXY_MODULE_PY_EOF'
"""Модуль MTProxy — MTProto-прокси для Telegram."""
import asyncio
import html
import logging
import os
import pty
import re
import time

from telegram import (
    InlineKeyboardButton, InlineKeyboardMarkup, Update,
)
from telegram.ext import MessageHandler, filters, ContextTypes

from .actions import (
    is_broken,
    ACTIONS, UNINSTALL_CMD, UNINSTALL_TARGETS, SCAN_PATTERNS,
    PROXY_CONF, PROXY_SECRET,
    is_installed, is_running, get_version, get_status_short,
    get_link, get_secret, get_config,
    build_tg_link, get_external_host,
)
from core.utils import (
    existing_targets, sync_opts, build_uninstall_menu,
    collect_uninstall_cmd, toggle_opt,
    scan_leftovers, build_leftovers_message,
    ui_edit_q, ui_edit_or_send,
    show_card,
    show_card,
    ui_edit_q,
)
from core.utils import set_last_msg

log = logging.getLogger(__name__)

MAX_MSG = 3500


def _esc(s: str) -> str:
    return html.escape(s or '')


def _strip_ansi(s: str) -> str:
    s = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', s)
    s = re.sub(r'\x1b\][^\x07]*\x07', '', s)
    s = re.sub(r'\x1b[=>]', '', s)
    return s


def _split(text, size=MAX_MSG):
    if not text:
        return ['']
    chunks, cur = [], ''
    for line in text.splitlines(keepends=True):
        if len(cur) + len(line) > size:
            if cur:
                chunks.append(cur)
            cur = line
            while len(cur) > size:
                chunks.append(cur[:size])
                cur = cur[size:]
        else:
            cur += line
    if cur:
        chunks.append(cur)
    return chunks


class MTProxyModule:
    name = 'mtproxy'
    title = 'MTProxy'
    icon = '\U0001f310'  # 🌐
    description = 'MTProto-прокси для Telegram'
    category = 'services'
    category_title = 'Сервис'
    category_icon = '\U0001f6e0'
    conflicts_with = {}
    commands = [('mt', '🌐 MTProxy')]
    cleanup_paths = [
        '/opt/bin/tg-ws-proxy',
        '/opt/sbin/tg-ws-proxy',
        '/opt/etc/tg-ws-proxy',
        '/opt/var/log/tg-ws-proxy.log',
        '/opt/var/run/tg-ws-proxy*',
    ]
    cleanup_init = ['S99tg-ws-proxy']

    def __init__(self, chat_id):
        self.chat_id = str(chat_id)
        self._proc_pid = None
        self._master = None
        self._running = False
        self._status_msg_id = None
        self._buf = b''
        self._last_edit = 0.0
        self._last_action = None
        self._uninstall_opts = {}
        self._leftovers = []
        self._editing = False

    async def startup(self, app):
        app.add_handler(MessageHandler(
            filters.TEXT & ~filters.COMMAND,
            self._handle_text,
        ))
        log.info('MTProxy module started')

    async def on_leave(self):
        self._kill()
        self._editing = False

    def _kill(self):
        import signal
        pid = getattr(self, '_proc_pid', None)
        if pid:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(os.getpgid(pid), sig)
                except ProcessLookupError:
                    break
                except Exception:
                    try:
                        os.kill(pid, sig)
                    except Exception:
                        pass
                time.sleep(0.4)
            try:
                os.waitpid(pid, os.WNOHANG)
            except Exception:
                pass
            self._proc_pid = None
        if self._master is not None:
            try:
                os.close(self._master)
            except Exception:
                pass
            self._master = None
        self._running = False

    # ================= статус =================

    def get_installed(self) -> bool:
        return is_installed()

    def get_status_short(self) -> str:
        return get_status_short()

    def _get_full_link(self) -> str:
        """Возвращает готовую tg:// ссылку — из лога, либо собирает из конфига."""
        link = get_link()
        if link:
            return link
        # собираем вручную
        secret = get_secret()
        if not secret:
            return ''
        cfg = get_config()
        port = cfg.get('PORT', '')
        host = cfg.get('HOST', '')
        # если HOST локальный — берём внешний IP
        if not host or host in ('0.0.0.0', '127.0.0.1', 'localhost'):
            host = get_external_host()
        if not host or not port:
            return ''
        return build_tg_link(host=host, port=port, secret=secret)

    # ================= UI =================

    def _build_card(self):
        installed = is_installed()
        running = is_running()
        broken = is_broken()
        version = get_version() if installed else ''

        lines = [f'{self.icon} <b>{self.title}</b>', '']
    
        if broken:
            lines.append('⚠️ <b>Установка повреждена</b>')
            lines.append('<i>Пакет есть в opkg, но файлы отсутствуют.</i>')
            lines.append('')
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('🔧 Переустановить',
                                      callback_data='mtproxy:ask:reinstall')],
                [InlineKeyboardButton('🗑 Удалить и почистить',
                                      callback_data='mtproxy:ask:uninstall')],
                [InlineKeyboardButton('⬅️ Назад', callback_data='router:cat:services'),
                 InlineKeyboardButton('🏠 Модули', callback_data='router:main')],
            ])
            return '\n'.join(lines), kb

        if installed:
            v = f' · <code>{version}</code>' if version else ''
            lines.append(f'✅ Установлен{v}')
            lines.append('Сервис: ' + ('🟢 работает' if running else '🔴 остановлен'))
            cfg = get_config()
            if cfg:
                port = cfg.get('PORT', '?')
                host = cfg.get('HOST', '')
                if host and host not in ('0.0.0.0', '::', '127.0.0.1', 'localhost'):
                    lines.append(f'Хост: <code>{_esc(host)}</code>')
                lines.append(f'Порт: <code>{port}</code>')
            secret = get_secret()
            if secret:
                lines.append(f'Секрет: <code>{secret[:8]}…</code>')
        else:
            lines.append('❌ Не установлен')
        lines.append('')

        if self._running:
            lines.append('⏳ <b>Выполняется операция...</b>')
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить', callback_data='mtproxy:kill')],
                [InlineKeyboardButton('\u2b05\ufe0f Назад', callback_data='router:cat:services'),
                 InlineKeyboardButton('\U0001f3e0 Модули', callback_data='router:main')],
            ])
            return '\n'.join(lines), kb

        rows = []
        if not installed:
            rows.append([InlineKeyboardButton(
                '\u2b07\ufe0f Установить MTProxy',
                callback_data='mtproxy:ask:install')])
        else:
            if running:
                rows.append([InlineKeyboardButton(
                    '\u23f9 Остановить', callback_data='mtproxy:ask:stop')])
                rows.append([InlineKeyboardButton(
                    '\U0001f504 Перезапустить', callback_data='mtproxy:ask:restart')])
            else:
                rows.append([InlineKeyboardButton(
                    '\u25b6\ufe0f Запустить', callback_data='mtproxy:ask:start')])
            rows.append([InlineKeyboardButton(
                '\U0001f4ca Статус', callback_data='mtproxy:ask:status')])
            rows.append([InlineKeyboardButton(
                '\U0001f517 Показать ссылку', callback_data='mtproxy:show_link')])
            rows.append([InlineKeyboardButton(
                '✏️ Редактировать конфиг', callback_data='mtproxy:edit_config')])
            rows.append([InlineKeyboardButton(
                '\U0001f5d1 Удалить MTProxy', callback_data='mtproxy:ask:uninstall')])
    
        rows.append([InlineKeyboardButton(
            '\U0001f504 Обновить карточку', callback_data='mtproxy:main')])
        rows.append([
            InlineKeyboardButton('\u2b05\ufe0f Назад', callback_data='router:cat:services'),
            InlineKeyboardButton('\U0001f3e0 Модули', callback_data='router:main'),
        ])
        return '\n'.join(lines), InlineKeyboardMarkup(rows)

    async def send_card_message(self, update, ctx):
        text, kb = self._build_card()
        await show_card(update, ctx, text, kb=kb)

    async def handle_callback(self, action, q, ctx):
        if action == 'main':
            await q.answer()
            self._editing = False
            text, kb = self._build_card()
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower():
                    raise
            return

        if action == 'kill':
            await q.answer('Прерываю...')
            self._kill()
            try:
                await q.edit_message_text(
                    '\U0001f6d1 Операция прервана.',
                    reply_markup=InlineKeyboardMarkup([
                        [InlineKeyboardButton('\u2b05\ufe0f Назад', callback_data='mtproxy:main')],
                    ]),
                )
            except Exception:
                pass
            return

        if action == 'cleanup:all':
            await q.answer()
            return await self._do_cleanup(q, ctx)

        if action == 'noop':
            await q.answer('✅ Ссылка скопирована')
            return

        if action == 'show_link':
            await q.answer()
            return await self._show_link(q, ctx)

        if action == 'edit_config':
            await q.answer()
            await self._show_config(q, ctx)
            return

        if action == 'ask:uninstall':
            await q.answer()
            return await self._show_uninstall_menu(q, ctx)

        if action.startswith('opt:'):
            return await self._handle_opt(q, ctx, action[4:])

        if action.startswith('ask:'):
            key = action[4:]
            await q.answer()
            a = ACTIONS.get(key)
            if not a:
                await q.answer('Неизвестное действие', show_alert=True)
                return
            text = (
                f'{a["icon"]} <b>{a["title"]}</b>\n\n'
                f'{a["desc"]}\n\n'
                f'Подтвердить?'
            )
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2705 Подтвердить',
                                      callback_data=f'mtproxy:go:{key}')],
                [InlineKeyboardButton('\u274c Отмена',
                                      callback_data='mtproxy:main')],
            ])
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower():
                    raise
            return

        if action.startswith('go:'):
            key = action[3:]
            await q.answer()
            a = ACTIONS.get(key)
            if not a:
                return
            await self._start_action(q, ctx, key, a)
            return

        await q.answer()

    # ================= ссылка =================

    async def _show_link(self, q, ctx):
        link = await asyncio.to_thread(self._get_full_link)
        secret = get_secret()
        cfg = get_config()
        port = cfg.get('PORT', '?')
        host = cfg.get('HOST', '0.0.0.0')

        if link:
            lines = [
                '\U0001f517 <b>Ссылка для подключения</b>',
                '',
                f'<code>{_esc(link)}</code>',
                '',
                '<i>Нажмите на ссылку — она скопируется в буфер обмена. '
                'Затем откройте её в Telegram.</i>',
            ]
            rows = []
            # Кнопка «Скопировать ссылку» (Bot API 7.11+, PTB 21.10+)
            try:
                rows.append([InlineKeyboardButton(
                    '\U0001f4cb Скопировать ссылку',
                    callback_data='mtproxy:noop',
                    copy_text=link,
                )])
            except TypeError:
                pass
            rows.append([InlineKeyboardButton(
                '\u2b05\ufe0f Назад', callback_data='mtproxy:main')])
            kb = InlineKeyboardMarkup(rows)
        elif secret:
            lines = [
                '\U0001f517 <b>Данные подключения</b>',
                '',
                f'Хост: <code>{_esc(host)}</code>',
                f'Порт: <code>{port}</code>',
                f'Секрет: <code>{_esc(secret)}</code>',
                '',
                '<i>Готовая ссылка недоступна — прокси не запущен '
                'или внешний IP не определён. Запустите прокси и '
                'откройте раздел снова.</i>',
            ]
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f504 Обновить',
                                      callback_data='mtproxy:show_link')],
                [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                      callback_data='mtproxy:main')],
            ])
        else:
            lines = [
                '\U0001f517 <b>Данные подключения</b>',
                '',
                '<i>Прокси не запущен или секрет не сгенерирован.</i>',
            ]
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                      callback_data='mtproxy:main')],
            ])

        text = '\n'.join(lines)
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise
    async def _show_config(self, q, ctx):
        try:
            if os.path.exists(PROXY_CONF):
                with open(PROXY_CONF) as f:
                    content = f.read()
            else:
                content = '(файл config.conf не найден)'
        except Exception as e:
            content = f'(ошибка чтения: {e})'

        if len(content) > 3000:
            content = content[:3000] + '\n... (сокращено)'

        text = (
            f'\u2699\ufe0f <b>Конфиг MTProxy</b>\n'
            f'<code>{PROXY_CONF}</code>\n\n'
            f'<pre>{_esc(content)}</pre>'
        )
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('\u270f\ufe0f Прислать новый конфиг',
                                  callback_data='mtproxy:edit_new')],
            [InlineKeyboardButton('\u2b05\ufe0f Назад', callback_data='mtproxy:main')],
        ])
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise

    async def _ask_new_config(self, q, ctx):
        self._editing = True
        text = (
            '\u270f\ufe0f <b>Пришлите новый конфиг</b>\n\n'
            'Следующим сообщением отправьте полный текст файла\n'
            f'<code>{PROXY_CONF}</code>.\n\n'
            '⚠️ Текущий конфиг будет сохранён в <code>config.conf.bak</code>.\n'
            'После записи перезапустите прокси для применения.'
        )
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('\u274c Отмена', callback_data='mtproxy:main')],
        ])
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise

    async def _handle_text(self, update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        if str(update.effective_chat.id) != self.chat_id:
            return
        if not self._editing:
            return
        text = update.message.text or ''
        if not text.strip():
            return
        try:
            if os.path.exists(PROXY_CONF):
                import shutil
                shutil.copy(PROXY_CONF, PROXY_CONF + '.bak')
            os.makedirs(os.path.dirname(PROXY_CONF), exist_ok=True)
            with open(PROXY_CONF, 'w') as f:
                f.write(text)
            self._editing = False
            await update.message.reply_text(
                f'✅ Конфиг сохранён.\n'
                f'Резервная копия: <code>{PROXY_CONF}.bak</code>\n\n'
                f'Перезапустите прокси для применения.',
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton('\U0001f504 Перезапустить',
                                          callback_data='mtproxy:ask:restart')],
                    [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                          callback_data='mtproxy:main')],
                ]),
            )
        except Exception as e:
            self._editing = False
            log.exception('save config failed: %s', e)
            await update.message.reply_text(f'❌ Не удалось сохранить: {e}')

    # ================= запуск =================

    async def _start_action(self, q, ctx, key, action):
        if self._running:
            return
        self._running = True
        self._last_action = key
        self._buf = b''
        self._last_edit = 0.0
        self._awaiting_yn = False

        self._status_msg_id = await ui_edit_q(
            q,
            f'{action["icon"]} <b>{action["title"]}</b>\n\n<pre>запуск...</pre>',
            kb=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='mtproxy:kill')],
            ]),
        )

        pid, master = pty.fork()
        if pid == 0:
            try:
                os.environ['TERM'] = 'dumb'
                os.environ['DEBIAN_FRONTEND'] = 'noninteractive'
                os.execv('/bin/sh', ['sh', '-c', action['cmd']])
            except Exception:
                os._exit(1)
        self._proc_pid = pid
        self._master = master
        asyncio.create_task(self._reader_loop(ctx, pid, master))

    def _drain_master(self, master) -> bytes:
        import select as _select
        extra = b''
        try:
            while True:
                r, _, _ = _select.select([master], [], [], 0.3)
                if not r:
                    break
                try:
                    data = os.read(master, 4096)
                except (BlockingIOError, OSError):
                    break
                if not data:
                    break
                extra += data
        except Exception as e:
            log.debug('drain_master: %s', e)
        return extra

    async def _reader_loop(self, ctx, pid, master):
        try:
            import fcntl
            fcntl.fcntl(master, fcntl.F_SETFL, os.O_NONBLOCK)
        except Exception as e:
            log.warning('nonblock failed: %s', e)

        idle_start = time.time()
        start_time = time.time()
        timeout_total = 180
        try:
            while True:
                if time.time() - start_time > timeout_total:
                    log.warning('Timeout %ss, killing process', timeout_total)
                    try:
                        os.kill(pid, 9)
                    except Exception:
                        pass
                    self._buf += b'\n[!] Timeout: process killed\n'
                    break
                try:
                    wpid, _ws = os.waitpid(pid, os.WNOHANG)
                    if wpid == pid:
                        self._buf += self._drain_master(master)
                        break
                except ChildProcessError:
                    self._buf += self._drain_master(master)
                    break
                except Exception:
                    pass

                try:
                    data = os.read(master, 4096)
                    idle_start = time.time()
                except BlockingIOError:
                    if time.time() - idle_start > 2.0:
                        try:
                            wpid, _ws = os.waitpid(pid, os.WNOHANG)
                            if wpid == pid:
                                self._buf += self._drain_master(master)
                                break
                        except Exception:
                            pass
                    await asyncio.sleep(0.15)
                    continue
                except OSError:
                    break
                if not data:
                    break
                self._buf += data
                if len(self._buf) > 60000:
                    self._buf = self._buf[-50000:]
                now = time.time()
                if now - self._last_edit >= 1.2:
                    self._last_edit = now
                    await self._update_status(ctx)
        finally:
            try:
                os.close(master)
            except Exception:
                pass
            self._master = None

        try:
            _, status = os.waitpid(pid, 0)
            rc = os.waitstatus_to_exitcode(status)
        except ChildProcessError:
            rc = 0
        except Exception:
            rc = -1
        self._proc_pid = None
        await self._finish(ctx, self._buf, rc)

    async def _update_status(self, ctx=None, bot=None):
        if bot is None and ctx is not None:
            bot = ctx.bot
        if bot is None or not self._status_msg_id:
            return
        text = _strip_ansi(self._buf.decode('utf-8', errors='replace'))
        tail = text[-1800:] if len(text) > 1800 else text
        try:
            await bot.edit_message_text(
                chat_id=self.chat_id,
                message_id=self._status_msg_id,
                text=f'\u23f3 <b>Выполняется...</b>\n\n<pre>{_esc(tail)}</pre>',
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton('\U0001f6d1 Отменить',
                                          callback_data='mtproxy:kill')],
                ]),
            )
        except Exception as e:
            if 'not modified' not in str(e).lower():
                log.debug('update_status: %s', e)

    async def _finish(self, ctx, buf, rc):
        self._running = False
        self._awaiting_yn = False
        was_uninstall = (self._last_action == 'uninstall')
        was_cleanup = (self._last_action == 'cleanup')
        text = _strip_ansi(buf.decode('utf-8', errors='replace'))

        if rc == 0 and 'Collected errors' in text:
            new_lines, skip = [], False
            for ln in text.split('\n'):
                if 'Collected errors' in ln:
                    skip = True
                    continue
                if skip:
                    if ln.strip().startswith('*'):
                        if 'is not installed' in ln:
                            continue
                        new_lines.append(ln)
                        continue
                    else:
                        skip = False
                new_lines.append(ln)
            text = '\n'.join(new_lines).strip()

        offer_start = (
            self._last_action == 'install'
            and rc == 0
            and (is_installed())
            and not (is_running())
        )
        self._last_action = None
        icon = '\u2705' if rc == 0 else '\u274c'

        if offer_start:
            header = (f'{icon} <b>Установка завершена</b>\n'
                      f'<i>exit code: {rc}</i>')
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u25b6\ufe0f Запустить сейчас',
                                      callback_data='mtproxy:ask:start')],
                [InlineKeyboardButton('\u23ed Позже',
                                      callback_data='mtproxy:main')],
            ])
        elif was_cleanup:
            header = f'{icon} <b>Остатки удалены</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                      callback_data='mtproxy:main')],
            ])
        else:
            header = f'{icon} <b>Операция завершена</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                      callback_data='mtproxy:main')],
            ])

        body = header
        if text.strip():
            tail = '\n'.join(text.strip().split('\n')[-20:])
            if len(tail) > 1800:
                tail = '\u2026' + tail[-1800:]
            body += f'\n\n<pre>{_esc(tail)}</pre>'
            body += '\n\n<i>Полный лог: /opt/var/log/router_bot.log</i>'

        if rc == 0 and was_uninstall:
            try:
                leftovers = scan_leftovers(SCAN_PATTERNS)
            except Exception:
                leftovers = []
            if leftovers:
                self._leftovers = leftovers
                body += f'\n\n\U0001f50d <b>Найдено {len(leftovers)} остатков.</b>'
                kb = InlineKeyboardMarkup([
                    [InlineKeyboardButton(
                        f'\U0001f5d1 Удалить все ({len(leftovers)})',
                        callback_data='mtproxy:cleanup:all')],
                    [InlineKeyboardButton('\u2705 Оставить',
                                          callback_data='mtproxy:main')],
                ])

        if self._status_msg_id:
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id,
                    message_id=self._status_msg_id,
                    text=body,
                    parse_mode='HTML',
                    reply_markup=kb,
                )
                self._status_msg_id = None
                return
            except Exception as e:
                log.debug('final edit failed: %s', e)
                self._status_msg_id = None

        msg = await ctx.bot.send_message(            chat_id=self.chat_id, text=body,
            parse_mode='HTML', reply_markup=kb,
        )

        set_last_msg(self.chat_id, msg.message_id)

    # ================= меню удаления =================

    async def _show_uninstall_menu(self, q, ctx):
        targets = existing_targets(UNINSTALL_TARGETS)
        self._uninstall_opts = sync_opts(targets, self._uninstall_opts)

        text, kb = build_uninstall_menu(
            targets,
            self._uninstall_opts,
            title='Удаление MTProxy',
            always_msg='Пакет <code>tg-ws-proxy</code> удаляется всегда.',
            prefix='mtproxy',
        )
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise

    async def _handle_opt(self, q, ctx, key):
        if key in self._uninstall_opts:
            toggle_opt(self._uninstall_opts, key)
            state = 'вкл' if self._uninstall_opts[key] else 'выкл'
            await q.answer(f'{state}: {key}')
            await self._show_uninstall_menu(q, ctx)
            return

        if key == 'go':
            await q.answer()
            targets = existing_targets(UNINSTALL_TARGETS)
            cmd = collect_uninstall_cmd(targets, self._uninstall_opts, UNINSTALL_CMD)
            self._uninstall_opts = {}

            self._buf = b''
            self._last_edit = 0.0
            self._running = True
            self._last_action = 'uninstall'
            self._status_msg_id = await ui_edit_q(
                q,
                '\U0001f5d1 <b>Удаление MTProxy</b>\n\n<pre>запуск...</pre>',
                kb=InlineKeyboardMarkup([
                    [InlineKeyboardButton('\U0001f6d1 Отменить',
                                          callback_data='mtproxy:kill')],
                ]),
            )
            pid, master = pty.fork()
            if pid == 0:
                try:
                    os.environ['TERM'] = 'dumb'
                    os.execv('/bin/sh', ['sh', '-c', cmd])
                except Exception:
                    os._exit(1)
            self._proc_pid = pid
            self._master = master
            asyncio.create_task(self._reader_loop(ctx, pid, master))
            return

        await q.answer()

    # ================= удаление остатков =================

    async def _check_leftovers(self, ctx):
        try:
            leftovers = scan_leftovers(SCAN_PATTERNS)
        except Exception as e:
            log.debug('scan_leftovers failed: %s', e)
            return
        if not leftovers:
            return
        self._leftovers = leftovers
        text, kb = build_leftovers_message(leftovers, prefix='mtproxy')
        try:
            await ctx.bot.send_message(
                chat_id=self.chat_id,
                text=text,
                parse_mode='HTML',
                reply_markup=kb,
            )
        except Exception as e:
            log.warning('send leftovers failed: %s', e)

    async def _do_cleanup(self, q, ctx):
        if not getattr(self, '_leftovers', None):
            await q.answer('Нечего удалять', show_alert=True)
            return
        parts = []
        total = len(self._leftovers)
        for p in self._leftovers:
            safe = p.replace("'", "'\\''")
            parts.append(f"echo 'Удаляю: {safe}' ; rm -rf '{safe}'")
        parts.append(f"echo '' ; echo 'Готово: удалено {total} элементов'")
        cmd = ' ; '.join(parts)
        self._leftovers = []

        self._buf = b''
        self._last_edit = 0.0
        self._running = True
        self._last_action = 'cleanup'
        self._status_msg_id = await ui_edit_q(
                q,
                '\U0001f5d1 <b>Удаление остатков MTProxy</b>\n\n<pre>запуск...</pre>',
                kb=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='mtproxy:kill')],
            ]),
            )
        pid, master = pty.fork()
        if pid == 0:
            try:
                os.environ['TERM'] = 'dumb'
                os.execv('/bin/sh', ['sh', '-c', cmd])
            except Exception:
                os._exit(1)
        self._proc_pid = pid
        self._master = master
        asyncio.create_task(self._reader_loop(ctx, pid, master))
RB_MODULES_MTPROXY_MODULE_PY_EOF

echo "  → modules/mtproxy/actions.py"
cat > /opt/router_bot/modules/mtproxy/actions.py << 'RB_MODULES_MTPROXY_ACTIONS_PY_EOF'
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
GET_LINK = 'grep -oE "tg://proxy[^[:space:]\"]+" /opt/var/log/tg-ws-proxy.log | tail -1'

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
        has_pkg = (r.returncode == 0)
    except Exception:
        has_pkg = False
    has_bin = os.path.exists(PROXY_BIN)
    has_init = os.path.exists(PROXY_INIT)
    return has_pkg and has_bin and has_init


def is_broken() -> bool:
    """Пакет в opkg есть, но бинарник или init отсутствуют."""
    try:
        r = subprocess.run(
            ['sh', '-c', 'opkg list-installed 2>/dev/null | grep -q "^tg-ws-proxy "'],
            timeout=5,
        )
        has_pkg = (r.returncode == 0)
    except Exception:
        has_pkg = False
    has_bin = os.path.exists(PROXY_BIN)
    has_init = os.path.exists(PROXY_INIT)
    return has_pkg and not (has_bin and has_init)


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
    'reinstall': {
        'title': 'Переустановка MTProxy',
        'icon': '🔧',
        'desc': 'Удаление повреждённых файлов и установка пакета заново.',
        'cmd': 'opkg remove --force-removal-of-dependent-packages --autoremove tg-ws-proxy 2>&1 || true ; '
               'rm -f /opt/bin/tg-ws-proxy /opt/etc/init.d/S99tg-ws-proxy ; '
               'curl -fsSL https://raw.githubusercontent.com/spatiumstas/feedly/main/add-repo.sh | sh && '
               'opkg update && opkg install tg-ws-proxy'
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
RB_MODULES_MTPROXY_ACTIONS_PY_EOF

echo "  → modules/keen_pbr/__init__.py"
cat > /opt/router_bot/modules/keen_pbr/__init__.py << 'RB_MODULES_KEEN_PBR___INIT___PY_EOF'

RB_MODULES_KEEN_PBR___INIT___PY_EOF

echo "  → modules/keen_pbr/module.py"
cat > /opt/router_bot/modules/keen_pbr/module.py << 'RB_MODULES_KEEN_PBR_MODULE_PY_EOF'
"""Модуль keen-pbr — policy-based routing."""
import asyncio
import html
import logging
import os
import pty
import re
import time

from telegram import (
    InlineKeyboardButton, InlineKeyboardMarkup, Update,
)
from telegram.ext import MessageHandler, filters, ContextTypes

from .actions import (
    ACTIONS, UNINSTALL_CMD, UNINSTALL_TARGETS, SCAN_PATTERNS,
    PBR_CONF, PBR_WEB,
    is_installed, is_running, get_version, get_status_short,
    get_config_path,
)
from core.utils import (
    existing_targets, sync_opts, build_uninstall_menu,
    collect_uninstall_cmd, toggle_opt,
    scan_leftovers, build_leftovers_message,
    ui_edit_q, ui_edit_or_send,
    show_card,
    show_card,
    ui_edit_q,
)
from core.utils import set_last_msg

log = logging.getLogger(__name__)

MAX_MSG = 3500


def _esc(s: str) -> str:
    return html.escape(s or '')


def _strip_ansi(s: str) -> str:
    s = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', s)
    s = re.sub(r'\x1b\][^\x07]*\x07', '', s)
    s = re.sub(r'\x1b[=>]', '', s)
    return s


def _split(text, size=MAX_MSG):
    if not text:
        return ['']
    chunks, cur = [], ''
    for line in text.splitlines(keepends=True):
        if len(cur) + len(line) > size:
            if cur:
                chunks.append(cur)
            cur = line
            while len(cur) > size:
                chunks.append(cur[:size])
                cur = cur[size:]
        else:
            cur += line
    if cur:
        chunks.append(cur)
    return chunks


class KeenPbrModule:
    name = 'keen_pbr'
    title = 'Keen-PBR'
    icon = '\U0001f6e4'  # 🛤
    description = 'policy-based routing для Keenetic'
    category = 'services'
    category_title = 'Сервис'
    category_icon = '\U0001f6e0'
    conflicts_with = {
        'xkeen': 'оба занимают policy-routing и nftables-метки',
        'hydraroute': 'оба используют nftables/iptables для маршрутизации',
    }
    commands = [('kp', '🛤 Keen-PBR')]
    cleanup_paths = [
        '/opt/sbin/keen-pbr',
        '/opt/bin/keen-pbr',
        '/opt/etc/keen-pbr',
        '/opt/var/log/keen-pbr*',
        '/opt/var/run/keen-pbr*',
    ]
    cleanup_init = ['S99keen-pbr']

    def __init__(self, chat_id):
        self.chat_id = str(chat_id)
        self._proc_pid = None
        self._master = None
        self._running = False
        self._status_msg_id = None
        self._buf = b''
        self._last_edit = 0.0
        self._last_action = None
        self._uninstall_opts = {}
        self._leftovers = []
        self._editing = False

    async def startup(self, app):
        app.add_handler(MessageHandler(
            filters.TEXT & ~filters.COMMAND,
            self._handle_text,
        ))
        log.info('Keen-PBR module started')

    async def on_leave(self):
        self._kill()
        self._editing = False

    def _kill(self):
        import signal
        pid = getattr(self, '_proc_pid', None)
        if pid:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(os.getpgid(pid), sig)
                except ProcessLookupError:
                    break
                except Exception:
                    try:
                        os.kill(pid, sig)
                    except Exception:
                        pass
                time.sleep(0.4)
            try:
                os.waitpid(pid, os.WNOHANG)
            except Exception:
                pass
            self._proc_pid = None
        if self._master is not None:
            try:
                os.close(self._master)
            except Exception:
                pass
            self._master = None
        self._running = False

    # ================= статус =================

    def get_installed(self) -> bool:
        return is_installed()

    def get_status_short(self) -> str:
        return get_status_short()

    # ================= UI =================

    def _build_card(self):
        installed = is_installed()
        running = is_running()
        version = get_version() if installed else ''

        lines = [f'{self.icon} <b>{self.title}</b>', '']
        if installed:
            v = f' · <code>{version}</code>' if version else ''
            lines.append(f'✅ Установлен{v}')
            lines.append('Сервис: ' + ('🟢 работает' if running else '🔴 остановлен'))

            cfg_path = get_config_path()
            if cfg_path and os.path.exists(cfg_path):
                lines.append(f'Конфиг: <code>{_esc(cfg_path)}</code>')

            from core.utils import get_router_ip
            _ip = get_router_ip()
            _port = PBR_WEB.rsplit(':', 1)[-1]
            _url = f'http://{_ip}:{_port}'
            lines.append(f'Web UI: <a href="{_url}">{_url}</a>')
        else:
            lines.append('❌ Не установлен')
            import subprocess as _sp
            def _proc_running(pname):
                try:
                    _r = _sp.run(['sh', '-c', f'ps w | grep -q "[{pname[0]}]{pname[1:]}" && echo yes'], capture_output=True, text=True, timeout=3)
                    return 'yes' in (_r.stdout or '')
                except Exception: return False
            if _proc_running('xkeen'):
                lines.append('')
                lines.append('⚠️ <b>Конфликт с XKeen</b>')
                lines.append('<i>Удалите XKeen перед установкой.</i>')
            if _proc_running('hrneo'):
                lines.append('')
                lines.append('⚠️ <b>Конфликт с HydraRoute</b>')
                lines.append('<i>Удалите HydraRoute перед установкой.</i>')
        lines.append('')

        if self._running:
            lines.append('⏳ <b>Выполняется операция...</b>')
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить', callback_data='keen_pbr:kill')],
                [
                    InlineKeyboardButton('\u2b05\ufe0f Назад', callback_data='router:cat:services'),
                    InlineKeyboardButton('\U0001f3e0 Модули', callback_data='router:main'),
                ],
            ])
            return '\n'.join(lines), kb

        rows = []
        if not installed:
            rows.append([InlineKeyboardButton(
                '\u2b07\ufe0f Установить keen-pbr',
                callback_data='keen_pbr:ask:install')])
        else:
            if running:
                rows.append([InlineKeyboardButton(
                    '\u23f9 Остановить', callback_data='keen_pbr:ask:stop')])
                rows.append([InlineKeyboardButton(
                    '\U0001f504 Перезапустить', callback_data='keen_pbr:ask:restart')])
            else:
                rows.append([InlineKeyboardButton(
                    '\u25b6\ufe0f Запустить', callback_data='keen_pbr:ask:start')])
            rows.append([
                InlineKeyboardButton('\U0001f4ca Статус', callback_data='keen_pbr:ask:status'),
                InlineKeyboardButton('\u2139\ufe0f Инфо', callback_data='keen_pbr:ask:info'),
            ])
            rows.append([
                InlineKeyboardButton('\u2705 Проверить конфиг', callback_data='keen_pbr:ask:test_config'),
                InlineKeyboardButton('📄 Перечитать конфиг', callback_data='keen_pbr:ask:reload'),
            ])
            rows.append([InlineKeyboardButton(
                '\U0001f4c4 Показать конфиг', callback_data='keen_pbr:show_config')])
            rows.append([InlineKeyboardButton(
                '✏️ Редактировать конфиг', callback_data='keen_pbr:edit_config')])
            rows.append([InlineKeyboardButton(
                '\U0001f5d1 Удалить keen-pbr', callback_data='keen_pbr:ask:uninstall')])
        rows.append([InlineKeyboardButton(
            '\U0001f504 Обновить карточку', callback_data='keen_pbr:main')])
        rows.append([
            InlineKeyboardButton('\u2b05\ufe0f Назад', callback_data='router:cat:services'),
            InlineKeyboardButton('\U0001f3e0 Модули', callback_data='router:main'),
        ])
        return '\n'.join(lines), InlineKeyboardMarkup(rows)

    async def send_card_message(self, update, ctx):
        text, kb = self._build_card()
        await show_card(update, ctx, text, kb=kb)

    async def handle_callback(self, action, q, ctx):
        if action == 'main':
            await q.answer()
            self._editing = False
            text, kb = self._build_card()
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower():
                    raise
            return

        if action == 'kill':
            await q.answer('Прерываю...')
            self._kill()
            try:
                await q.edit_message_text(
                    '\U0001f6d1 Операция прервана.',
                    reply_markup=InlineKeyboardMarkup([
                        [InlineKeyboardButton('\u2b05\ufe0f Назад', callback_data='keen_pbr:main')],
                    ]),
                )
            except Exception:
                pass
            return

        if action == 'cleanup:all':
            await q.answer()
            return await self._do_cleanup(q, ctx)

        if action == 'show_config':
            await q.answer()
            return await self._show_config(q, ctx)

        if action == 'edit_config':
            await q.answer()
            return await self._ask_new_config(q, ctx)

        if action == 'ask:uninstall':
            await q.answer()
            return await self._show_uninstall_menu(q, ctx)

        if action.startswith('opt:'):
            return await self._handle_opt(q, ctx, action[4:])

        if action.startswith('ask:'):
            key = action[4:]
            await q.answer()
            a = ACTIONS.get(key)
            if not a:
                await q.answer('Неизвестное действие', show_alert=True)
                return
            text = (
                f'{a["icon"]} <b>{a["title"]}</b>\n\n'
                f'{a["desc"]}\n\n'
                f'Подтвердить?'
            )
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2705 Подтвердить',
                                      callback_data=f'keen_pbr:go:{key}')],
                [InlineKeyboardButton('\u274c Отмена',
                                      callback_data='keen_pbr:main')],
            ])
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower():
                    raise
            return

        if action.startswith('go:'):
            key = action[3:]
            await q.answer()
            a = ACTIONS.get(key)
            if not a:
                return
            await self._start_action(q, ctx, key, a)
            return

        await q.answer()

    # ================= конфиг =================

    async def _show_config(self, q, ctx):
        cfg_path = get_config_path()
        try:
            if os.path.exists(cfg_path):
                with open(cfg_path) as f:
                    content = f.read()
            else:
                content = f'(файл {cfg_path} не найден)'
        except Exception as e:
            content = f'(ошибка чтения: {e})'

        if len(content) > 3000:
            content = content[:3000] + '\n... (сокращено)'

        text = (
            f'\U0001f4c4 <b>Конфиг keen-pbr</b>\n'
            f'<code>{_esc(cfg_path)}</code>\n\n'
            f'<pre>{_esc(content)}</pre>'
        )
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('\u270f\ufe0f Прислать новый конфиг',
                                  callback_data='keen_pbr:edit_config')],
            [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                  callback_data='keen_pbr:main')],
        ])
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise

    async def _ask_new_config(self, q, ctx):
        self._editing = True
        cfg_path = get_config_path()
        text = (
            '\u270f\ufe0f <b>Пришлите новый конфиг</b>\n\n'
            'Следующим сообщением отправьте полный текст YAML-файла\n'
            f'<code>{_esc(cfg_path)}</code>.\n\n'
            '⚠️ Текущий файл будет сохранён в <code>.bak</code>.\n'
            'После записи перезапустите сервис для применения.'
        )
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('\u274c Отмена', callback_data='keen_pbr:main')],
        ])
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise

    async def _handle_text(self, update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        if str(update.effective_chat.id) != self.chat_id:
            return
        if not self._editing:
            return
        text = update.message.text or ''
        if not text.strip():
            return

        cfg_path = get_config_path()
        try:
            import shutil
            if os.path.exists(cfg_path):
                shutil.copy(cfg_path, cfg_path + '.bak')
            os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
            with open(cfg_path, 'w') as f:
                f.write(text)
            self._editing = False
            await update.message.reply_text(
                f'✅ Конфиг сохранён: <code>{_esc(cfg_path)}</code>\n'
                f'Резервная копия: <code>{_esc(cfg_path)}.bak</code>\n\n'
                f'Перезапустите сервис для применения.',
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton('\u2705 Проверить',
                                          callback_data='keen_pbr:ask:test_config')],
                    [InlineKeyboardButton('\U0001f504 Перезапустить',
                                          callback_data='keen_pbr:ask:restart')],
                    [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                          callback_data='keen_pbr:main')],
                ]),
            )
        except Exception as e:
            self._editing = False
            log.exception('save keen-pbr config failed: %s', e)
            await update.message.reply_text(f'❌ Не удалось сохранить: {e}')

    # ================= запуск =================

    async def _start_action(self, q, ctx, key, action):
        if self._running:
            return
        self._running = True
        self._last_action = key
        self._buf = b''
        self._last_edit = 0.0
        self._awaiting_yn = False

        self._status_msg_id = await ui_edit_q(
            q,
            f'{action["icon"]} <b>{action["title"]}</b>\n\n<pre>запуск...</pre>',
            kb=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='keen_pbr:kill')],
            ]),
        )

        pid, master = pty.fork()
        if pid == 0:
            try:
                os.environ['TERM'] = 'dumb'
                os.environ['DEBIAN_FRONTEND'] = 'noninteractive'
                os.execv('/bin/sh', ['sh', '-c', action['cmd']])
            except Exception:
                os._exit(1)
        self._proc_pid = pid
        self._master = master
        asyncio.create_task(self._reader_loop(ctx, pid, master))

    def _drain_master(self, master) -> bytes:
        import select as _select
        extra = b''
        try:
            while True:
                r, _, _ = _select.select([master], [], [], 0.3)
                if not r:
                    break
                try:
                    data = os.read(master, 4096)
                except (BlockingIOError, OSError):
                    break
                if not data:
                    break
                extra += data
        except Exception as e:
            log.debug('drain_master: %s', e)
        return extra

    async def _reader_loop(self, ctx, pid, master):
        try:
            import fcntl
            fcntl.fcntl(master, fcntl.F_SETFL, os.O_NONBLOCK)
        except Exception as e:
            log.warning('nonblock failed: %s', e)

        idle_start = time.time()
        start_time = time.time()
        timeout_total = 180
        try:
            while True:
                if time.time() - start_time > timeout_total:
                    log.warning('Timeout %ss, killing process', timeout_total)
                    try:
                        os.kill(pid, 9)
                    except Exception:
                        pass
                    self._buf += b'\n[!] Timeout: process killed\n'
                    break
                try:
                    wpid, _ws = os.waitpid(pid, os.WNOHANG)
                    if wpid == pid:
                        self._buf += self._drain_master(master)
                        break
                except ChildProcessError:
                    self._buf += self._drain_master(master)
                    break
                except Exception:
                    pass

                try:
                    data = os.read(master, 4096)
                    idle_start = time.time()
                except BlockingIOError:
                    if time.time() - idle_start > 2.0:
                        try:
                            wpid, _ws = os.waitpid(pid, os.WNOHANG)
                            if wpid == pid:
                                self._buf += self._drain_master(master)
                                break
                        except Exception:
                            pass
                    await asyncio.sleep(0.15)
                    continue
                except OSError:
                    break
                if not data:
                    break
                self._buf += data
                if len(self._buf) > 60000:
                    self._buf = self._buf[-50000:]
                now = time.time()
                if now - self._last_edit >= 1.2:
                    self._last_edit = now
                    await self._update_status(ctx)
        finally:
            try:
                os.close(master)
            except Exception:
                pass
            self._master = None

        try:
            _, status = os.waitpid(pid, 0)
            rc = os.waitstatus_to_exitcode(status)
        except ChildProcessError:
            rc = 0
        except Exception:
            rc = -1
        self._proc_pid = None
        await self._finish(ctx, self._buf, rc)

    async def _update_status(self, ctx=None, bot=None):
        if bot is None and ctx is not None:
            bot = ctx.bot
        if bot is None or not self._status_msg_id:
            return
        text = _strip_ansi(self._buf.decode('utf-8', errors='replace'))
        tail = text[-1800:] if len(text) > 1800 else text
        try:
            await bot.edit_message_text(
                chat_id=self.chat_id,
                message_id=self._status_msg_id,
                text=f'\u23f3 <b>Выполняется...</b>\n\n<pre>{_esc(tail)}</pre>',
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton('\U0001f6d1 Отменить',
                                          callback_data='keen_pbr:kill')],
                ]),
            )
        except Exception as e:
            if 'not modified' not in str(e).lower():
                log.debug('update_status: %s', e)

    async def _finish(self, ctx, buf, rc):
        self._running = False
        self._awaiting_yn = False
        was_uninstall = (self._last_action == 'uninstall')
        was_cleanup = (self._last_action == 'cleanup')
        text = _strip_ansi(buf.decode('utf-8', errors='replace'))

        if rc == 0 and 'Collected errors' in text:
            new_lines, skip = [], False
            for ln in text.split('\n'):
                if 'Collected errors' in ln:
                    skip = True
                    continue
                if skip:
                    if ln.strip().startswith('*'):
                        if 'is not installed' in ln:
                            continue
                        new_lines.append(ln)
                        continue
                    else:
                        skip = False
                new_lines.append(ln)
            text = '\n'.join(new_lines).strip()

        offer_start = (
            self._last_action == 'install'
            and rc == 0
            and (is_installed())
            and not (is_running())
        )
        self._last_action = None
        icon = '\u2705' if rc == 0 else '\u274c'

        if offer_start:
            header = (f'{icon} <b>Установка завершена</b>\n'
                      f'<i>exit code: {rc}</i>')
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u25b6\ufe0f Запустить сейчас',
                                      callback_data='keen_pbr:ask:start')],
                [InlineKeyboardButton('\u23ed Позже',
                                      callback_data='keen_pbr:main')],
            ])
        elif was_cleanup:
            header = f'{icon} <b>Остатки удалены</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                      callback_data='keen_pbr:main')],
            ])
        else:
            header = f'{icon} <b>Операция завершена</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                      callback_data='keen_pbr:main')],
            ])

        body = header
        if text.strip():
            tail = '\n'.join(text.strip().split('\n')[-20:])
            if len(tail) > 1800:
                tail = '\u2026' + tail[-1800:]
            body += f'\n\n<pre>{_esc(tail)}</pre>'
            body += '\n\n<i>Полный лог: /opt/var/log/router_bot.log</i>'

        if rc == 0 and was_uninstall:
            try:
                leftovers = scan_leftovers(SCAN_PATTERNS)
            except Exception:
                leftovers = []
            if leftovers:
                self._leftovers = leftovers
                body += f'\n\n\U0001f50d <b>Найдено {len(leftovers)} остатков.</b>'
                kb = InlineKeyboardMarkup([
                    [InlineKeyboardButton(
                        f'\U0001f5d1 Удалить все ({len(leftovers)})',
                        callback_data='keen_pbr:cleanup:all')],
                    [InlineKeyboardButton('\u2705 Оставить',
                                          callback_data='keen_pbr:main')],
                ])

        if self._status_msg_id:
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id,
                    message_id=self._status_msg_id,
                    text=body,
                    parse_mode='HTML',
                    reply_markup=kb,
                )
                self._status_msg_id = None
                return
            except Exception as e:
                log.debug('final edit failed: %s', e)
                self._status_msg_id = None

        msg = await ctx.bot.send_message(            chat_id=self.chat_id, text=body,
            parse_mode='HTML', reply_markup=kb,
        )

        set_last_msg(self.chat_id, msg.message_id)

    # ================= меню удаления =================

    async def _show_uninstall_menu(self, q, ctx):
        targets = existing_targets(UNINSTALL_TARGETS)
        self._uninstall_opts = sync_opts(targets, self._uninstall_opts)

        text, kb = build_uninstall_menu(
            targets,
            self._uninstall_opts,
            title='Удаление keen-pbr',
            always_msg='Пакет <code>keen-pbr</code> удаляется всегда.',
            prefix='keen_pbr',
        )
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise

    async def _handle_opt(self, q, ctx, key):
        if key in self._uninstall_opts:
            toggle_opt(self._uninstall_opts, key)
            state = 'вкл' if self._uninstall_opts[key] else 'выкл'
            await q.answer(f'{state}: {key}')
            await self._show_uninstall_menu(q, ctx)
            return

        if key == 'go':
            await q.answer()
            targets = existing_targets(UNINSTALL_TARGETS)
            cmd = collect_uninstall_cmd(targets, self._uninstall_opts, UNINSTALL_CMD)
            self._uninstall_opts = {}

            self._buf = b''
            self._last_edit = 0.0
            self._running = True
            self._last_action = 'uninstall'
            self._status_msg_id = await ui_edit_q(
                q,
                '\U0001f5d1 <b>Удаление keen-pbr</b>\n\n<pre>запуск...</pre>',
                kb=InlineKeyboardMarkup([
                    [InlineKeyboardButton('\U0001f6d1 Отменить',
                                          callback_data='keen_pbr:kill')],
                ]),
            )
            pid, master = pty.fork()
            if pid == 0:
                try:
                    os.environ['TERM'] = 'dumb'
                    os.execv('/bin/sh', ['sh', '-c', cmd])
                except Exception:
                    os._exit(1)
            self._proc_pid = pid
            self._master = master
            asyncio.create_task(self._reader_loop(ctx, pid, master))
            return

        await q.answer()

    # ================= удаление остатков =================

    async def _check_leftovers(self, ctx):
        try:
            leftovers = scan_leftovers(SCAN_PATTERNS)
        except Exception as e:
            log.debug('scan_leftovers failed: %s', e)
            return
        if not leftovers:
            return
        self._leftovers = leftovers
        text, kb = build_leftovers_message(leftovers, prefix='keen_pbr')
        try:
            await ctx.bot.send_message(
                chat_id=self.chat_id,
                text=text,
                parse_mode='HTML',
                reply_markup=kb,
            )
        except Exception as e:
            log.warning('send leftovers failed: %s', e)

    async def _do_cleanup(self, q, ctx):
        if not getattr(self, '_leftovers', None):
            await q.answer('Нечего удалять', show_alert=True)
            return
        parts = []
        total = len(self._leftovers)
        for p in self._leftovers:
            safe = p.replace("'", "'\\''")
            parts.append(f"echo 'Удаляю: {safe}' ; rm -rf '{safe}'")
        parts.append(f"echo '' ; echo 'Готово: удалено {total} элементов'")
        cmd = ' ; '.join(parts)
        self._leftovers = []

        self._buf = b''
        self._last_edit = 0.0
        self._running = True
        self._last_action = 'cleanup'
        self._status_msg_id = await ui_edit_q(
                q,
                '\U0001f5d1 <b>Удаление остатков keen-pbr</b>\n\n<pre>запуск...</pre>',
                kb=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='keen_pbr:kill')],
            ]),
            )
        pid, master = pty.fork()
        if pid == 0:
            try:
                os.environ['TERM'] = 'dumb'
                os.execv('/bin/sh', ['sh', '-c', cmd])
            except Exception:
                os._exit(1)
        self._proc_pid = pid
        self._master = master
        asyncio.create_task(self._reader_loop(ctx, pid, master))
RB_MODULES_KEEN_PBR_MODULE_PY_EOF

echo "  → modules/keen_pbr/actions.py"
cat > /opt/router_bot/modules/keen_pbr/actions.py << 'RB_MODULES_KEEN_PBR_ACTIONS_PY_EOF'
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
            'Использует nftables и sing-box/xray ядра.'
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
RB_MODULES_KEEN_PBR_ACTIONS_PY_EOF

echo "  → modules/neofit/__init__.py"
cat > /opt/router_bot/modules/neofit/__init__.py << 'RB_MODULES_NEOFIT___INIT___PY_EOF'

RB_MODULES_NEOFIT___INIT___PY_EOF

echo "  → modules/neofit/module.py"
cat > /opt/router_bot/modules/neofit/module.py << 'RB_MODULES_NEOFIT_MODULE_PY_EOF'
"""Модуль NeoFit — веб-панель управления прокси на Keenetic."""
import asyncio
import html
import logging
import os
import pty
import re
import time

from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import ContextTypes, MessageHandler, filters, ApplicationHandlerStop

from .actions import (
    ACTIONS, UNINSTALL_CMD, UNINSTALL_TARGETS, SCAN_PATTERNS,
    get_neofit_web_url, get_router_ip,
    is_installed, is_running, get_version, get_status_short,
)
from core.utils import (
    existing_targets, sync_opts, build_uninstall_menu,
    collect_uninstall_cmd, toggle_opt, scan_leftovers, build_leftovers_message,
    show_card,
    show_card,
    ui_edit_q,
)
from core.utils import set_last_msg

log = logging.getLogger(__name__)
MAX_MSG = 3500


def _esc(s):
    return html.escape(s or '')


def _strip_ansi(s):
    s = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', s)
    s = re.sub(r'\x1b\][^\x07]*\x07', '', s)
    s = re.sub(r'\x1b[=>]', '', s)
    return s


class NeoFitModule:
    name = 'neofit'
    title = 'NeoFit'
    icon = '\U0001f500'
    description = 'веб-панель управления Xray/Sing-Box'
    category = 'services'
    category_title = 'Сервис'
    category_icon = '\U0001f6e0'
    conflicts_with = {
        'xkeen': 'оба используют Xray/Sing-Box ядра',
    }
    commands = [('nf', '🔀 NeoFit')]
    cleanup_paths = [
        '/opt/sbin/neofit',
        '/opt/bin/neofit',
        '/opt/sbin/nf',
        '/opt/bin/nf',
        '/opt/etc/neofit',
        '/opt/etc/opkg/neofit.conf',
        '/opt/var/log/neofit*',
        '/opt/var/run/neofit*',
    ]
    cleanup_init = ['S69neofit']

    def __init__(self, chat_id):
        self.chat_id = str(chat_id)
        self._proc_pid = None
        self._master = None
        self._running = False
        self._status_msg_id = None
        self._buf = b''
        self._last_edit = 0.0
        self._last_action = None
        self._uninstall_opts = {}
        self._leftovers = []

    async def startup(self, app):
        log.info('NeoFit module started')

    async def on_leave(self):
        self._kill()

    def _kill(self):
        import signal
        pid = getattr(self, '_proc_pid', None)
        if pid:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(os.getpgid(pid), sig)
                except ProcessLookupError:
                    break
                except Exception:
                    try:
                        os.kill(pid, sig)
                    except Exception:
                        pass
                time.sleep(0.4)
            try:
                os.waitpid(pid, os.WNOHANG)
            except Exception:
                pass
            self._proc_pid = None
        if self._master is not None:
            try:
                os.close(self._master)
            except Exception:
                pass
            self._master = None
        self._running = False

    def get_installed(self):
        return is_installed()

    def get_status_short(self):
        return get_status_short()

    # ================= UI =================

    def _build_card(self):
        installed = is_installed()
        running = is_running()
        version = get_version() if installed else ''

        lines = [f'{self.icon} <b>{self.title}</b>', '']
        if installed:
            v = f' · <code>{version}</code>' if version else ''
            lines.append(f'✅ Установлен{v}')
            lines.append('Сервис: ' + ('🟢 работает' if running else '🔴 остановлен'))
            _url = get_neofit_web_url()
            lines.append(f'Web UI: <a href="{_url}">{_url}</a>')
            if os.path.exists('/opt/etc/neofit'):
                lines.append('Конфиг: <code>/opt/etc/neofit/</code>')
        else:
            lines.append('❌ Не установлен')
            _xk_proc = False
            try:
                import subprocess as _sp
                _r = _sp.run(['sh', '-c', 'ps w | grep -q "[x]keen" && echo yes'],
                             capture_output=True, text=True, timeout=3)
                _xk_proc = 'yes' in (_r.stdout or '')
            except Exception:
                pass
            if _xk_proc:
                lines.append('')
                lines.append('⚠️ <b>Конфликт с XKeen</b>')
                lines.append('<i>Удалите XKeen перед установкой.</i>')
        lines.append('')

        if self._running:
            lines.append('⏳ <b>Выполняется операция...</b>')
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить', callback_data='neofit:kill')],
                [InlineKeyboardButton('\u2b05\ufe0f Назад', callback_data='router:cat:services'),
                 InlineKeyboardButton('\U0001f3e0 Модули', callback_data='router:main')],
            ])
            return '\n'.join(lines), kb

        rows = []
        if not installed:
            rows.append([InlineKeyboardButton(
                '\u2b07\ufe0f Установить NeoFit', callback_data='neofit:ask:install')])
        else:
            if running:
                rows.append([InlineKeyboardButton(
                    '\U0001f310 Открыть Web UI', url=get_neofit_web_url())])
                rows.append([
                    InlineKeyboardButton('\u23f9 Остановить', callback_data='neofit:ask:stop'),
                    InlineKeyboardButton('\U0001f504 Перезапустить', callback_data='neofit:ask:restart'),
                ])
            else:
                rows.append([InlineKeyboardButton(
                    '\u25b6\ufe0f Запустить', callback_data='neofit:ask:start')])
            rows.append([
                InlineKeyboardButton('\U0001f4ca Статус', callback_data='neofit:ask:status'),
                InlineKeyboardButton('\U0001f4dc Логи', callback_data='neofit:ask:logs'),
            ])
            rows.append([InlineKeyboardButton(
                '\U0001f5d1 Удалить NeoFit', callback_data='neofit:ask:uninstall')])
        rows.append([InlineKeyboardButton(
            '\U0001f504 Обновить карточку', callback_data='neofit:main')])
        rows.append([
            InlineKeyboardButton('\u2b05\ufe0f Назад', callback_data='router:cat:services'),
            InlineKeyboardButton('\U0001f3e0 Модули', callback_data='router:main'),
        ])
        return '\n'.join(lines), InlineKeyboardMarkup(rows)

    async def send_card_message(self, update, ctx):
        text, kb = self._build_card()
        await show_card(update, ctx, text, kb=kb)

    # ================= callback =================

    async def handle_callback(self, action, q, ctx):
        if action == 'main':
            await q.answer()
            text, kb = self._build_card()
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower():
                    raise
            return

        if action == 'kill':
            await q.answer('Прерываю...')
            self._kill()
            try:
                await q.edit_message_text(
                    '\U0001f6d1 Операция прервана.',
                    reply_markup=InlineKeyboardMarkup([
                        [InlineKeyboardButton('\u2b05\ufe0f Назад', callback_data='neofit:main')],
                    ]),
                )
            except Exception:
                pass
            return

        if action == 'cleanup:all':
            await q.answer()
            return await self._do_cleanup(q, ctx)

        if action == 'ask:uninstall':
            await q.answer()
            return await self._show_uninstall_menu(q, ctx)

        if action.startswith('opt:'):
            return await self._handle_opt(q, ctx, action[4:])

        if action.startswith('ask:'):
            key = action[4:]
            await q.answer()
            a = ACTIONS.get(key)
            if not a:
                await q.answer('Неизвестное действие', show_alert=True)
                return
            text = (
                f'{a["icon"]} <b>{a["title"]}</b>\n\n'
                f'{a["desc"]}\n\n'
                f'Подтвердить?'
            )
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2705 Подтвердить', callback_data=f'neofit:go:{key}')],
                [InlineKeyboardButton('\u274c Отмена', callback_data='neofit:main')],
            ])
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower():
                    raise
            return

        if action.startswith('go:'):
            key = action[3:]
            await q.answer()
            a = ACTIONS.get(key)
            if not a:
                return
            await self._start_action(q, ctx, key, a)
            return

        await q.answer()

    # ================= запуск =================

    async def _start_action(self, q, ctx, key, action):
        if self._running:
            return
        self._running = True
        self._last_action = key
        self._buf = b''
        self._last_edit = 0.0
        self._awaiting_yn = False

        self._status_msg_id = await ui_edit_q(
            q,
            f'{action["icon"]} <b>{action["title"]}</b>\n\n<pre>запуск...</pre>',
            kb=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='neofit:kill')],
            ]),
        )

        pid, master = pty.fork()
        if pid == 0:
            try:
                os.environ['TERM'] = 'dumb'
                os.environ['DEBIAN_FRONTEND'] = 'noninteractive'
                os.execv('/bin/sh', ['sh', '-c', action['cmd']])
            except Exception:
                os._exit(1)
        self._proc_pid = pid
        self._master = master
        asyncio.create_task(self._reader_loop(ctx, pid, master))

    def _drain_master(self, master):
        import select as _select
        extra = b''
        try:
            while True:
                r, _, _ = _select.select([master], [], [], 0.3)
                if not r:
                    break
                try:
                    data = os.read(master, 4096)
                except (BlockingIOError, OSError):
                    break
                if not data:
                    break
                extra += data
        except Exception as e:
            log.debug('drain_master: %s', e)
        return extra

    async def _reader_loop(self, ctx, pid, master):
        try:
            import fcntl
            fcntl.fcntl(master, fcntl.F_SETFL, os.O_NONBLOCK)
        except Exception as e:
            log.warning('nonblock failed: %s', e)

        idle_start = time.time()
        start_time = time.time()
        timeout_total = 180
        try:
            while True:
                if time.time() - start_time > timeout_total:
                    log.warning('Timeout %ss, killing process', timeout_total)
                    try:
                        os.kill(pid, 9)
                    except Exception:
                        pass
                    self._buf += b'\n[!] Timeout: process killed\n'
                    break
                try:
                    wpid, _ws = os.waitpid(pid, os.WNOHANG)
                    if wpid == pid:
                        self._buf += self._drain_master(master)
                        break
                except ChildProcessError:
                    self._buf += self._drain_master(master)
                    break
                except Exception:
                    pass

                try:
                    data = os.read(master, 4096)
                    idle_start = time.time()
                except BlockingIOError:
                    if time.time() - idle_start > 2.0:
                        try:
                            wpid, _ws = os.waitpid(pid, os.WNOHANG)
                            if wpid == pid:
                                self._buf += self._drain_master(master)
                                break
                        except Exception:
                            pass
                    await asyncio.sleep(0.15)
                    continue
                except OSError:
                    break
                if not data:
                    break
                self._buf += data
                if len(self._buf) > 60000:
                    self._buf = self._buf[-50000:]
                now = time.time()
                if now - self._last_edit >= 1.2:
                    self._last_edit = now
                    await self._update_status(ctx)
        finally:
            try:
                os.close(master)
            except Exception:
                pass
            self._master = None

        try:
            _, status = os.waitpid(pid, 0)
            rc = os.waitstatus_to_exitcode(status)
        except ChildProcessError:
            rc = 0
        except Exception:
            rc = -1
        self._proc_pid = None
        await self._finish(ctx, self._buf, rc)

    async def _update_status(self, ctx=None, bot=None):
        if bot is None and ctx is not None:
            bot = ctx.bot
        if bot is None or not self._status_msg_id:
            return
        text = _strip_ansi(self._buf.decode('utf-8', errors='replace'))
        tail = text[-1800:] if len(text) > 1800 else text
        try:
            await bot.edit_message_text(
                chat_id=self.chat_id,
                message_id=self._status_msg_id,
                text=f'\u23f3 <b>Выполняется...</b>\n\n<pre>{_esc(tail)}</pre>',
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton('\U0001f6d1 Отменить',
                                          callback_data='neofit:kill')],
                ]),
            )
        except Exception as e:
            if 'not modified' not in str(e).lower():
                log.debug('update_status: %s', e)

    # ================= финал =================

    async def _finish(self, ctx, buf, rc):
        self._running = False
        self._awaiting_yn = False
        was_uninstall = (self._last_action == 'uninstall')
        was_cleanup = (self._last_action == 'cleanup')
        text = _strip_ansi(buf.decode('utf-8', errors='replace'))

        if rc == 0 and 'Collected errors' in text:
            new_lines, skip = [], False
            for ln in text.split('\n'):
                if 'Collected errors' in ln:
                    skip = True
                    continue
                if skip:
                    if ln.strip().startswith('*'):
                        if 'is not installed' in ln:
                            continue
                        new_lines.append(ln)
                        continue
                    else:
                        skip = False
                new_lines.append(ln)
            text = '\n'.join(new_lines).strip()

        offer_start = (
            self._last_action == 'install'
            and rc == 0
            and (is_installed())
            and not (is_running())
        )
        self._last_action = None
        icon = '\u2705' if rc == 0 else '\u274c'

        if offer_start:
            header = (f'{icon} <b>Установка завершена</b>\n'
                      f'<i>exit code: {rc}</i>')
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u25b6\ufe0f Запустить сейчас',
                                      callback_data='neofit:ask:start')],
                [InlineKeyboardButton('\u23ed Позже',
                                      callback_data='neofit:main')],
            ])
        elif was_cleanup:
            header = f'{icon} <b>Остатки удалены</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                      callback_data='neofit:main')],
            ])
        else:
            header = f'{icon} <b>Операция завершена</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                      callback_data='neofit:main')],
            ])

        body = header
        if text.strip():
            tail = '\n'.join(text.strip().split('\n')[-20:])
            if len(tail) > 1800:
                tail = '\u2026' + tail[-1800:]
            body += f'\n\n<pre>{_esc(tail)}</pre>'
            body += '\n\n<i>Полный лог: /opt/var/log/router_bot.log</i>'

        if rc == 0 and was_uninstall:
            try:
                leftovers = scan_leftovers(SCAN_PATTERNS)
            except Exception:
                leftovers = []
            if leftovers:
                self._leftovers = leftovers
                body += f'\n\n\U0001f50d <b>Найдено {len(leftovers)} остатков.</b>'
                kb = InlineKeyboardMarkup([
                    [InlineKeyboardButton(
                        f'\U0001f5d1 Удалить все ({len(leftovers)})',
                        callback_data='neofit:cleanup:all')],
                    [InlineKeyboardButton('\u2705 Оставить',
                                          callback_data='neofit:main')],
                ])

        if self._status_msg_id:
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id,
                    message_id=self._status_msg_id,
                    text=body,
                    parse_mode='HTML',
                    reply_markup=kb,
                )
                self._status_msg_id = None
                return
            except Exception as e:
                log.debug('final edit failed: %s', e)
                self._status_msg_id = None

        msg = await ctx.bot.send_message(            chat_id=self.chat_id, text=body,
            parse_mode='HTML', reply_markup=kb,
        )

        set_last_msg(self.chat_id, msg.message_id)

    # ================= меню удаления =================

    async def _show_uninstall_menu(self, q, ctx):
        targets = existing_targets(UNINSTALL_TARGETS)
        self._uninstall_opts = sync_opts(targets, self._uninstall_opts)
        text, kb = build_uninstall_menu(
            targets, self._uninstall_opts,
            title='Удаление NeoFit',
            always_msg='Пакет <code>neofit</code> удаляется всегда.',
            prefix='neofit',
        )
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise

    async def _handle_opt(self, q, ctx, key):
        if key in self._uninstall_opts:
            toggle_opt(self._uninstall_opts, key)
            state = 'вкл' if self._uninstall_opts[key] else 'выкл'
            await q.answer(f'{state}: {key}')
            await self._show_uninstall_menu(q, ctx)
            return

        if key == 'go':
            await q.answer()
            targets = existing_targets(UNINSTALL_TARGETS)
            cmd = collect_uninstall_cmd(targets, self._uninstall_opts, UNINSTALL_CMD)
            self._uninstall_opts = {}
            self._buf = b''
            self._last_edit = 0.0
            self._running = True
            self._last_action = 'uninstall'
            self._status_msg_id = await ui_edit_q(
                q,
                '\U0001f5d1 <b>Удаление NeoFit</b>\n\n<pre>запуск...</pre>',
                kb=InlineKeyboardMarkup([
                    [InlineKeyboardButton('\U0001f6d1 Отменить', callback_data='neofit:kill')],
                ]),
            )
            pid, master = pty.fork()
            if pid == 0:
                try:
                    os.environ['TERM'] = 'dumb'
                    os.execv('/bin/sh', ['sh', '-c', cmd])
                except Exception:
                    os._exit(1)
            self._proc_pid = pid
            self._master = master
            asyncio.create_task(self._reader_loop(ctx, pid, master))
            return

        await q.answer()

    # ================= удаление остатков =================

    async def _check_leftovers(self, ctx):
        try:
            leftovers = scan_leftovers(SCAN_PATTERNS)
        except Exception as e:
            log.debug('scan_leftovers failed: %s', e)
            return
        if not leftovers:
            return
        self._leftovers = leftovers
        text, kb = build_leftovers_message(leftovers, prefix='neofit')
        try:
            await ctx.bot.send_message(
                chat_id=self.chat_id, text=text,
                parse_mode='HTML', reply_markup=kb,
            )
        except Exception as e:
            log.warning('send leftovers failed: %s', e)

    async def _do_cleanup(self, q, ctx):
        if not getattr(self, '_leftovers', None):
            await q.answer('Нечего удалять', show_alert=True)
            return
        parts = []
        total = len(self._leftovers)
        for p in self._leftovers:
            safe = p.replace("'", "'\\''")
            parts.append(f"echo 'Удаляю: {safe}' ; rm -rf '{safe}'")
        parts.append(f"echo '' ; echo 'Готово: удалено {total} элементов'")
        cmd = ' ; '.join(parts)
        self._leftovers = []
        self._buf = b''
        self._last_edit = 0.0
        self._running = True
        self._last_action = 'cleanup'
        self._status_msg_id = await ui_edit_q(
                q,
                '\U0001f5d1 <b>Удаление остатков NeoFit</b>\n\n<pre>запуск...</pre>',
                kb=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить', callback_data='neofit:kill')],
            ]),
            )
        pid, master = pty.fork()
        if pid == 0:
            try:
                os.environ['TERM'] = 'dumb'
                os.execv('/bin/sh', ['sh', '-c', cmd])
            except Exception:
                os._exit(1)
        self._proc_pid = pid
        self._master = master
        asyncio.create_task(self._reader_loop(ctx, pid, master))
RB_MODULES_NEOFIT_MODULE_PY_EOF

echo "  → modules/neofit/actions.py"
cat > /opt/router_bot/modules/neofit/actions.py << 'RB_MODULES_NEOFIT_ACTIONS_PY_EOF'
"""Действия модуля NeoFit."""
import os
import subprocess

# --- Установка / удаление ---
INSTALL_CMD = (
    'opkg update && '
    'opkg install curl wget-ssl ca-certificates && '
    'ARCH=$(grep "^arch=" /opt/etc/entware_release | cut -d= -f2) && '
    'case "$ARCH" in '
    'aarch64) URL="aarch64-k3.10";; '
    'mipsel) URL="mipselsf-k3.4";; '
    'mips) URL="mipssf-k3.4";; '
    '*) URL="mipselsf-k3.4";; '
    'esac && '
    'mkdir -p /opt/etc/opkg && '
    'echo "src/gz neofit https://pegakmop.github.io/release/keenetic/$URL" > /opt/etc/opkg/neofit.conf && '
    'opkg update && '
    'opkg install neofit'
)

UNINSTALL_CMD = (
    'opkg remove --force-removal-of-dependent-packages '
    '--autoremove neofit 2>&1 || true'
)

# --- Управление сервисом (через init-скрипт) ---
NEOFIT_INIT     = '/opt/etc/init.d/S69neofit'
# start-stop-daemon -b отвязывает демон от pty (делает setsid), иначе он падает по SIGHUP
SERVICE_START   = f'/opt/sbin/start-stop-daemon -S -b -x {NEOFIT_INIT} -- start 2>&1; sleep 2; {NEOFIT_INIT} status 2>&1'
SERVICE_STOP    = f'{NEOFIT_INIT} stop    2>&1'
SERVICE_RESTART = f'{NEOFIT_INIT} stop 2>&1; sleep 1; /opt/sbin/start-stop-daemon -S -b -x {NEOFIT_INIT} -- start 2>&1; sleep 2; {NEOFIT_INIT} status 2>&1'
SERVICE_STATUS  = f'{NEOFIT_INIT} status  2>&1'

# --- Диагностика ---
CMD_VERSION = 'neofit --version 2>&1 || nf --version 2>&1'
CMD_INFO    = 'nf status 2>&1'
CMD_LOGS    = 'tail -n 60 /opt/var/log/neofit.log 2>/dev/null || tail -n 60 /opt/var/log/neofit/*.log 2>/dev/null || (ndmc -c "show log" 2>/dev/null | grep -i neofit | tail -n 60) || echo "Логи не найдены."'

# Пути
NEOFIT_BIN     = '/opt/sbin/neofit'
NEOFIT_BIN_ALT = '/opt/bin/neofit'
NEOFIT_INIT    = '/opt/etc/init.d/S99neofit'
NEOFIT_CONF_DIR = '/opt/etc/neofit'
NEOFIT_LOG     = '/opt/var/log/neofit.log'
NEOFIT_WEB_PORT = 92

def get_router_ip() -> str:
    try:
        r = subprocess.run(
            ['sh', '-c',
             "ip -4 addr show br0 2>/dev/null | "
             "grep -oE 'inet [0-9.]+' | head -1 | awk '{print $2}'"],
            capture_output=True, text=True, timeout=3)
        ip = (r.stdout or '').strip()
        if ip and not ip.startswith('127.'):
            return ip
    except Exception:
        pass
    import socket as _s
    s = _s.socket(_s.AF_INET, _s.SOCK_DGRAM)
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

def get_neofit_web_url() -> str:
    return f'http://{get_router_ip()}:{NEOFIT_WEB_PORT}'


def find_bin() -> str:
    for p in (NEOFIT_BIN, NEOFIT_BIN_ALT, '/opt/bin/nf', '/opt/sbin/nf'):
        if os.path.exists(p):
            return p
    try:
        r = subprocess.run(
            ['sh', '-c', 'command -v neofit 2>/dev/null || command -v nf 2>/dev/null'],
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
    return os.path.exists('/opt/etc/init.d/S69neofit') or bool(find_bin())


def is_running() -> bool:
    # 1. Самый надежный способ — pidof
    try:
        r = subprocess.run(['pidof', 'neofit'], capture_output=True, timeout=3)
        if r.returncode == 0:
            return True
    except Exception:
        pass
    # 2. Через процесс (fallback)
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
    'show_config': {
        'title': 'Показать конфиг',
        'icon': '\U0001f4c4',
        'desc': 'Содержимое каталога /opt/etc/neofit/',
        'cmd': 'ls -la /opt/etc/neofit/ 2>&1',
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
RB_MODULES_NEOFIT_ACTIONS_PY_EOF

echo "  → modules/usque_keenetic/__init__.py"
cat > /opt/router_bot/modules/usque_keenetic/__init__.py << 'RB_MODULES_USQUE_KEENETIC___INIT___PY_EOF'

RB_MODULES_USQUE_KEENETIC___INIT___PY_EOF

echo "  → modules/usque_keenetic/module.py"
cat > /opt/router_bot/modules/usque_keenetic/module.py << 'RB_MODULES_USQUE_KEENETIC_MODULE_PY_EOF'
"""Модуль usque-keenetic — Cloudflare WARP (MASQUE) для Keenetic."""
import asyncio, html, logging, os, pty, re, time
from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import (
    ContextTypes, MessageHandler, filters,
)

from .actions import (
    ACTIONS, UNINSTALL_CMD, UNINSTALL_TARGETS, SCAN_PATTERNS, USQUE_CONF,
    is_installed, is_running, get_version, get_status_short,
)
from core.utils import (
    existing_targets, sync_opts, build_uninstall_menu,
    collect_uninstall_cmd, toggle_opt,
    scan_leftovers, build_leftovers_message,
    ui_edit_q, ui_edit_or_send,
    show_card,
    show_card,
    ui_edit_q,
)
from core.utils import set_last_msg

log = logging.getLogger(__name__)


def _esc(s): return html.escape(s or '')
def _strip_ansi(s):
    s = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', s)
    s = re.sub(r'\x1b\][^\x07]*\x07', '', s)
    return re.sub(r'\x1b[=>]', '', s)


class UsqueKeeneticModule:
    name = 'usque_keenetic'
    title = 'Usque WARP'
    icon = '\u2601\ufe0f'
    description = 'Cloudflare WARP (MASQUE)'
    category = 'services'
    category_title = 'Сервис'
    category_icon = '\U0001f6e0'
    conflicts_with = {
        'keen_pbr':   'пересечение policy-routing и nftables-меток',
        'xkeen':      'оба занимают туннели/маршрутизацию',
        'hydraroute': 'пересечение маршрутизации доменов',
    }
    commands = [('usque', '☁️ Usque WARP')]
    cleanup_paths = [
        '/opt/bin/usque',
        '/opt/sbin/usque',
        '/opt/etc/usque',
        '/opt/etc/opkg/usque-keenetic.conf',
        '/opt/var/log/usque*',
    ]
    cleanup_init = ['S51usque']

    def __init__(self, chat_id):
        self.chat_id = str(chat_id)
        self._proc_pid = None
        self._master = None
        self._running = False
        self._status_msg_id = None
        self._buf = b''
        self._last_edit = 0.0
        self._last_action = None
        self._uninstall_opts = {}
        self._leftovers = []
        self._editing = False

    async def startup(self, app):
        app.add_handler(MessageHandler(
            filters.TEXT & ~filters.COMMAND,
            self._handle_text,
        ))
        log.info('Usque-keenetic module started')

    async def on_leave(self):
        self._kill()
        self._editing = False

    def _kill(self):
        import signal
        pid = getattr(self, '_proc_pid', None)
        if pid:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(os.getpgid(pid), sig)
                except ProcessLookupError:
                    break
                except Exception:
                    try: os.kill(pid, sig)
                    except Exception: pass
                time.sleep(0.4)
            try: os.waitpid(pid, os.WNOHANG)
            except Exception: pass
            self._proc_pid = None
        if self._master is not None:
            try: os.close(self._master)
            except Exception: pass
            self._master = None
        self._running = False

    def get_installed(self): return is_installed()
    def get_status_short(self): return get_status_short()

    def _build_card(self):
        installed = is_installed()
        running = is_running()
        version = get_version() if installed else ''
        lines = [f'{self.icon} <b>{self.title}</b>', '']
        if installed:
            v = f' · <code>{version}</code>' if version else ''
            lines.append(f'✅ Установлен{v}')
            lines.append('Сервис: ' + ('🟢 работает' if running else '🔴 остановлен'))
            if os.path.exists(USQUE_CONF):
                lines.append(f'Конфиг: <code>{_esc(USQUE_CONF)}</code>')
        else:
            lines.append('❌ Не установлен')
            import subprocess as _sp
            def _proc_running(pname):
                try:
                    _r = _sp.run(['sh', '-c', f'ps w | grep -q "[{pname[0]}]{pname[1:]}" && echo yes'], capture_output=True, text=True, timeout=3)
                    return 'yes' in (_r.stdout or '')
                except Exception: return False
            for proc, name in [('keen-pbr', 'Keen-PBR'),
                               ('xkeen', 'XKeen'),
                               ('hrneo', 'HydraRoute')]:
                if _proc_running(proc):
                    lines.append('')
                    lines.append(f'⚠️ <b>Конфликт с {name}</b>')
                    lines.append(f'<i>Удалите {name} перед установкой.</i>')
        lines.append('')

        if self._running:
            lines.append('⏳ <b>Выполняется операция...</b>')
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='usque_keenetic:kill')],
                [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                      callback_data='router:cat:services'),
                 InlineKeyboardButton('\U0001f3e0 Модули',
                                      callback_data='router:main')],
            ])
            return '\n'.join(lines), kb

        rows = []
        if not installed:
            rows.append([InlineKeyboardButton(
                '\u2b07\ufe0f Установить usque-keenetic',
                callback_data='usque_keenetic:ask:install')])
        else:
            if running:
                rows.append([
                    InlineKeyboardButton('\u23f9 Остановить',
                                         callback_data='usque_keenetic:ask:stop'),
                    InlineKeyboardButton('\U0001f504 Перезапустить',
                                         callback_data='usque_keenetic:ask:restart'),
                ])
            else:
                rows.append([InlineKeyboardButton(
                    '\u25b6\ufe0f Запустить',
                    callback_data='usque_keenetic:ask:start')])
            rows.append([
                InlineKeyboardButton('\U0001f4ca Статус',
                                     callback_data='usque_keenetic:ask:status'),
                InlineKeyboardButton('\U0001f4c4 Версия',
                                     callback_data='usque_keenetic:ask:version'),
            ])
            rows.append([
                InlineKeyboardButton('\U0001f4c4 Показать конфиг',
                                     callback_data='usque_keenetic:show_config'),
                InlineKeyboardButton('\U0001f4dc Логи',
                                     callback_data='usque_keenetic:ask:logs'),
            ])
            rows.append([InlineKeyboardButton(
                '\U0001f5d1 Удалить usque-keenetic',
                callback_data='usque_keenetic:ask:uninstall')])
        rows.append([InlineKeyboardButton(
            '\U0001f504 Обновить карточку',
            callback_data='usque_keenetic:main')])
        rows.append([
            InlineKeyboardButton('\u2b05\ufe0f Назад',
                                 callback_data='router:cat:services'),
            InlineKeyboardButton('\U0001f3e0 Модули',
                                 callback_data='router:main'),
        ])
        return '\n'.join(lines), InlineKeyboardMarkup(rows)

    async def send_card_message(self, update, ctx):
        text, kb = self._build_card()
        await show_card(update, ctx, text, kb=kb)

    async def handle_callback(self, action, q, ctx):
        if action == 'main':
            await q.answer()
            text, kb = self._build_card()
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower(): raise
            return
        if action == 'kill':
            await q.answer('Прерываю...')
            self._kill()
            try:
                await q.edit_message_text(
                    '\U0001f6d1 Операция прервана.',
                    reply_markup=InlineKeyboardMarkup([
                        [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                              callback_data='usque_keenetic:main')],
                    ]),
                )
            except Exception: pass
            return
        if action == 'cleanup:all':
            await q.answer()
            return await self._do_cleanup(q, ctx)
        if action == 'show_config':
            await q.answer()
            return await self._show_config(q, ctx)
        if action == 'edit_config':
            await q.answer()
            return await self._ask_new_config(q, ctx)
        if action == 'ask:uninstall':
            await q.answer()
            return await self._show_uninstall_menu(q, ctx)
        if action.startswith('opt:'):
            return await self._handle_opt(q, ctx, action[4:])
        if action.startswith('ask:'):
            key = action[4:]
            await q.answer()
            a = ACTIONS.get(key)
            if not a:
                await q.answer('Неизвестное действие', show_alert=True)
                return
            desc = a['desc']
            if key == 'install':
                import subprocess as _sp
                def _proc_run(p):
                    try:
                        _r = _sp.run(['sh', '-c', f'ps w | grep -q "[{p[0]}]{p[1:]}" && echo yes'], capture_output=True, text=True, timeout=3)
                        return 'yes' in (_r.stdout or '')
                    except Exception: return False
                warns = []
                if _proc_run('keen-pbr'): warns.append('Keen-PBR')
                if _proc_run('xkeen'): warns.append('XKeen')
                if _proc_run('hrneo'): warns.append('HydraRoute')
                if warns:
                    desc += f'\n\n⚠️ <b>Внимание:</b> сейчас запущен { " и ".join(warns) }. Это может вызвать конфликт.'
            text = (f'{a["icon"]} <b>{a["title"]}</b>\n\n'
                    f'{desc}\n\nПодтвердить?')
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2705 Подтвердить',
                                      callback_data=f'usque_keenetic:go:{key}')],
                [InlineKeyboardButton('\u274c Отмена',
                                      callback_data='usque_keenetic:main')],
            ])
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower(): raise
            return
        if action.startswith('go:'):
            key = action[3:]
            await q.answer()
            a = ACTIONS.get(key)
            if a:
                await self._start_action(q, ctx, key, a)
            return
        await q.answer()

    async def _start_action(self, q, ctx, key, action):
        if self._running:
            return
        self._running = True
        self._last_action = key
        self._buf = b''
        self._last_edit = 0.0
        self._awaiting_yn = False

        self._status_msg_id = await ui_edit_q(
            q,
            f'{action["icon"]} <b>{action["title"]}</b>\n\n<pre>запуск...</pre>',
            kb=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='usque_keenetic:kill')],
            ]),
        )

        pid, master = pty.fork()
        if pid == 0:
            try:
                os.environ['TERM'] = 'dumb'
                os.environ['DEBIAN_FRONTEND'] = 'noninteractive'
                os.execv('/bin/sh', ['sh', '-c', action['cmd']])
            except Exception:
                os._exit(1)
        self._proc_pid = pid
        self._master = master
        asyncio.create_task(self._reader_loop(ctx, pid, master))

    def _drain_master(self, master):
        import select as _select
        extra = b''
        try:
            while True:
                r, _, _ = _select.select([master], [], [], 0.3)
                if not r: break
                try: data = os.read(master, 4096)
                except (BlockingIOError, OSError): break
                if not data: break
                extra += data
        except Exception as e: log.debug('drain_master: %s', e)
        return extra

    async def _reader_loop(self, ctx, pid, master):
        try:
            import fcntl
            fcntl.fcntl(master, fcntl.F_SETFL, os.O_NONBLOCK)
        except Exception as e: log.warning('nonblock failed: %s', e)
        idle_start = time.time()
        start_time = time.time()
        timeout_total = 180
        try:
            while True:
                if time.time() - start_time > timeout_total:
                    log.warning('Timeout %ss, killing process', timeout_total)
                    try:
                        os.kill(pid, 9)
                    except Exception:
                        pass
                    self._buf += b'\n[!] Timeout: process killed\n'
                    break
                try:
                    wpid, _ws = os.waitpid(pid, os.WNOHANG)
                    if wpid == pid:
                        self._buf += self._drain_master(master); break
                except ChildProcessError:
                    self._buf += self._drain_master(master); break
                except Exception: pass
                try:
                    data = os.read(master, 4096)
                    idle_start = time.time()
                except BlockingIOError:
                    if time.time() - idle_start > 2.0:
                        try:
                            wpid, _ws = os.waitpid(pid, os.WNOHANG)
                            if wpid == pid:
                                self._buf += self._drain_master(master); break
                        except Exception: pass
                    await asyncio.sleep(0.15); continue
                except OSError: break
                if not data: break
                self._buf += data
                if len(self._buf) > 60000: self._buf = self._buf[-50000:]
                now = time.time()
                if now - self._last_edit >= 1.2:
                    self._last_edit = now
                    await self._update_status(ctx)
        finally:
            try: os.close(master)
            except Exception: pass
            self._master = None
        try:
            _, status = os.waitpid(pid, 0)
            rc = os.waitstatus_to_exitcode(status)
        except ChildProcessError: rc = 0
        except Exception: rc = -1
        self._proc_pid = None
        await self._finish(ctx, self._buf, rc)

    async def _update_status(self, ctx=None, bot=None):
        if bot is None and ctx is not None:
            bot = ctx.bot
        if bot is None or not self._status_msg_id:
            return
        text = _strip_ansi(self._buf.decode('utf-8', errors='replace'))
        tail = text[-1800:] if len(text) > 1800 else text
        try:
            await bot.edit_message_text(
                chat_id=self.chat_id,
                message_id=self._status_msg_id,
                text=f'\u23f3 <b>Выполняется...</b>\n\n<pre>{_esc(tail)}</pre>',
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton('\U0001f6d1 Отменить',
                                          callback_data='usque_keenetic:kill')],
                ]),
            )
        except Exception as e:
            if 'not modified' not in str(e).lower():
                log.debug('update_status: %s', e)

    async def _finish(self, ctx, buf, rc):
        self._running = False
        self._awaiting_yn = False
        was_uninstall = (self._last_action == 'uninstall')
        was_cleanup = (self._last_action == 'cleanup')
        text = _strip_ansi(buf.decode('utf-8', errors='replace'))

        if rc == 0 and 'Collected errors' in text:
            new_lines, skip = [], False
            for ln in text.split('\n'):
                if 'Collected errors' in ln:
                    skip = True
                    continue
                if skip:
                    if ln.strip().startswith('*'):
                        if 'is not installed' in ln:
                            continue
                        new_lines.append(ln)
                        continue
                    else:
                        skip = False
                new_lines.append(ln)
            text = '\n'.join(new_lines).strip()

        offer_start = (
            self._last_action == 'install'
            and rc == 0
            and (is_installed())
            and not (is_running())
        )
        self._last_action = None
        icon = '\u2705' if rc == 0 else '\u274c'

        if offer_start:
            header = (f'{icon} <b>Установка завершена</b>\n'
                      f'<i>exit code: {rc}</i>')
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u25b6\ufe0f Запустить сейчас',
                                      callback_data='usque_keenetic:ask:start')],
                [InlineKeyboardButton('\u23ed Позже',
                                      callback_data='usque_keenetic:main')],
            ])
        elif was_cleanup:
            header = f'{icon} <b>Остатки удалены</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                      callback_data='usque_keenetic:main')],
            ])
        else:
            header = f'{icon} <b>Операция завершена</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                      callback_data='usque_keenetic:main')],
            ])

        body = header
        if text.strip():
            tail = '\n'.join(text.strip().split('\n')[-20:])
            if len(tail) > 1800:
                tail = '\u2026' + tail[-1800:]
            body += f'\n\n<pre>{_esc(tail)}</pre>'
            body += '\n\n<i>Полный лог: /opt/var/log/router_bot.log</i>'

        if rc == 0 and was_uninstall:
            try:
                leftovers = scan_leftovers(SCAN_PATTERNS)
            except Exception:
                leftovers = []
            if leftovers:
                self._leftovers = leftovers
                body += f'\n\n\U0001f50d <b>Найдено {len(leftovers)} остатков.</b>'
                kb = InlineKeyboardMarkup([
                    [InlineKeyboardButton(
                        f'\U0001f5d1 Удалить все ({len(leftovers)})',
                        callback_data='usque_keenetic:cleanup:all')],
                    [InlineKeyboardButton('\u2705 Оставить',
                                          callback_data='usque_keenetic:main')],
                ])

        if self._status_msg_id:
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id,
                    message_id=self._status_msg_id,
                    text=body,
                    parse_mode='HTML',
                    reply_markup=kb,
                )
                self._status_msg_id = None
                return
            except Exception as e:
                log.debug('final edit failed: %s', e)
                self._status_msg_id = None

        msg = await ctx.bot.send_message(            chat_id=self.chat_id, text=body,
            parse_mode='HTML', reply_markup=kb,
        )

        set_last_msg(self.chat_id, msg.message_id)

    async def _show_uninstall_menu(self, q, ctx):
        targets = existing_targets(UNINSTALL_TARGETS)
        self._uninstall_opts = sync_opts(targets, self._uninstall_opts)
        text, kb = build_uninstall_menu(
            targets, self._uninstall_opts,
            title='Удаление usque-keenetic',
            always_msg='Пакет <code>usque-keenetic</code> удаляется всегда.',
            prefix='usque_keenetic',
        )
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower(): raise

    async def _handle_opt(self, q, ctx, key):
        if key in self._uninstall_opts:
            toggle_opt(self._uninstall_opts, key)
            state = 'вкл' if self._uninstall_opts[key] else 'выкл'
            await q.answer(f'{state}: {key}')
            await self._show_uninstall_menu(q, ctx)
            return
        if key == 'go':
            await q.answer()
            targets = existing_targets(UNINSTALL_TARGETS)
            cmd = collect_uninstall_cmd(targets, self._uninstall_opts, UNINSTALL_CMD)
            self._uninstall_opts = {}
            self._buf = b''; self._last_edit = 0.0
            self._running = True; self._last_action = 'uninstall'
            self._status_msg_id = await ui_edit_q(
                q,
                '\U0001f5d1 <b>Удаление usque-keenetic</b>\n\n<pre>запуск...</pre>',
                kb=InlineKeyboardMarkup([
                    [InlineKeyboardButton('\U0001f6d1 Отменить',
                                          callback_data='usque_keenetic:kill')],
                ]),
            )
            pid, master = pty.fork()
            if pid == 0:
                try:
                    os.environ['TERM'] = 'dumb'
                    os.execv('/bin/sh', ['sh', '-c', cmd])
                except Exception: os._exit(1)
            self._proc_pid = pid; self._master = master
            asyncio.create_task(self._reader_loop(ctx, pid, master))
            return
        await q.answer()

    async def _show_config(self, q, ctx):
        cfg_path = '/opt/etc/usque/usque.conf'
        try:
            if os.path.exists(cfg_path):
                with open(cfg_path) as f:
                    content = f.read()
            else:
                content = f'(файл {cfg_path} не найден)'
        except Exception as e:
            content = f'(ошибка чтения: {e})'
        if len(content) > 3000:
            content = content[:3000] + '\n... (сокращено)'
        text = (
            f'\U0001f4c4 <b>Конфиг Usque WARP</b>\n'
            f'<code>{cfg_path}</code>\n\n'
            f'<pre>{_esc(content)}</pre>'
        )
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('\u270f\ufe0f Прислать новый конфиг',
                                  callback_data='usque_keenetic:edit_config')],
            [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                  callback_data='usque_keenetic:main')],
        ])
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise


    async def _ask_new_config(self, q, ctx):
        self._editing = True
        text = (
            '\u270f\ufe0f <b>Пришлите новый конфиг</b>\n\n'
            f'Следующим сообщением отправьте полный текст файла\n'
            f'<code>{USQUE_CONF}</code>.\n\n'
            '\u26a0\ufe0f Текущий конфиг будет сохранён в <code>.bak</code>.\n'
            'После записи перезапустите сервис для применения.'
        )
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('\u274c Отмена',
                                  callback_data='usque_keenetic:main')],
        ])
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise

    async def _handle_text(self, update, ctx):
        if str(update.effective_chat.id) != self.chat_id:
            return
        if not self._editing:
            return
        text = update.message.text or ''
        if not text.strip():
            return
        try:
            import shutil
            if os.path.exists(USQUE_CONF):
                shutil.copy(USQUE_CONF, USQUE_CONF + '.bak')
            os.makedirs(os.path.dirname(USQUE_CONF), exist_ok=True)
            with open(USQUE_CONF, 'w') as f:
                f.write(text)
            self._editing = False
            await update.message.reply_text(
                f'\u2705 Конфиг сохранён.\n'
                f'Резервная копия: <code>{USQUE_CONF}.bak</code>\n\n'
                f'Перезапустите сервис для применения.',
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton(
                        '\U0001f504 Перезапустить',
                        callback_data='usque_keenetic:ask:restart')],
                    [InlineKeyboardButton(
                        '\u2b05\ufe0f Назад',
                        callback_data='usque_keenetic:main')],
                ]),
            )
        except Exception as e:
            self._editing = False
            log.exception('save config failed: %s', e)
            await update.message.reply_text(
                f'\u274c Не удалось сохранить: {e}')

    async def _check_leftovers(self, ctx):
        try: leftovers = scan_leftovers(SCAN_PATTERNS)
        except Exception as e:
            log.debug('scan_leftovers failed: %s', e); return
        if not leftovers: return
        self._leftovers = leftovers
        text, kb = build_leftovers_message(leftovers, prefix='usque_keenetic')
        try:
            await ctx.bot.send_message(chat_id=self.chat_id, text=text,
                                       parse_mode='HTML', reply_markup=kb)
        except Exception as e: log.warning('send leftovers failed: %s', e)

    async def _do_cleanup(self, q, ctx):
        if not getattr(self, '_leftovers', None):
            await q.answer('Нечего удалять', show_alert=True); return
        parts = []
        total = len(self._leftovers)
        for p in self._leftovers:
            safe = p.replace("'", "'\\''")
            parts.append(f"echo 'Удаляю: {safe}' ; rm -rf '{safe}'")
        parts.append(f"echo '' ; echo 'Готово: удалено {total} элементов'")
        cmd = ' ; '.join(parts)
        self._leftovers = []
        self._buf = b''; self._last_edit = 0.0
        self._running = True; self._last_action = 'cleanup'
        self._status_msg_id = await ui_edit_q(
                q,
                '\U0001f5d1 <b>Удаление остатков usque</b>\n\n<pre>запуск...</pre>',
                kb=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='usque_keenetic:kill')],
            ]),
            )
        pid, master = pty.fork()
        if pid == 0:
            try:
                os.environ['TERM'] = 'dumb'
                os.execv('/bin/sh', ['sh', '-c', cmd])
            except Exception: os._exit(1)
        self._proc_pid = pid; self._master = master
        asyncio.create_task(self._reader_loop(ctx, pid, master))
RB_MODULES_USQUE_KEENETIC_MODULE_PY_EOF

echo "  → modules/usque_keenetic/actions.py"
cat > /opt/router_bot/modules/usque_keenetic/actions.py << 'RB_MODULES_USQUE_KEENETIC_ACTIONS_PY_EOF'
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
            '⚠️ Требует Keenetic OS >= 5.0.'
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
RB_MODULES_USQUE_KEENETIC_ACTIONS_PY_EOF

mkdir -p /opt/router_bot/modules/awg_manager /opt/router_bot/data/awg_manager
mkdir -p /opt/router_bot/modules/awg_manager /opt/router_bot/data/awg_manager
echo "  → modules/awg_manager/__init__.py"
cat > /opt/router_bot/modules/awg_manager/__init__.py << 'RB_MODULES_AWG___INIT___PY_EOF'

RB_MODULES_AWG___INIT___PY_EOF

echo "  → modules/awg_manager/actions.py"
cat > /opt/router_bot/modules/awg_manager/actions.py << 'RB_MODULES_AWG_ACTIONS_PY_EOF'
"""Действия модуля AWG Manager (AmneziaWG / Sing-box)."""
import json
import os
import subprocess

MCP_URL = 'http://127.0.0.1:2222/mcp'
WEB_PORT = 2222

INIT_SCRIPT = '/opt/etc/init.d/S99awg-manager'
BIN_PATH = '/opt/bin/awg-manager'
CONF_DIR = '/opt/etc/awg-manager'
LOG_FILE = '/opt/var/log/awg-manager.log'

AWG_REPO_URL  = 'http://repo.hoaxisr.ru/mipsel-k3.4'
AWG_REPO_CONF = '/opt/etc/opkg/awg_manager.conf'

INSTALL_CMD = (
    'mkdir -p /opt/etc/opkg && '
    'if ! grep -q repo.hoaxisr.ru ' + AWG_REPO_CONF + ' 2>/dev/null; then '
    'printf "src/gz hoaxisr %s\\n" ' + AWG_REPO_URL + ' > ' + AWG_REPO_CONF + '; '
    'fi && '
    'opkg update && '
    'opkg install awg-manager'
)

UNINSTALL_CMD = (
    'opkg remove --force-removal-of-dependent-packages '
    '--autoremove awg-manager 2>&1 || true'
)

SERVICE_START   = f'/opt/sbin/start-stop-daemon -S -b -x {INIT_SCRIPT} -- start 2>&1; sleep 2; {INIT_SCRIPT} status 2>&1'
SERVICE_STOP    = f'{INIT_SCRIPT} stop 2>&1'
SERVICE_RESTART = f'{INIT_SCRIPT} stop 2>&1; sleep 1; /opt/sbin/start-stop-daemon -S -b -x {INIT_SCRIPT} -- start 2>&1; sleep 2; {INIT_SCRIPT} status 2>&1'
SERVICE_STATUS  = f'{INIT_SCRIPT} status 2>&1'

CMD_VERSION = 'opkg list-installed 2>/dev/null | grep "^awg-manager "'
CMD_LOGS = 'tail -n 60 /opt/var/log/awg-manager.log 2>/dev/null || (ndmc -c "show log" 2>/dev/null | grep -i awg-manager | tail -n 60) || echo "Логи пусты"'


def is_installed() -> bool:
    try:
        r = subprocess.run(
            ['sh', '-c', 'opkg list-installed 2>/dev/null | grep -q "^awg-manager "'],
            timeout=5,
        )
        if r.returncode == 0:
            return True
    except Exception:
        pass
    return os.path.exists(INIT_SCRIPT) or os.path.exists(BIN_PATH)


def is_running() -> bool:
    try:
        r = subprocess.run(
            ['sh', '-c', 'ps w | grep -E "[a]wg-manager" | grep -v grep | wc -l'],
            capture_output=True, text=True, timeout=5,
        )
        return int((r.stdout or '0').strip()) > 0
    except Exception:
        return False


def get_version() -> str:
    try:
        r = subprocess.run(
            ['sh', '-c', CMD_VERSION],
            capture_output=True, text=True, timeout=5,
        )
        for line in (r.stdout or '').splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[0] == 'awg-manager':
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


def get_router_ip() -> str:
    from core.utils import get_router_ip as _g
    return _g()


def get_awg_web_url() -> str:
    return f'http://{get_router_ip()}:{WEB_PORT}'


def get_mcp_token() -> str:
    from core.config import get as cfg
    return cfg('AWG_MCP_TOKEN', '')


# --- Действия для UI ---
ACTIONS = {
    'install': {
        'title': 'Установка AWG Manager',
        'icon': '⬇️',
        'desc': (
            'Установит AWG Manager — веб-панель и MCP-сервер '
            'для управления туннелями AmneziaWG и Sing-box.\n\n'
            'Web UI: <code>http://&lt;router-ip&gt;:2222</code>'
        ),
        'cmd': INSTALL_CMD,
    },
    'uninstall': {
        'title': 'Удаление AWG Manager',
        'icon': '🗑',
        'desc': (
            'Будет удалён пакет <code>awg-manager</code>.\n\n'
            '⚠️ Конфиги в <code>/opt/etc/awg-manager/</code> останутся.'
        ),
        'cmd': UNINSTALL_CMD,
        'danger': True,
    },
    'start':    {'title': 'Запуск',    'icon': '▶️', 'desc': 'Команда: <code>S99awg-manager start</code>', 'cmd': SERVICE_START},
    'stop':     {'title': 'Остановка', 'icon': '⏹', 'desc': 'Команда: <code>S99awg-manager stop</code>',  'cmd': SERVICE_STOP},
    'restart':  {'title': 'Перезапуск', 'icon': '🔄', 'desc': 'Команда: <code>S99awg-manager restart</code>', 'cmd': SERVICE_RESTART},
    'status':   {'title': 'Статус',    'icon': '📊', 'desc': 'Команда: <code>S99awg-manager status</code>', 'cmd': SERVICE_STATUS},
    'version':  {'title': 'Версия',    'icon': '📄', 'desc': 'Версия пакета awg-manager', 'cmd': CMD_VERSION},
    'logs':     {'title': 'Логи',      'icon': '📜', 'desc': 'Последние 60 строк лога', 'cmd': CMD_LOGS},
}


# ================= Описание целей удаления =================

UNINSTALL_TARGETS = [
    {
        'key': 'bin',
        'desc': 'Бинарник awg-manager',
        'paths': ['/opt/bin/awg-manager', '/opt/sbin/awg-manager'],
        'cmd': 'rm -f /opt/bin/awg-manager /opt/sbin/awg-manager',
    },
    {
        'key': 'init',
        'desc': 'Init-скрипт S99awg-manager',
        'paths': ['/opt/etc/init.d/S99awg-manager'],
        'cmd': 'rm -f /opt/etc/init.d/S99awg-manager',
    },
    {
        'key': 'configs',
        'desc': 'Конфиги /opt/etc/awg-manager',
        'paths': ['/opt/etc/awg-manager'],
        'cmd': 'rm -rf /opt/etc/awg-manager',
    },
    {
        'key': 'logs',
        'desc': 'Логи и runtime',
        'paths': ['/opt/var/log/awg-manager*', '/opt/var/run/awg-manager*'],
        'cmd': 'rm -rf /opt/var/log/awg-manager* /opt/var/run/awg-manager*',
    },
    {
        'key': 'opkg',
        'desc': 'Метаданные opkg',
        'paths': ['/opt/lib/opkg/info/awg-manager*'],
        'cmd': 'rm -rf /opt/lib/opkg/info/awg-manager*',
    },
]

SCAN_PATTERNS = ['*awg-manager*', '*awg_manager*']

CONFIG_PATH = '/opt/router_bot/config.env'

def save_mcp_token(token: str) -> bool:
    """Сохраняет MCP-токен в config.env и обновляет os.environ."""
    import os
    try:
        lines = []
        found = False
        if os.path.exists(CONFIG_PATH):
            with open(CONFIG_PATH) as f:
                for line in f:
                    if line.startswith('AWG_MCP_TOKEN='):
                        lines.append(f"AWG_MCP_TOKEN='{token}'\n")
                        found = True
                    else:
                        lines.append(line)
        if not found:
            lines.append(f"\n# AWG Manager MCP-токен\nAWG_MCP_TOKEN='{token}'\n")
        tmp = CONFIG_PATH + '.tmp'
        with open(tmp, 'w') as f:
            f.writelines(lines)
        os.replace(tmp, CONFIG_PATH)
        os.environ['AWG_MCP_TOKEN'] = token
        return True
    except Exception as e:
        import logging
        logging.getLogger(__name__).warning('save_mcp_token failed: %s', e)
        return False
RB_MODULES_AWG_ACTIONS_PY_EOF

echo "  → modules/awg_manager/module.py"
cat > /opt/router_bot/modules/awg_manager/module.py << 'RB_MODULES_AWG_MODULE_PY_EOF'
"""Модуль AWG Manager — управление AmneziaWG / Sing-box."""
import asyncio
import html
import json
import logging
import urllib.request
import urllib.error

from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import (
    ContextTypes, MessageHandler, filters, ApplicationHandlerStop,
)

from core.utils import (
    existing_targets, sync_opts, build_uninstall_menu,
    collect_uninstall_cmd, toggle_opt,
    scan_leftovers, build_leftovers_message,
    ui_edit_q, ui_edit_or_send,
    show_card, get_last_msg,
)

from .actions import (
    ACTIONS, INSTALL_CMD, UNINSTALL_CMD,
    UNINSTALL_TARGETS, SCAN_PATTERNS,
    is_installed, is_running, get_version, get_status_short,
    get_awg_web_url, get_mcp_token,
    SERVICE_START, SERVICE_STOP, SERVICE_RESTART, SERVICE_STATUS, CMD_LOGS,
    MCP_URL, save_mcp_token,
)

log = logging.getLogger(__name__)



def _esc(s):
    return html.escape(s or '')


def _mcp_call_sync(method: str, params: dict = None) -> dict:
    from .actions import get_mcp_token, MCP_URL
    token = get_mcp_token()
    if not token:
        raise RuntimeError('MCP-токен не задан')
    body = {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params or {}}
    req = urllib.request.Request(
        MCP_URL, data=json.dumps(body).encode('utf-8'),
        headers={
            'Authorization': f'Bearer {token}',
            'Content-Type': 'application/json',
            'Accept': 'application/json, text/event-stream',
        },
        method='POST')
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            raw = r.read().decode('utf-8', errors='replace')
    except urllib.error.HTTPError as e:
        try:
            body_err = e.read().decode('utf-8', errors='replace')[:300]
        except Exception:
            body_err = '(no body)'
        raise RuntimeError(f'MCP HTTP {e.code}: {body_err}')
    for line in raw.splitlines():
        if line.startswith('data: '):
            data = json.loads(line[6:])
            res = data.get('result', {})
            if res.get('isError'):
                raise RuntimeError(res.get('content', [{}])[0].get('text', 'MCP error'))
            sc = res.get('structuredContent')
            if sc is not None: return sc
            return json.loads(res.get('content', [{}])[0].get('text', '{}'))
    raise RuntimeError('Пустой ответ MCP')

async def _mcp_tool(name: str, args: dict = None) -> dict:
    return await asyncio.to_thread(_mcp_call_sync, 'tools/call', {'name': name, 'arguments': args or {}})

class AwgManagerModule:
    name = 'awg_manager'
    title = 'AWG Manager'
    icon = '🛡'
    description = 'AmneziaWG / Sing-box управление'
    category = 'services'
    category_title = 'Сервис'
    category_icon = '🛠'
    conflicts_with = {
        'xkeen': 'оба занимают маршрутизацию и nftables-метки',
        'hydraroute': 'оба используют nftables/iptables для маршрутизации',
        'keen_pbr': 'оба занимают policy-routing и nftables',
        'usque_keenetic': 'оба занимают туннели/маршрутизацию',
    }
    commands = [('awg', '🛡 AWG Manager')]
    cleanup_paths = [
        '/opt/bin/awg-manager',
        '/opt/sbin/awg-manager',
        '/opt/etc/awg-manager',
        '/opt/etc/opkg/awg_manager.conf',
        '/opt/var/log/awg-manager*',
        '/opt/var/run/awg-manager*',
    ]
    cleanup_init = ['S99awg-manager']

    def __init__(self, chat_id):
        self.chat_id = str(chat_id)
        self._awaiting_token = False
        self._uninstall_opts = {}
        self._leftovers = []
        self._status_msg_id = None
        self._running = False

    async def startup(self, app):
        app.add_handler(MessageHandler(
            filters.TEXT & ~filters.COMMAND,
            self._handle_text,
        ), group=-3)
        log.info('AWG Manager module started')

    async def on_leave(self):
        self._awaiting_token = False
        self._uninstall_opts = {}
        self._leftovers = []

    def get_installed(self) -> bool:
        return is_installed()

    def get_status_short(self) -> str:
        return get_status_short()

    # ================= UI =================

    def _build_card(self):
        installed = is_installed()
        running = is_running()
        version = get_version() if installed else ''

        lines = [f'{self.icon} <b>{self.title}</b>', '']
        if installed:
            v = f' · <code>{version}</code>' if version else ''
            lines.append(f'✅ Установлен{v}')
            lines.append('Сервис: ' + ('🟢 работает' if running else '🔴 остановлен'))
            url = get_awg_web_url()
            lines.append(f'Web UI: <a href="{url}">{url}</a>')
            if get_mcp_token():
                lines.append('MCP: <code>токен задан</code>')
            else:
                lines.append('MCP: <i>токен не задан</i>')
        else:
            lines.append('❌ Не установлен')
            warns = []
            if self._proc_check('xray'): warns.append('XKeen/HR (xray)')
            if self._proc_check('keen-pbr'): warns.append('Keen-PBR')
            if self._proc_check('usque'): warns.append('Usque WARP')
            if warns:
                lines.append('')
                lines.append('⚠️ <b>Активные конфликты:</b>')
                for w in warns:
                    lines.append(f'  • {w}')
        lines.append('')

        rows = []
        if not installed:
            rows.append([InlineKeyboardButton(
                '⬇️ Установить AWG Manager',
                callback_data='awg_manager:ask:install')])
        else:
            if running:
                rows.append([
                    InlineKeyboardButton('⏹ Остановить', callback_data='awg_manager:ask:stop'),
                    InlineKeyboardButton('🔄 Перезапустить', callback_data='awg_manager:ask:restart'),
                ])
            else:
                rows.append([InlineKeyboardButton(
                    '▶️ Запустить', callback_data='awg_manager:ask:start')])
            rows.append([
                InlineKeyboardButton('📊 Статус', callback_data='awg_manager:ask:status'),
                InlineKeyboardButton('📜 Логи', callback_data='awg_manager:ask:logs'),
            ])
            if get_mcp_token():
                rows.append([InlineKeyboardButton('🔑 Изменить MCP токен', callback_data='awg_manager:ask:mcp_token')])
            else:
                rows.append([InlineKeyboardButton('🔑 Задать MCP токен', callback_data='awg_manager:ask:mcp_token')])
            rows.append([InlineKeyboardButton(
                '🗑 Удалить AWG Manager',
                callback_data='awg_manager:ask:uninstall')])
        if installed:

            rows.append([InlineKeyboardButton('📊 Dashboard', callback_data='awg_manager:dashboard')])

        rows.append([InlineKeyboardButton(

            '🔄 Обновить карточку', callback_data='awg_manager:main')])
        rows.append([
            InlineKeyboardButton('⬅️ Назад', callback_data='router:cat:services'),
            InlineKeyboardButton('🏠 Модули', callback_data='router:main'),
        ])
        return '\n'.join(lines), InlineKeyboardMarkup(rows)

    async def _ask_mcp_token(self, q, ctx):
        self._awaiting_token = True
        text = (
            '🔑 <b>Ввод MCP-токена</b>\n\n'
            'Отправьте токен следующим сообщением.\n'
            '<i>Сообщение с токеном будет сразу удалено.</i>\n\n'
            'Получить токен: веб-интерфейс AWG Manager → Настройки → MCP-сервер.'
        )
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('❌ Отмена', callback_data='awg_manager:main')]
        ])
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                log.debug('ask_mcp_token edit failed: %s', e)

    async def _handle_text(self, update, ctx):
        if str(update.effective_chat.id) != self.chat_id:
            return
        if not self._awaiting_token:
            return

        token = (update.message.text or '').strip()
        try:
            await update.message.delete()
        except Exception:
            pass

        self._awaiting_token = False
        last_id = get_last_msg(self.chat_id)

        if not token:
            err_text = '❌ Токен пуст. Попробуйте снова: /awg → Задать токен'
            if last_id:
                try:
                    await ctx.bot.edit_message_text(
                        chat_id=self.chat_id, message_id=last_id,
                        text=err_text,
                    )
                    raise ApplicationHandlerStop
                except Exception:
                    pass
            await ctx.bot.send_message(chat_id=self.chat_id, text=err_text)
            raise ApplicationHandlerStop

        if save_mcp_token(token):
            header = '✅ <b>MCP-токен сохранён</b>\n\n'
        else:
            header = '❌ <b>Ошибка сохранения токена</b>\n\n'

        text, kb = self._build_card()

        # Пытаемся отредактировать окно ввода токена (чтобы не плодить сообщения)
        if last_id:
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id,
                    message_id=last_id,
                    text=header + text,
                    parse_mode='HTML',
                    reply_markup=kb,
                )
                raise ApplicationHandlerStop
            except Exception as e:
                log.debug('edit token result failed: %s', e)

        # Fallback, если отредактировать не удалось
        await ctx.bot.send_message(
            chat_id=self.chat_id,
            text=header + text,
            parse_mode='HTML',
            reply_markup=kb,
        )
        raise ApplicationHandlerStop

    @staticmethod
    def _proc_check(pname: str) -> bool:
        import subprocess
        try:
            r = subprocess.run(
                ['sh', '-c', f'ps w | grep -q "[{pname[0]}]{pname[1:]}" && echo yes'],
                capture_output=True, text=True, timeout=3,
            )
            return 'yes' in (r.stdout or '')
        except Exception:
            return False

    async def send_card_message(self, update, ctx):
        text, kb = self._build_card()
        await show_card(update, ctx, text, kb=kb)

    # ================= Callbacks =================

    async def _show_dashboard(self, q, ctx):
        try:
            tunnels = await _mcp_tool('list_tunnels')
            servers = await _mcp_tool('list_managed_servers')
            dns = await _mcp_tool('list_dns_routes')
            static = await _mcp_tool('list_static_routes')
        except Exception as e:
            log.error('Dashboard MCP error: %s', e)
            await q.edit_message_text(
                f'❌ <b>Ошибка MCP</b>\n\n<code>{_esc(str(e))}</code>',
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton('⬅️ Назад', callback_data='awg_manager:main')],
                ]))
            return

        lines = [f'{self.icon} <b>AWG Dashboard</b>', '']
        
        t_list = tunnels.get('tunnels', [])
        lines.append(f'📡 Туннели: <b>{len(t_list)}</b>')
        for t in t_list[:5]:
            st = '🟢' if t.get('up') else '🔴'
            lines.append(f'  {st} {_esc(t.get("name") or t.get("id", "?"))}')

        s_list = servers.get('servers', [])
        lines.append(f'\n🛡 WG Серверы: <b>{len(s_list)}</b>')
        for srv in s_list:
            st = '🟢' if srv.get('connected') else '🔴'
            mg = ' ⚙️' if srv.get('managed') else ''
            lines.append(f'  {st} {_esc(srv.get("description") or "?")} ({srv.get("interfaceName")}) · {srv.get("peerCount")} peers{mg}')

        lines.append('\n📋 Маршруты:')
        lines.append(f'  🌐 DNS: <b>{len(dns.get("routes", []))}</b>')
        lines.append(f'  🔗 Static: <b>{len(static.get("routes", []))}</b>')

        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('🔄 Обновить', callback_data='awg_manager:dashboard')],
            [InlineKeyboardButton('⬅️ Назад', callback_data='awg_manager:main')],
        ])
        try:
            await q.edit_message_text('\n'.join(lines), parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise

    async def handle_callback(self, action, q, ctx):
        if action == 'dashboard':
            await q.answer()
            return await self._show_dashboard(q, ctx)
        if action == 'main':
            await q.answer()
            text, kb = self._build_card()
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower():
                    raise
            return

        if action == 'cleanup:all':
            await q.answer()
            return await self._do_cleanup(q, ctx)

        if action == 'ask:uninstall':
            await q.answer()
            return await self._show_uninstall_menu(q, ctx)

        if action.startswith('opt:'):
            return await self._handle_opt(q, ctx, action[4:])

        if action == 'ask:mcp_token':
            await q.answer()
            return await self._ask_mcp_token(q, ctx)
        if action.startswith('ask:'):
            key = action[4:]
            await q.answer()
            a = ACTIONS.get(key)
            if not a:
                await q.answer('Неизвестное действие', show_alert=True)
                return
            desc = a['desc']
            if key == 'install':
                desc = desc.replace('&lt;router-ip&gt;', get_awg_web_url().split('//')[1].split(':')[0])
                warns = []
                if self._proc_check('xray'): warns.append('XKeen/HydraRoute')
                if self._proc_check('keen-pbr'): warns.append('Keen-PBR')
                if self._proc_check('usque'): warns.append('Usque WARP')
                if warns:
                    desc += f'\n\n⚠️ <b>Внимание:</b> сейчас запущен {", ".join(warns)}. Это может вызвать конфликт.'
            text = (
                f'{a["icon"]} <b>{a["title"]}</b>\n\n'
                f'{desc}\n\n'
                f'Подтвердить?'
            )
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('✅ Подтвердить', callback_data=f'awg_manager:go:{key}')],
                [InlineKeyboardButton('❌ Отмена', callback_data='awg_manager:main')],
            ])
            try:
                await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
            except Exception as e:
                if 'not modified' not in str(e).lower():
                    raise
            return

        if action.startswith('go:'):
            key = action[3:]
            await q.answer()
            a = ACTIONS.get(key)
            if not a:
                return
            await self._run_action(q, ctx, key, a)
            return

        await q.answer()

    # ================= Выполнение =================

    async def _run_action(self, q, ctx, key, action):
        import asyncio, os, pty, select, time, subprocess
        self._running = True

        self._status_msg_id = await ui_edit_q(
            q,
            f'{action["icon"]} <b>{action["title"]}</b>\n\n<pre>запуск...</pre>',
            kb=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='awg_manager:main')],
            ]),
        )

        cmd = action['cmd']

        def _exec():
            master, slave = pty.openpty()
            try:
                proc = subprocess.Popen(
                    ['sh', '-c', cmd],
                    stdin=slave, stdout=slave, stderr=slave,
                    close_fds=True, start_new_session=True,
                    env={**os.environ, 'TERM': 'dumb'},
                )
                os.close(slave)
                buf = b''
                start = time.time()
                while True:
                    try:
                        wpid, _ = os.waitpid(proc.pid, os.WNOHANG)
                        if wpid == proc.pid:
                            while True:
                                r, _, _ = select.select([master], [], [], 0.2)
                                if not r: break
                                try:
                                    data = os.read(master, 4096)
                                except OSError:
                                    break
                                if not data: break
                                buf += data
                            break
                    except ChildProcessError:
                        break
                    except Exception:
                        pass
                    try:
                        r, _, _ = select.select([master], [], [], 0.3)
                        if r:
                            try:
                                data = os.read(master, 4096)
                                if data: buf += data
                            except OSError:
                                break
                    except Exception:
                        pass
                    if time.time() - start > 300:
                        proc.kill()
                        break
                try:
                    _, status = os.waitpid(proc.pid, 0)
                    rc = os.waitstatus_to_exitcode(status)
                except Exception:
                    rc = -1
                os.close(master)
                return buf.decode('utf-8', errors='replace'), rc
            except Exception as e:
                try:
                    os.close(master)
                except Exception:
                    pass
                return str(e), -1

        out, rc = await asyncio.to_thread(_exec)
        self._running = False

        icon = '\u2705' if rc == 0 else '\u274c'
        tail = out[-3000:] if len(out) > 3000 else out
        text = (
            f'{icon} <b>{action["title"]} завершено</b>\n'
            f'<i>exit code: {rc}</i>\n\n'
            f'<pre>{_esc(tail)}</pre>'
        )

        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                  callback_data='awg_manager:main')],
        ])

        if rc == 0 and key == 'uninstall':
            try:
                leftovers = scan_leftovers(SCAN_PATTERNS)
            except Exception:
                leftovers = []
            if leftovers:
                self._leftovers = leftovers
                text += f'\n\n\U0001f50d <b>Найдено {len(leftovers)} остатков.</b>'
                kb = InlineKeyboardMarkup([
                    [InlineKeyboardButton(
                        f'\U0001f5d1 Удалить все ({len(leftovers)})',
                        callback_data='awg_manager:cleanup:all')],
                    [InlineKeyboardButton('\u2705 Оставить',
                                          callback_data='awg_manager:main')],
                ])

        if self._status_msg_id:
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id,
                    message_id=self._status_msg_id,
                    text=text, parse_mode='HTML',
                    reply_markup=kb,
                )
                self._status_msg_id = None
                return
            except Exception as e:
                log.debug('awg final edit: %s', e)
                self._status_msg_id = None

        await ctx.bot.send_message(
            chat_id=self.chat_id, text=text,
            parse_mode='HTML', reply_markup=kb,
        )

    # ================= Удаление с чекбоксами =================

    async def _show_uninstall_menu(self, q, ctx):
        targets = existing_targets(UNINSTALL_TARGETS)
        self._uninstall_opts = sync_opts(targets, self._uninstall_opts)
        text, kb = build_uninstall_menu(
            targets,
            self._uninstall_opts,
            title='Удаление AWG Manager',
            always_msg='Пакет <code>awg-manager</code> удаляется всегда.',
            prefix='awg_manager',
        )
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise

    async def _handle_opt(self, q, ctx, key):
        if key in self._uninstall_opts:
            toggle_opt(self._uninstall_opts, key)
            state = 'вкл' if self._uninstall_opts[key] else 'выкл'
            await q.answer(f'{state}: {key}')
            await self._show_uninstall_menu(q, ctx)
            return
        if key == 'go':
            await q.answer()
            targets = existing_targets(UNINSTALL_TARGETS)
            cmd = collect_uninstall_cmd(targets, self._uninstall_opts, UNINSTALL_CMD)
            self._uninstall_opts = {}
            action = {
                'icon': '🗑',
                'title': 'Удаление AWG Manager',
                'cmd': cmd,
            }
            await self._run_action(q, ctx, 'uninstall', action)
            return
        await q.answer()

    async def _check_leftovers(self, ctx):
        try:
            leftovers = scan_leftovers(SCAN_PATTERNS)
        except Exception as e:
            log.debug('scan_leftovers failed: %s', e)
            return
        if not leftovers:
            return
        self._leftovers = leftovers
        text, kb = build_leftovers_message(leftovers, prefix='awg_manager')
        try:
            await ctx.bot.send_message(
                chat_id=self.chat_id,
                text=text,
                parse_mode='HTML',
                reply_markup=kb,
            )
        except Exception as e:
            log.warning('send leftovers failed: %s', e)

    async def _do_cleanup(self, q, ctx):
        if not getattr(self, '_leftovers', None):
            await q.answer('Нечего удалять', show_alert=True)
            return
        parts = []
        total = len(self._leftovers)
        for p in self._leftovers:
            safe = p.replace("'", "'\\''")
            parts.append(f"echo 'Удаляю: {safe}' ; rm -rf '{safe}'")
        parts.append(f"echo '' ; echo 'Готово: удалено {total} элементов'")
        cmd = ' ; '.join(parts)
        self._leftovers = []
        action = {
            'icon': '🗑',
            'title': 'Удаление остатков',
            'cmd': cmd,
        }
        await self._run_action(q, ctx, 'cleanup', action)
RB_MODULES_AWG_MODULE_PY_EOF

echo "  → install.sh"
cat > /opt/router_bot/install.sh << 'RB_INSTALL_SH_EOF'
#!/bin/sh
set -e

# ---- Неинтерактивный режим (self-update из Telegram) ----
# При RB_NONINTERACTIVE=1 все read получат EOF и вернут дефолт
if [ "${RB_NONINTERACTIVE:-}" = "1" ]; then
    exec < /dev/null
    # read с EOF возвращает 1 — не убивать скрипт через set -e
    set +e
fi

BASE_DIR="/opt/router_bot"
LOG_DIR="/opt/var/log"
INIT_DIR="/opt/etc/init.d"

MODE="${RB_MODE:-auto}"
NEW_VERSION="${RB_VERSION:-}"
if [ "$MODE" = "auto" ]; then
    if [ -f "$BASE_DIR/config.env" ]; then
        MODE="upgrade"
    else
        MODE="install"
    fi
fi

# ---- всегда копируем helper-скрипты в /opt/bin ----
# (работает в любом режиме — install, upgrade, reinstall)
mkdir -p /opt/bin
if [ -f "$BASE_DIR/core/wrapper.sh" ]; then
    cp -f "$BASE_DIR/core/wrapper.sh" /opt/bin/routerbot_wrapper.sh
    chmod +x /opt/bin/routerbot_wrapper.sh
fi
if [ -f "$BASE_DIR/core/rb" ]; then
    cp -f "$BASE_DIR/core/rb" /opt/bin/rb
    chmod +x /opt/bin/rb
fi

echo ""
echo "════════════════════════════════════════════"
echo "  Router Bot — Установщик"
echo "════════════════════════════════════════════"
echo ""

# ---------- 1. Проверка и установка зависимостей ----------
echo "→ Проверяю зависимости..."
echo ""

MISSING_OPKG=""
MISSING_PIP=""

for pkg_bin in \
    "python3:/opt/bin/python3" \
    "python3-pip:/opt/bin/pip3" \
    "curl:/opt/bin/curl" \
    "ca-certificates:/opt/etc/ssl/certs/ca-certificates.crt"
do
    pkg="${pkg_bin%%:*}"
    bin="${pkg_bin#*:}"
    if [ ! -e "$bin" ]; then
        MISSING_OPKG="$MISSING_OPKG $pkg"
    fi
done

# OpenSSH-пакеты проверяем через opkg, а НЕ по пути:
# dropbear создаёт симлинк /opt/bin/ssh -> /opt/sbin/dropbear,
# из-за чего проверка "-e /opt/bin/ssh" обманывается.
for pkg in openssh-client openssh-keygen; do
    if ! opkg list-installed 2>/dev/null | grep -q "^${pkg} "; then
        MISSING_OPKG="$MISSING_OPKG $pkg"
    fi
done

# Финальная валидация: /opt/bin/ssh должен быть реально OpenSSH
if [ -x /opt/bin/ssh ]; then
    if ! /opt/bin/ssh -V 2>&1 | grep -q OpenSSH; then
        case " $MISSING_OPKG " in
            *" openssh-client "*) ;;
            *) MISSING_OPKG="$MISSING_OPKG openssh-client" ;;
        esac
    fi
fi

if [ ! -x /bin/ndmc ]; then
    echo "❌ /bin/ndmc не найден. Это не Keenetic?"
    exit 1
fi

# Системные утилиты, нужные для работы init-скриптов и сети
for tool in ip start-stop-daemon; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "  [WARN] Не найдена утилита: $tool — установка может не сработать"
    fi
done
echo "  ✅ /bin/ndmc"

# python-telegram-bot: проверяем вне зависимости от того, есть ли python3
if [ ! -x /opt/bin/python3 ]; then
    case " $MISSING_OPKG " in
        *" python3 "*) ;;
        *) MISSING_OPKG="$MISSING_OPKG python3" ;;
    esac
    MISSING_PIP="python-telegram-bot[job-queue]"
elif ! /opt/bin/python3 -c "import telegram" 2>/dev/null; then
    MISSING_PIP="python-telegram-bot[job-queue]"
else
    echo "  python-telegram-bot: OK"
fi

# python3 -m pip должен быть доступен, иначе установка упадёт
if [ -x /opt/bin/python3 ] && ! /opt/bin/python3 -m pip --version >/dev/null 2>&1; then
    case " $MISSING_OPKG " in
        *" python3-pip "*) ;;
        *) MISSING_OPKG="$MISSING_OPKG python3-pip" ;;
    esac
fi

echo ""
if [ -z "$MISSING_OPKG" ] && [ -z "$MISSING_PIP" ]; then
    echo "✅ Все зависимости на месте"
else
    echo "────────────────────────────────────────────"
    echo "  Не хватает:"
    [ -n "$MISSING_OPKG" ] && echo "    • opkg:$MISSING_OPKG"
    [ -n "$MISSING_PIP"  ] && echo "    • pip: $MISSING_PIP"
    echo "────────────────────────────────────────────"
    echo ""
    printf "Установить сейчас? (~60 сек) (y/N): "
    read DO_INSTALL
    if [ "$DO_INSTALL" != "y" ] && [ "$DO_INSTALL" != "Y" ]; then
        echo "Отмена. Установите вручную:"
        [ -n "$MISSING_OPKG" ] && echo "  opkg install$MISSING_OPKG"
        [ -n "$MISSING_PIP"  ] && echo "  pip3 install \"$MISSING_PIP\""
        exit 1
    fi

    if [ -n "$MISSING_OPKG" ]; then
        echo ""
        # --- Автоопределение архитектуры Entware ---
_entware_arch=""
if opkg print-architecture >/dev/null 2>&1; then
    _entware_arch=$(opkg print-architecture 2>/dev/null \
        | awk '$1=="arch" && $2!="all" && $2!~/_kn$/ && $3+0>max {max=$3+0; a=$2} END{print a}')
fi
if [ -z "$_entware_arch" ]; then
    _entware_arch=$(grep '^src/gz entware ' /opt/etc/opkg.conf 2>/dev/null \
        | awk '{print $NF}' | sed 's|.*/||')
fi
# Нормализация коротких форм под каталоги Entware
case "$_entware_arch" in
    aarch64|arm64|armv8)     _entware_arch="aarch64-k3.10" ;;
    mipsel|mips32|mips32el)  _entware_arch="mipselsf-k3.4" ;;
    mips)                    _entware_arch="mipssf-k3.4" ;;
    mips64|mips64el)         _entware_arch="mips64elsf-k3.4" ;;
    armv7|armv7l|armhf)      _entware_arch="armv7sf-k3.2" ;;
    x86_64|amd64|x86-64)     _entware_arch="x86-64-k3.2" ;;
esac
[ -z "$_entware_arch" ] && _entware_arch="mipselsf-k3.4"
echo "  Архитектура Entware: $_entware_arch"

# --- Пробегаем ВСЕ зеркала (HEAD с fallback на GET range) ---
_MIRROR_BASES="http://bin.entware.net https://mirrors.bfsu.edu.cn/entware http://mirrors.nju.edu.cn/entware https://mirror.vinet.io/entware http://entware.mirror.digitalpacific.com.au"
_OPKG_OK=0
for _mb in $_MIRROR_BASES; do
    _url="$_mb/$_entware_arch"
    echo "  Проверяю зеркало: $_url"
    _code=$(/opt/bin/curl -4 -sL -I -A 'RouterBot-mirror-check/1.0' \
        -o /dev/null -w "%{http_code}" --max-time 8 "$_url/Packages.gz" 2>/dev/null)
    case "$_code" in
        403|405|501|000|"")
            _code=$(/opt/bin/curl -4 -sL -r 0-0 -A 'RouterBot-mirror-check/1.0' \
                -o /dev/null -w "%{http_code}" --max-time 8 "$_url/Packages.gz" 2>/dev/null)
            ;;
    esac
    case "$_code" in
        200|204|206|301|302|303|307|308)
            echo "    ✅ $_code — применяю"
            sed -i "s|^src/gz entware .*|src/gz entware $_url|" /opt/etc/opkg.conf
            if opkg update >/dev/null 2>&1; then
                _OPKG_OK=1
                break
            fi
            echo "    ⚠️  opkg update не прошёл, пробую следующее"
            ;;
        *)
            echo "    ❌ $_code"
            ;;
    esac
done

if [ "$_OPKG_OK" = "0" ]; then
    echo "  ⚠️  Ни одно зеркало не отвечает. Пробую как есть."
    opkg update >/dev/null 2>&1 || true
fi

echo "→ opkg install$MISSING_OPKG"
opkg install --force-overwrite $MISSING_OPKG || { echo "❌ opkg install не удался"; exit 1; }
    fi

    if [ -n "$MISSING_PIP" ]; then
        echo ""
        echo "→ pip3 install (может занять ~30 сек)"
        /opt/bin/python3 -m pip install --quiet --upgrade "$MISSING_PIP" || {
            echo "❌ pip3 install не удался"; exit 1;
        }
    fi
    echo ""
    echo "✅ Зависимости установлены"
fi
echo ""

# ---------- 2. Проверка файлов фреймворка ----------
REQUIRED="
$BASE_DIR/main.py
$BASE_DIR/core/__init__.py
$BASE_DIR/core/main.py
$BASE_DIR/core/config.py
$BASE_DIR/core/router.py
$BASE_DIR/core/utils.py
$BASE_DIR/modules/__init__.py
$BASE_DIR/modules/net_watch/__init__.py
$BASE_DIR/modules/net_watch/module.py
$BASE_DIR/modules/ssh_control/__init__.py
$BASE_DIR/modules/ssh_control/module.py
$BASE_DIR/modules/ssh_control/ssh_client.py
$BASE_DIR/modules/ssh_control/storage.py
$BASE_DIR/modules/system/__init__.py
$BASE_DIR/modules/system/module.py
$BASE_DIR/modules/hydraroute/__init__.py
$BASE_DIR/modules/hydraroute/module.py
$BASE_DIR/modules/hydraroute/actions.py
$BASE_DIR/modules/flashkeen/__init__.py
$BASE_DIR/modules/flashkeen/module.py
$BASE_DIR/modules/flashkeen/actions.py
$BASE_DIR/modules/xkeen/__init__.py
$BASE_DIR/modules/xkeen/module.py
$BASE_DIR/modules/xkeen/actions.py
$BASE_DIR/modules/bird/__init__.py
$BASE_DIR/modules/bird/module.py
$BASE_DIR/modules/bird/actions.py
$BASE_DIR/modules/mtproxy/__init__.py
$BASE_DIR/modules/mtproxy/module.py
$BASE_DIR/modules/mtproxy/actions.py
$BASE_DIR/modules/keen_pbr/__init__.py
$BASE_DIR/modules/keen_pbr/module.py
$BASE_DIR/modules/keen_pbr/actions.py
$BASE_DIR/modules/neofit/__init__.py
$BASE_DIR/modules/neofit/module.py
$BASE_DIR/modules/neofit/actions.py
$BASE_DIR/modules/usque_keenetic/__init__.py
$BASE_DIR/modules/usque_keenetic/module.py
$BASE_DIR/modules/usque_keenetic/actions.py
$BASE_DIR/modules/awg_manager/__init__.py
$BASE_DIR/modules/awg_manager/module.py
$BASE_DIR/modules/awg_manager/actions.py
"
MISSING_FILES=""
for f in $REQUIRED; do
    [ -f "$f" ] || MISSING_FILES="$MISSING_FILES $f"
done

if [ -n "$MISSING_FILES" ]; then
    echo "❌ Не хватает файлов:"
    for f in $MISSING_FILES; do echo "   $f"; done
    exit 1
fi
echo "✅ Все файлы фреймворка на месте"
echo ""

# ---------- 2a. Запись версии ----------
if [ -n "$NEW_VERSION" ]; then
    printf '%s\n' "$NEW_VERSION" > "$BASE_DIR/VERSION"
    echo "  → Версия: $NEW_VERSION"
    echo ""
fi

# ---------- 2b. Режим обновления ----------
if [ "$MODE" != "install" ]; then
    # --- Self-heal: целостность установки ---
    if [ ! -f /opt/router_bot/config.env ]; then
        if [ -f /opt/router_bot/config.env.bak ]; then
            echo "⚠️  config.env отсутствует, восстанавливаю из бэкапа..."
            cp -p /opt/router_bot/config.env.bak /opt/router_bot/config.env
            chmod 600 /opt/router_bot/config.env
            echo "  ✅ config.env восстановлен"
            echo "  ⚠️  Проверьте актуальность: rb config"
        else
            echo "⚠️  config.env отсутствует, резервной копии тоже нет."
            echo "   Нужна полная переустановка:"
            echo "     rm /opt/router_bot/VERSION && sh /tmp/router_bot_setup.sh"
            exit 1
        fi
    fi
    echo "→ Проверяю целостность установки..."
    if [ -f /opt/router_bot/restore_init.sh ]; then
        sh /opt/router_bot/restore_init.sh
    fi
    # Чистим .pyc-мусор в бэкапе от старых версий (до v2)
    if [ -d /opt/router_bot/.user_backup ]; then
        find /opt/router_bot/.user_backup -name '*.pyc' -delete 2>/dev/null || true
        find /opt/router_bot/.user_backup -type d -name __pycache__ -empty -delete 2>/dev/null || true
    fi
    # Чистим __pycache__ в установке — Python пересоздаст при старте
    find /opt/router_bot -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
    echo ""
    echo "────────────────────────────────────────────"
    echo "  Режим: $MODE"
    echo "────────────────────────────────────────────"
    echo ""

    # --- Сводка о сохранённых изменениях ---
    if [ -d /opt/router_bot/.user_backup ]; then
        _bk=$(find /opt/router_bot/.user_backup -type f 2>/dev/null | wc -l | tr -d " ")
        [ -z "$_bk" ] && _bk=0
        if [ "$_bk" -gt 0 ]; then
            echo "════════════════════════════════════════════"
            echo "  ⚠️  Найдены изменённые файлы ($_bk)"
            echo "════════════════════════════════════════════"
            echo ""
            echo "Файлы, которые вы правили вручную:"
            find /opt/router_bot/.user_backup -type f 2>/dev/null | sed "s|/opt/router_bot/.user_backup/|    • |"
            echo ""
            echo "В системе они уже перезаписаны эталоном из архива."
            echo "Ваши копии сохранены в /opt/router_bot/.user_backup/"
            echo ""
            printf "Восстановить ваши версии? (y/N): "
            read _RESTORE
            if [ "$_RESTORE" = "y" ] || [ "$_RESTORE" = "Y" ]; then
                ( cd /opt/router_bot/.user_backup && find . -type f ) | while IFS= read -r _rel; do
                    _rel="${_rel#./}"
                    _src="/opt/router_bot/.user_backup/$_rel"
                    _dst="/opt/router_bot/$_rel"
                    mkdir -p "$(dirname "$_dst")"
                    cp -p "$_src" "$_dst" 2>/dev/null || true
                done
                echo "  ✅ Ваши изменения восстановлены"
                echo "  ⚠️  Проверьте совместимость с новой версией!"
            else
                echo "  Оставлены эталонные версии"
            fi
            echo ""
        fi
    fi

    # --- 1. Маршрут к api.telegram.org ---
    _RETRY=0
    _ANS_R=""
    while [ "$_RETRY" -lt 3 ]; do
        _RETRY=$((_RETRY+1))
        printf "→ Обновить маршрут к api.telegram.org? (y/N): "
        read _ANS_R
        _ANS_R=$(printf "%s" "$_ANS_R" | sed 's/[^[:alnum:]]//g')
        case "$_ANS_R" in
            y|Y) break ;;
            n|N) break ;;
            "") ;;
            *) echo "  Введите y или n" ;;
        esac
    done
    if [ "$_ANS_R" = "y" ] || [ "$_ANS_R" = "Y" ]; then
        echo ""
        _TUNABLES=$(ip -o link show 2>/dev/null \
            | sed "s/@[^ :]*//g" \
            | awk -F": " '$2 ~ /^(opkgtun[0-9]+|nwg[0-9]+|wg[0-9]+|tap[0-9]+)$/ { print $2 }')
        if [ -z "$_TUNABLES" ]; then
            echo "  Туннели не найдены, пропускаю."
        else
            _all_tuns=""
            _n=0
            _first_up=""
            for _t in $_TUNABLES; do
                if ip -o link show dev "$_t" 2>/dev/null | grep -q '<[^>]*UP[^>]*>'; then
                    _n=$((_n+1))
                    _all_tuns="$_all_tuns $_t"
                    [ -z "$_first_up" ] && _first_up="$_t"
                    _tip=$(ip -4 -o addr show dev "$_t" 2>/dev/null | awk "{print \$4}" | cut -d/ -f1 | head -1)
                    echo "    $_n) $_t  ${_tip:-no-IP}  [UP]"
                fi
            done
            for _t in $_TUNABLES; do
                if ! ip -o link show dev "$_t" 2>/dev/null | grep -q '<[^>]*UP[^>]*>'; then
                    _n=$((_n+1))
                    _all_tuns="$_all_tuns $_t"
                    _tip=$(ip -4 -o addr show dev "$_t" 2>/dev/null | awk "{print \$4}" | cut -d/ -f1 | head -1)
                    echo "    $_n) $_t  ${_tip:-no-IP}  [DOWN]"
                fi
            done
            echo ""
            _new_vpn_if=""
            if [ "$_n" -eq 1 ]; then
                _new_vpn_if=$(echo "$_all_tuns" | awk "{print \$1}")
                echo "  Единственный туннель: $_new_vpn_if"
            else
                while true; do
                    if [ -n "$_first_up" ]; then
                        printf "  Выберите номер [1-%d] (Enter = 1, %s): " "$_n" "$_first_up"
                    else
                        printf "  Выберите номер [1-%d]: " "$_n"
                    fi
                    read _ANS
                    _ANS=$(echo "$_ANS" | tr -d "[:space:]")
                    if [ -z "$_ANS" ] && [ -n "$_first_up" ]; then
                        _new_vpn_if="$_first_up"
                        break
                    fi
                    case "$_ANS" in
                        *[!0-9]*) echo "  Ошибка: число 1-$_n"; continue ;;
                    esac
                    if [ "$_ANS" -ge 1 ] && [ "$_ANS" -le "$_n" ]; then
                        _new_vpn_if=$(echo "$_all_tuns" | awk -v n="$_ANS" "{print \$n}")
                        [ -n "$_new_vpn_if" ] && break
                    else
                        echo "  Ошибка: число 1-$_n"
                    fi
                done
            fi

            _new_vpn_src=$(ip -4 -o addr show dev "$_new_vpn_if" 2>/dev/null | awk "{print \$4}" | cut -d/ -f1 | head -1)
            _wt=$(sed -n "s/^ROUTE_TABLE='\(.*\)'/\1/p" /opt/router_bot/config.env 2>/dev/null)
            [ -z "$_wt" ] && _wt="16385"
            echo "  Проверяю $_new_vpn_if ($_new_vpn_src)... (до 8 сек)"
            for _net in 149.154.160.0/20 91.108.4.0/22; do
                ip route add "$_net" dev "$_new_vpn_if" src "$_new_vpn_src" table "$_wt" 2>/dev/null || true
            done
            _CURL_OK=no
            if /opt/bin/curl -sf --max-time 8 "https://api.telegram.org" >/dev/null 2>&1; then
                _CURL_OK=yes
            fi
            if [ "$_CURL_OK" = "yes" ]; then
                echo "  ✅ Доступ через $_new_vpn_if есть"
                sed -i "s|^VPN_IF=.*|VPN_IF='$_new_vpn_if'|" /opt/router_bot/config.env
                sed -i "s|^VPN_SRC=.*|VPN_SRC='$_new_vpn_src'|" /opt/router_bot/config.env
                sed -i "s|^USE_VPN=.*|USE_VPN='yes'|" /opt/router_bot/config.env
                if [ ! -x /opt/etc/init.d/S97tgroutes ] && [ -f /opt/router_bot/init/S97tgroutes ]; then
                    cp -f /opt/router_bot/init/S97tgroutes /opt/etc/init.d/S97tgroutes
                    chmod +x /opt/etc/init.d/S97tgroutes
                fi
                /opt/etc/init.d/S97tgroutes rebuild >/dev/null 2>&1 || true
                echo "  ✅ config.env обновлён"
            else
                echo "  ❌ Через $_new_vpn_if доступа нет, оставляю старую настройку"
            fi
        fi
    else
        echo "  Маршрут оставлен без изменений"
    fi
    echo ""

    # --- 2. Токен ---
    _RETRY=0
    _ANS_T=""
    while [ "$_RETRY" -lt 3 ]; do
        _RETRY=$((_RETRY+1))
        printf "→ Обновить токен бота? (y/N): "
        read _ANS_T
        _ANS_T=$(printf "%s" "$_ANS_T" | sed 's/[^[:alnum:]]//g')
        case "$_ANS_T" in
            y|Y) break ;;
            n|N) break ;;
            "") ;;
            *) echo "  Введите y или n" ;;
        esac
    done
    if [ "$_ANS_T" = "y" ] || [ "$_ANS_T" = "Y" ]; then
        while true; do
            printf "  Токен бота (от @BotFather): "
            read _NEW_TOKEN
            _NEW_TOKEN=$(echo "$_NEW_TOKEN" | tr -d " ")
            [ -z "$_NEW_TOKEN" ] && echo "  Пусто, попробуйте ещё" && continue
            _RES=$(TG_TOKEN="$_NEW_TOKEN" /opt/bin/python3 - << 'PYEOF'
import os, json, urllib.request, urllib.error
tok = os.environ.get("TG_TOKEN", "")
try:
    r = urllib.request.urlopen(f"https://api.telegram.org/bot{tok}/getMe", timeout=10)
    d = json.loads(r.read())
    print("OK:" + d["result"].get("username", "") if d.get("ok") else "FAIL_OTHER:bad")
except urllib.error.HTTPError as e:
    print(f"FAIL_TOKEN:HTTP {e.code}")
except urllib.error.URLError as e:
    print(f"FAIL_NET:{e.reason}")
except Exception as e:
    print(f"FAIL_OTHER:{type(e).__name__}:{e}")
PYEOF
)
            case "$_RES" in
                OK:*)
                    _BOT_USER="${_RES#OK:}"
                    echo "  ✅ Токен валиден, бот: @$_BOT_USER"
                    sed -i "s|^TG_BOT_TOKEN=.*|TG_BOT_TOKEN='$_NEW_TOKEN'|" /opt/router_bot/config.env
                    echo "  ✅ config.env обновлён"
                    break
                    ;;
                FAIL_TOKEN:*)
                    echo "  ❌ Токен неверен: ${_RES#FAIL_TOKEN:}"
                    ;;
                FAIL_NET:*)
                    echo "  ⚠️  Сеть: ${_RES#FAIL_NET:}"
                    printf "     Повторить? (Y/n): "; read _R; [ "$_R" = "n" ] && break
                    ;;
                *) echo "  ❌ $_RES" ;;
            esac
        done
    else
        echo "  Токен оставлен без изменений"
    fi
    echo ""

    # --- 3. Chat ID ---
    _RETRY=0
    _ANS_C=""
    while [ "$_RETRY" -lt 3 ]; do
        _RETRY=$((_RETRY+1))
        printf "→ Обновить chat_id? (y/N): "
        read _ANS_C
        _ANS_C=$(printf "%s" "$_ANS_C" | sed 's/[^[:alnum:]]//g')
        case "$_ANS_C" in
            y|Y) break ;;
            n|N) break ;;
            "") ;;
            *) echo "  Введите y или n" ;;
        esac
    done
    if [ "$_ANS_C" = "y" ] || [ "$_ANS_C" = "Y" ]; then
        _cur_token=$(sed -n "s/^TG_BOT_TOKEN='\(.*\)'/\1/p" /opt/router_bot/config.env)
        while true; do
            printf "  Chat ID: "
            read _NEW_CHAT
            _NEW_CHAT=$(echo "$_NEW_CHAT" | tr -d " ")
            [ -z "$_NEW_CHAT" ] && echo "  Пусто, попробуйте ещё" && continue
            _RES=$(TG_TOKEN="$_cur_token" TG_CHAT="$_NEW_CHAT" /opt/bin/python3 - << 'PYEOF'
import os, json, urllib.request, urllib.parse, urllib.error
tok = os.environ["TG_TOKEN"]; chat = os.environ["TG_CHAT"]
try:
    data = urllib.parse.urlencode({"chat_id": chat, "text": "Router Bot: check chat_id"}).encode()
    r = urllib.request.urlopen(f"https://api.telegram.org/bot{tok}/sendMessage", data=data, timeout=10)
    d = json.loads(r.read())
    print("OK" if d.get("ok") else "FAIL_OTHER:not ok")
except urllib.error.HTTPError as e:
    print(f"FAIL_CHAT:HTTP {e.code}")
except urllib.error.URLError as e:
    print(f"FAIL_NET:{e.reason}")
except Exception as e:
    print(f"FAIL_OTHER:{type(e).__name__}:{e}")
PYEOF
)
            case "$_RES" in
                OK)
                    echo "  ✅ Chat ID валиден, тестовое сообщение доставлено"
                    sed -i "s|^TG_CHAT_ID=.*|TG_CHAT_ID='$_NEW_CHAT'|" /opt/router_bot/config.env
                    echo "  ✅ config.env обновлён"
                    break
                    ;;
                FAIL_CHAT:*)
                    echo "  ❌ Chat ID неверен или бот не начал диалог: ${_RES#FAIL_CHAT:}"
                    ;;
                FAIL_NET:*)
                    echo "  ⚠️  Сеть: ${_RES#FAIL_NET:}"
                    printf "     Повторить? (Y/n): "; read _R; [ "$_R" = "n" ] && break
                    ;;
                *) echo "  ❌ $_RES" ;;
            esac
        done
    else
        echo "  Chat ID оставлен без изменений"
    fi
    echo ""

    rm -f /var/run/routerbot.giveup /var/run/routerbot.fail
    echo "→ Перезапускаю бота..."
    /opt/etc/init.d/S98routerbot restart 2>/dev/null || true
    echo ""
    echo "════════════════════════════════════════════"
    echo "  ✅ Обновление завершено"
    echo "════════════════════════════════════════════"
    echo ""
    echo "→ Обновляю init-скрипты..."
    sh /opt/router_bot/ensure_init.sh
    echo ""
    echo "  Логи:  tail -f $LOG_DIR/router_bot.log"
    echo ""
    exit 0
fi

# ---------- 3. Автоопределение сети ----------
echo "→ Определение параметров сети..."

# --- Универсальный детект WAN: default via <gw> dev <iface> ---
detect_wan() {
    # 1. Настоящий WAN: default route с "via" (значит есть gateway)
    _line=$(ip route show default 2>/dev/null | grep " via " | head -1)
    if [ -n "$_line" ]; then
        _if=$(echo "$_line" | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
        _src=$(ip -4 -o addr show dev "$_if" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
        if [ -n "$_if" ] && [ -n "$_src" ]; then
            echo "$_if|$_src"
            return 0
        fi
    fi

    # 2. Fallback: default dev <iface> без via (обычно br0)
    _line=$(ip route show default 2>/dev/null | head -1)
    if [ -n "$_line" ]; then
        _if=$(echo "$_line" | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
        _src=$(ip -4 -o addr show dev "$_if" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
        if [ -n "$_if" ] && [ -n "$_src" ]; then
            echo "$_if|$_src"
            return 0
        fi
    fi
    return 1
}

if _WAN_INFO=$(detect_wan); then
    WAN_IF="${_WAN_INFO%%|*}"
    WAN_SRC="${_WAN_INFO#*|}"
    echo "  Определён WAN: $WAN_IF ($WAN_SRC)"
else
    echo "  ⚠️  Автодетект WAN не удался"
    WAN_IF=""
    WAN_SRC=""
fi

printf "  Использовать этот WAN? (Y/n, n — ввести вручную): "
read _ANS_WAN
case "$_ANS_WAN" in
    n|N)
        printf "  WAN-интерфейс (ppp0/eth3/...): "
        read WAN_IF
        printf "  IP на $WAN_IF: "
        read WAN_SRC
        ;;
esac

if [ -z "$WAN_IF" ] || [ -z "$WAN_SRC" ]; then
    echo "  ❌ WAN не задан"
    exit 1
fi

WAN_TABLE=$(ip rule show 2>/dev/null | awk -v src="$WAN_SRC" '
    $0 ~ "from " src " " { for(i=1;i<=NF;i++) if($i=="lookup") { print $(i+1); exit } }
')
[ -z "$WAN_TABLE" ] && WAN_TABLE="main"

echo "  WAN-интерфейс: $WAN_IF"
echo "  IP роутера:    $WAN_SRC"
echo "  Таблица:       $WAN_TABLE"
echo ""

# =================== продолжение в следующей части ===================

# ---------- 3.5. IPv6 ----------
echo "────────────────────────────────────────────"
echo "  IPv6 (влияет на проверку Telegram)"
echo "────────────────────────────────────────────"
echo "  На некоторых провайдерах IPv6 вызывает зависание"
echo "  при подключении к api.telegram.org."
echo ""
DISABLE_IPV6="yes"
printf "Отключить IPv6 для бота? (Y/n): "
read ANS_V6
ANS_V6=$(printf "%s" "$ANS_V6" | sed 's/[^[:alnum:]]//g')
case "$ANS_V6" in
    n|N) DISABLE_IPV6="no" ;;
    *)   DISABLE_IPV6="yes" ;;
esac
if [ "$DISABLE_IPV6" = "yes" ]; then
    echo "  IPv6 отключён (бот только на IPv4)"
else
    echo "  IPv6 включён"
fi
echo ""

# ---------- 4. Доступ к Telegram ----------
echo "────────────────────────────────────────────"
echo "  Доступ к Telegram"
echo "────────────────────────────────────────────"
echo ""

_curl_opts="-sf --max-time 8"
if [ "$DISABLE_IPV6" = "yes" ]; then
    _curl_opts="$_curl_opts -4"
fi

printf "→ Проверяю доступность Telegram напрямую... "
if /opt/bin/curl $_curl_opts "https://api.telegram.org" >/dev/null 2>&1; then
    echo "✅ доступен"
    echo "  VPN не нужен."
    USE_VPN="no"
    VPN_IF=""
    VPN_SRC=""
else
    echo "❌ недоступен"
    echo "  Похоже, Telegram блокируется. Настроим VPN."
    echo ""

    # Поиск туннелей (без tunl0, PPP, Tap и т.п.)
    TUNABLES=$(ip -o link show 2>/dev/null \
        | sed 's/@[^ :]*//g' \
        | awk -F': ' '$2 ~ /^(opkgtun[0-9]+|nwg[0-9]+|wg[0-9]+|tap[0-9]+)$/ { print $2 }')

    if [ -z "$TUNABLES" ]; then
        echo "  Туннелей не найдено."
        printf "  Введите имя туннеля вручную или Enter для отмены: "
        read VPN_IF
        [ -z "$VPN_IF" ] && { echo "  Отмена."; exit 1; }
    else
        # Собираем нумерованный список: сначала UP, потом DOWN.
        _all_tuns=""
        _n=0
        _first_up=""

        for _t in $TUNABLES; do
            if ip -o link show dev "$_t" 2>/dev/null | grep -q '<[^>]*UP[^>]*>'; then
                _n=$((_n+1))
                _all_tuns="$_all_tuns $_t"
                [ -z "$_first_up" ] && _first_up="$_t"
                _tip=$(ip -4 -o addr show dev "$_t" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
                echo "    $_n) $_t  ${_tip:-no-IP}  [UP]"
            fi
        done
        for _t in $TUNABLES; do
            if ! ip -o link show dev "$_t" 2>/dev/null | grep -q '<[^>]*UP[^>]*>'; then
                _n=$((_n+1))
                _all_tuns="$_all_tuns $_t"
                _tip=$(ip -4 -o addr show dev "$_t" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
                echo "    $_n) $_t  ${_tip:-no-IP}  [DOWN]"
            fi
        done
        echo ""

        if [ "$_n" -eq 0 ]; then
            echo "  ОШИБКА: туннели не найдены"
            exit 1
        fi

        if [ "$_n" -eq 1 ]; then
            VPN_IF=$(echo "$_all_tuns" | awk '{print $1}')
            echo "  Единственный туннель: $VPN_IF (выбран автоматически)"
        else
            while true; do
                if [ -n "$_first_up" ]; then
                    printf "  Выберите номер туннеля [1-%d] (Enter = 1, %s): " "$_n" "$_first_up"
                else
                    printf "  Выберите номер туннеля [1-%d]: " "$_n"
                fi
                read _ANS
                _ANS=$(echo "$_ANS" | tr -d '[:space:]')

                if [ -z "$_ANS" ]; then
                    if [ -n "$_first_up" ]; then
                        VPN_IF="$_first_up"
                        echo "  Выбран по умолчанию: $VPN_IF"
                        break
                    else
                        echo "  Нет UP-туннелей. Введите номер вручную."
                        continue
                    fi
                fi

                case "$_ANS" in
                    *[!0-9]*)
                        echo "  Ошибка: введите число от 1 до $_n"
                        continue
                        ;;
                esac

                if [ "$_ANS" -ge 1 ] && [ "$_ANS" -le "$_n" ]; then
                    VPN_IF=$(echo "$_all_tuns" | awk -v n="$_ANS" '{print $n}')
                    if [ -n "$VPN_IF" ]; then
                        echo "  Выбран: $VPN_IF"
                        break
                    fi
                else
                    echo "  Ошибка: число должно быть от 1 до $_n"
                fi
            done
        fi

        # Предупреждение, если выбранный туннель в состоянии DOWN
        if ! ip -o link show dev "$VPN_IF" 2>/dev/null | grep -q '<[^>]*UP[^>]*>'; then
            echo "  ВНИМАНИЕ: туннель $VPN_IF в состоянии DOWN."
            printf "  Продолжить с ним? (y/N): "
            read _C
            _C=$(printf "%s" "$_C" | tr -cd '\040-\176')
            [ "$_C" = "y" ] || [ "$_C" = "Y" ] || exit 1
        fi
    fi

    VPN_SRC=$(ip -4 -o addr show dev "$VPN_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    if [ -z "$VPN_SRC" ]; then
        printf "  Введите IP туннеля $VPN_IF: "
        read VPN_SRC
    fi

    echo ""
    printf "→ Проверяю доступ к Telegram через $VPN_IF ($VPN_SRC)... "
    # Удаляем конфликтующие маршруты из main (например, /32 через WAN)
    ip route del 149.154.166.110 2>/dev/null || true
    ip route del 149.154.160.0/20 2>/dev/null || true
    ip route del 91.108.4.0/22 2>/dev/null || true
    # Ставим через VPN — replace, чтобы гарантированно перезаписать
    ip route replace 149.154.166.110 dev "$VPN_IF" src "$VPN_SRC" table "$WAN_TABLE" 2>/dev/null || true
    ip route replace 149.154.160.0/20 dev "$VPN_IF" src "$VPN_SRC" table "$WAN_TABLE" 2>/dev/null || true
    ip route replace 91.108.4.0/22 dev "$VPN_IF" src "$VPN_SRC" table "$WAN_TABLE" 2>/dev/null || true
    # Удаляем старые правила для этих сетей — любой таблицы
    for _net in 149.154.166.110 149.154.160.0/20 91.108.4.0/22; do
        _j=0
        while [ "$_j" -lt 10 ]; do
            ip rule del to "$_net" 2>/dev/null || break
            _j=$((_j+1))
        done
    done
    # Добавляем правила
    ip rule add to 149.154.166.110 lookup "$WAN_TABLE" priority 1099 2>/dev/null || true
    ip rule add to 149.154.160.0/20 lookup "$WAN_TABLE" priority 1100 2>/dev/null || true
    ip rule add to 91.108.4.0/22 lookup "$WAN_TABLE" priority 1101 2>/dev/null || true
    ip rule add from "$WAN_SRC" lookup "$WAN_TABLE" priority 1152 2>/dev/null || true

    _vpn_ok=no; _route_ok=no
    if /opt/bin/curl $_curl_opts --interface "$VPN_IF" "https://api.telegram.org" >/dev/null 2>&1; then
        _vpn_ok=yes
    fi
    if /opt/bin/curl $_curl_opts "https://api.telegram.org" >/dev/null 2>&1; then
        _route_ok=yes
    fi
    if [ "$_route_ok" = "yes" ]; then
        echo "✅ работает"
        USE_VPN="yes"
    elif [ "$_vpn_ok" = "yes" ]; then
        echo "⚠️  VPN работает, но маршрут пока не применяется"
        echo "  Бот при старте применит маршруты повторно (S97tgroutes)."
        USE_VPN="yes"
    else
        echo "❌ VPN не работает (даже --interface)"
        printf "  Продолжить установку всё равно? (y/N): "
        read ANS
        if [ "$ANS" = "y" ] || [ "$ANS" = "Y" ]; then
            USE_VPN="yes"
            echo "  ⚠️  Продолжаем без рабочего VPN."
        else
            echo "  Отмена."
            exit 1
        fi
    fi
    # Маршрут НЕ удаляем — он нужен для проверки токена (urllib).
    # Дополнительно покрываем обе подсети Telegram.
    for _tgnet in 149.154.166.110 149.154.160.0/20 91.108.4.0/22; do
        ip route replace "$_tgnet" dev "$VPN_IF" src "$VPN_SRC" table "$WAN_TABLE" 2>/dev/null || true
    done
fi
echo ""

# ---------- 5. Выбор модулей (auto-discovery) ----------
echo "────────────────────────────────────────────"
echo "  Выбор модулей"
echo "────────────────────────────────────────────"
echo ""

if [ ! -x /opt/bin/python3 ]; then
    echo "❌ python3 отсутствует — не могу получить список модулей"
    exit 1
fi

set +e
_MODS_LIST=$(/opt/bin/python3 /opt/router_bot/core/list_modules.py 2>&1)
_MODS_RC=$?
set -e

if [ "$_MODS_RC" != "0" ] || [ -z "$_MODS_LIST" ]; then
    echo "❌ Не удалось получить список модулей (rc=$_MODS_RC)"
    echo "$_MODS_LIST" | sed 's/^/     /'
    exit 1
fi

_MODS_FILE=/tmp/rb_modules_list.txt
printf '%s\n' "$_MODS_LIST" > "$_MODS_FILE"

_MODS_TOTAL=0
while IFS='|' read -r _mname _mtitle _micon _mdesc _mcat _mdef; do
    [ -n "$_mname" ] && _MODS_TOTAL=$((_MODS_TOTAL+1))
done < "$_MODS_FILE"

if [ "$_MODS_TOTAL" = "0" ]; then
    echo "❌ В /opt/router_bot/modules/ не найдено ни одного модуля"
    rm -f "$_MODS_FILE"
    exit 1
fi

echo "Найдено модулей: $_MODS_TOTAL"
echo ""

ENABLED=""
printf "Установить все модули без вопросов? (y/N): "
read ANS_ALL
echo ""

if [ "$ANS_ALL" = "y" ] || [ "$ANS_ALL" = "Y" ]; then
    _COUNT=0
    while IFS='|' read -r _mname _mtitle _micon _mdesc _mcat _mdef; do
        [ -z "$_mname" ] && continue
        [ "$_mdef" = "1" ] || continue
        ENABLED="$ENABLED,$_mname"
        _COUNT=$((_COUNT+1))
    done < "$_MODS_FILE"
    echo "════════════════════════════════════════════"
    echo "  ✅ Выбрано: установка ВСЕХ модулей ($_COUNT)"
    echo "════════════════════════════════════════════"
    echo ""
    while IFS='|' read -r _mname _mtitle _micon _mdesc _mcat _mdef; do
        [ -z "$_mname" ] && continue
        [ "$_mdef" = "1" ] || continue
        printf "  %s %s — %s\n" "$_micon" "$_mtitle" "$_mdesc"
    done < "$_MODS_FILE"
    echo ""
else
    echo "По умолчанию все модули будут установлены."
    echo "Введите 'n' чтобы пропустить любой из них."
    echo ""
    while IFS='|' read -r _mname _mtitle _micon _mdesc _mcat _mdef; do
        [ -z "$_mname" ] && continue
        printf "%s %s\n" "$_micon" "$_mtitle"
        [ -n "$_mdesc" ] && printf "   %s\n" "$_mdesc"
        printf "   Установить? (Y/n): "
        read _ans_mod
        case "$_ans_mod" in
            n|N) printf "   ⏭  %s пропущен\n" "$_mtitle" ;;
            *)   ENABLED="$ENABLED,$_mname"; printf "   ✅ %s будет установлен\n" "$_mtitle" ;;
        esac
        echo ""
    done < "$_MODS_FILE"
fi

rm -f "$_MODS_FILE"

ENABLED=$(echo "$ENABLED" | sed 's/^,//')

if [ -z "$ENABLED" ]; then
    echo "❌ Не выбран ни один модуль. Установка отменена."
    exit 1
fi

echo "────────────────────────────────────────────"
echo "✅ Итоговый список модулей: $ENABLED"
echo "────────────────────────────────────────────"
echo ""

# =================== продолжение в следующей части ===================

# ---------- 6. Токен + Chat ID ----------
echo "────────────────────────────────────────────"
echo "  Настройка бота"
echo "────────────────────────────────────────────"
echo ""

while true; do
    # Перед первым вводом токена — применить правила для подсетей Telegram,
    # чтобы urllib-запрос getMe не ушёл в мёртвую таблицу.
    if [ "$_TG_RULES_APPLIED" != "yes" ] && [ "$USE_VPN" = "yes" ] && [ -n "$VPN_IF" ] && [ -n "$VPN_SRC" ]; then
        echo "-> Применяю правила Telegram через $VPN_IF для проверки токена..."
        _p=1100
        for _tgnet in 149.154.160.0/20 91.108.4.0/22; do
            ip rule add to "$_tgnet" lookup "$WAN_TABLE" priority $_p 2>/dev/null || true
            ip route add "$_tgnet" dev "$VPN_IF" src "$VPN_SRC" table "$WAN_TABLE" 2>/dev/null || true
            _p=$((_p+1))
        done
        ip rule add from "$WAN_SRC" lookup "$WAN_TABLE" priority 1152 2>/dev/null || true
        if ip route get 149.154.166.110 from "$WAN_SRC" 2>/dev/null | grep -q "$VPN_IF"; then
            echo "  OK: маршрут через $VPN_IF активен"
        else
            echo "  ВНИМАНИЕ: маршрут через $VPN_IF не активен"
        fi
        echo ""
        _TG_RULES_APPLIED=yes
    fi
    printf "Токен бота (от @BotFather): "
    read TOKEN
    TOKEN=$(echo "$TOKEN" | tr -d ' ')
    [ -z "$TOKEN" ] && echo "  Пусто. Попробуйте ещё раз." && continue

    RES=$(TG_TOKEN="$TOKEN" /opt/bin/python3 - << 'PYEOF'
import os, json, urllib.request, urllib.error
tok = os.environ.get('TG_TOKEN', '')
try:
    r = urllib.request.urlopen(f'https://api.telegram.org/bot{tok}/getMe', timeout=10)
    d = json.loads(r.read())
    print('OK:' + d['result'].get('username', '') if d.get('ok') else 'FAIL_OTHER:bad response')
except urllib.error.HTTPError as e:
    print(f'FAIL_TOKEN:HTTP {e.code} {e.reason}')
except urllib.error.URLError as e:
    print(f'FAIL_NET:{e.reason}')
except Exception as e:
    print(f'FAIL_OTHER:{type(e).__name__}:{e}')
PYEOF
)
    case "$RES" in
        OK:*) BOT_USERNAME="${RES#OK:}"; echo "  ✅ Токен валиден. Бот: @${BOT_USERNAME}"; break ;;
        *) echo "  ❌ Невалидный токен: $RES" ;;
    esac
done

echo ""
printf "Ваш Chat ID (узнать у @userinfobot): "
read CHAT_ID
CHAT_ID=$(echo "$CHAT_ID" | tr -d ' ')
[ -z "$CHAT_ID" ] && echo "❌ Пустой Chat ID. Выход." && exit 1
echo "  ✅ Chat ID: $CHAT_ID"

# удаляем возможный вебхук
TG_TOKEN="$TOKEN" /opt/bin/python3 - << 'PYEOF' 2>/dev/null || true
import os, urllib.request
tok = os.environ['TG_TOKEN']
urllib.request.urlopen(f'https://api.telegram.org/bot{tok}/deleteWebhook', timeout=10)
PYEOF

echo ""
printf "→ Отправляю тестовое сообщение в чат... "
TEST_RES=$(TG_TOKEN="$TOKEN" TG_CHAT="$CHAT_ID" /opt/bin/python3 - << 'PYEOF'
import os, json, urllib.request, urllib.parse
tok = os.environ['TG_TOKEN']
chat = os.environ['TG_CHAT']
try:
    data = urllib.parse.urlencode({
        'chat_id': chat,
        'text': '✅ Router Bot: тестовое сообщение. Chat ID указан верно.',
    }).encode()
    r = urllib.request.urlopen(
        f'https://api.telegram.org/bot{tok}/sendMessage',
        data=data, timeout=10,
    )
    d = json.loads(r.read())
    print('OK' if d.get('ok') else 'FAIL:' + d.get('description', ''))
except Exception as e:
    print('FAIL:' + str(e)[:100])
PYEOF
)
case "$TEST_RES" in
    OK) echo "✅ доставлено" ;;
    *)
        echo "❌ $TEST_RES"
        echo "  Причины: неверный Chat ID, или вы не нажали /start у бота @${BOT_USERNAME}"
        printf "  Продолжить всё равно? (y/N): "
        read ANS
        [ "$ANS" = "y" ] || [ "$ANS" = "Y" ] || exit 1
        ;;
esac

# ---------- 7. Доп. параметры ----------
echo ""
echo "────────────────────────────────────────────"
echo "  Дополнительно (Enter = по умолчанию)"
echo "────────────────────────────────────────────"

printf "Интервал опроса ndmc, сек [5]: "; read POLL
[ -z "$POLL" ] && POLL=5

printf "Heartbeat, сек (0 = выкл) [3600]: "; read HB
[ -z "$HB" ] && HB=3600

printf "Искать вендора по MAC (on/off) [on]: "; read VENDOR
[ -z "$VENDOR" ] && VENDOR=on

# ---------- 8. Запись config.env ----------
mkdir -p "$BASE_DIR" "$LOG_DIR" "$INIT_DIR" "$BASE_DIR/data" "$BASE_DIR/data/net_watch" "$BASE_DIR/data/ssh_control" "$BASE_DIR/data/xkeen" "$BASE_DIR/data/bird" "$BASE_DIR/data/hydraroute" "$BASE_DIR/data/mtproxy" "$BASE_DIR/data/keen_pbr" "$BASE_DIR/data/neofit" "$BASE_DIR/data/usque_keenetic" "$BASE_DIR/data/awg_manager"

cat > "$BASE_DIR/config.env" << EOF
# Router Bot — конфиг
# Сгенерирован $(date '+%Y-%m-%d %H:%M:%S')

TG_BOT_TOKEN='$TOKEN'
TG_CHAT_ID='$CHAT_ID'

# Модули (через запятую)
ENABLED_MODULES='$ENABLED'

# Net Watch
POLL_INTERVAL=$POLL
HEARTBEAT_INTERVAL=$HB
VENDOR_LOOKUP=$VENDOR
NDMC_PATH=/bin/ndmc

# Сеть
WAN_IF='$WAN_IF'
WAN_SRC='$WAN_SRC'
ROUTE_TABLE='$WAN_TABLE'

# VPN для Telegram
USE_VPN='$USE_VPN'
VPN_IF='$VPN_IF'
VPN_SRC='$VPN_SRC'

# IPv6 (yes = отключён, только IPv4)
DISABLE_IPV6='$DISABLE_IPV6'

# AWG Manager MCP-токен (получить в веб-интерфейсе AWG Manager)
AWG_MCP_TOKEN=''
EOF
chmod 600 "$BASE_DIR/config.env"
cp -p "$BASE_DIR/config.env" "$BASE_DIR/config.env.bak"
chmod 600 "$BASE_DIR/config.env.bak"
echo "✅ config.env (+ backup)"

# =================== продолжение в следующей части ===================

# ---------- 9. init: S97tgroutes ----------
cat > "$INIT_DIR/S97tgroutes" << 'EOF97'
#!/bin/sh
# Маршруты Telegram через VPN-туннель.
# WAN_IF и WAN_SRC определяются автоматически.
. /opt/router_bot/config.env

[ "$USE_VPN" = "yes" ] || exit 0
[ -n "$VPN_IF" ] || exit 0
[ -n "$VPN_SRC" ] || exit 0
[ -n "$ROUTE_TABLE" ] || ROUTE_TABLE="16385"
WAN_IF_CFG="${WAN_IF:-}"

TG_NETS="149.154.166.110 149.154.160.0/20 91.108.4.0/22"

# Определяет активный WAN-интерфейс: сначала из config.env,
# потом из default route (исключая VPN-туннели).
get_wan_if() {
    # 1. Из config.env — если интерфейс есть, с IPv4 и не VPN
    if [ -n "$WAN_IF_CFG" ] && \
       [ "$WAN_IF_CFG" != "$VPN_IF" ] && \
       ip -4 -o addr show dev "$WAN_IF_CFG" 2>/dev/null | grep -q ' inet '; then
        echo "$WAN_IF_CFG"
        return 0
    fi
    # 2. default via <gw> dev <iface> — настоящий WAN
    local ifc
    ifc=$(ip route show default 2>/dev/null \
        | grep " via " | head -1 \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    if [ -n "$ifc" ] && [ "$ifc" != "$VPN_IF" ]; then
        echo "$ifc"
        return 0
    fi
    # 3. Fallback: default dev <iface> без via
    ifc=$(ip route show default 2>/dev/null | head -1 \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    if [ -n "$ifc" ] && [ "$ifc" != "$VPN_IF" ]; then
        echo "$ifc"
        return 0
    fi
    return 1
}

get_wan_src() {
    local iface="$1"
    [ -n "$iface" ] || return 1
    ip -4 -o addr show dev "$iface" 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 | head -1
}

rebuild_rules() {
    local WAN_IF_NOW WAN_SRC_NOW

    WAN_IF_NOW=$(get_wan_if) || return 1
    WAN_SRC_NOW=$(get_wan_src "$WAN_IF_NOW")
    [ -n "$WAN_SRC_NOW" ] || return 1

    # обновляем config.env если WAN_IF/ WAN_SRC изменились
    if [ "$WAN_IF_NOW" != "$WAN_IF_CFG" ] || [ "$WAN_SRC_NOW" != "$WAN_SRC" ]; then
        sed -i "s|^WAN_IF=.*|WAN_IF='$WAN_IF_NOW'|" /opt/router_bot/config.env 2>/dev/null || true
        sed -i "s|^WAN_SRC=.*|WAN_SRC='$WAN_SRC_NOW'|" /opt/router_bot/config.env 2>/dev/null || true
        echo "WAN detected: $WAN_IF_NOW ($WAN_SRC_NOW)"
    fi

    # чистка старых правил
    for src in $(ip rule show | awk -v tbl="$ROUTE_TABLE" '$0 ~ "lookup " tbl " " {for(i=1;i<=NF;i++) if($i=="from") print $(i+1)}'); do
        case "$src" in
            [0-9]*) ip rule del from "$src" lookup "$ROUTE_TABLE" 2>/dev/null || true ;;
        esac
    done
    for net in $TG_NETS; do
        _i=0
        while [ "$_i" -lt 10 ]; do
            ip rule del to "$net" 2>/dev/null || break
            _i=$((_i+1))
        done
        ip route del "$net" 2>/dev/null || true
        ip route del "$net" table "$ROUTE_TABLE" 2>/dev/null || true
    done

    # source-based
    ip rule add from "$WAN_SRC_NOW" lookup "$ROUTE_TABLE" priority 1152 2>/dev/null || true

    # to-based (независимо от source)
    p=1100
    for net in $TG_NETS; do
        ip rule add to "$net" lookup "$ROUTE_TABLE" priority $p 2>/dev/null || true
        p=$((p+1))
    done

    # маршруты
    for net in $TG_NETS; do
        ip route replace "$net" dev "$VPN_IF" src "$VPN_SRC" table "$ROUTE_TABLE" 2>/dev/null || true
    done
}

case "$1" in
  start)   sleep 20; rebuild_rules || exit 0 ;;
  stop)
    for net in $TG_NETS; do
        _i=0
        while [ "$_i" -lt 10 ]; do
            ip rule del to "$net" 2>/dev/null || break
            _i=$((_i+1))
        done
        ip route del "$net" 2>/dev/null || true
        ip route del "$net" table "$ROUTE_TABLE" 2>/dev/null || true
    done
    for src in $(ip rule show | awk -v tbl="$ROUTE_TABLE" '$0 ~ "lookup " tbl " " {for(i=1;i<=NF;i++) if($i=="from") print $(i+1)}'); do
        case "$src" in
            [0-9]*) ip rule del from "$src" lookup "$ROUTE_TABLE" 2>/dev/null || true ;;
        esac
    done
    ;;
  rebuild) rebuild_rules ;;
  *) echo "Usage: $0 {start|stop|rebuild}"; exit 1 ;;
esac
EOF97
    chmod +x "$INIT_DIR/S97tgroutes"
mkdir -p /opt/router_bot/init
cp -f "$INIT_DIR/S97tgroutes" /opt/router_bot/init/S97tgroutes
echo "✅ S97tgroutes"

# ---------- 10. wrapper в /opt/bin ----------
echo "→ Устанавливаю routerbot_wrapper.sh..."
if [ -f "$BASE_DIR/core/wrapper.sh" ]; then
    cp -f "$BASE_DIR/core/wrapper.sh" /opt/bin/routerbot_wrapper.sh
    chmod +x /opt/bin/routerbot_wrapper.sh
    echo "✅ /opt/bin/routerbot_wrapper.sh"
else
    echo "⚠️  wrapper.sh не найден в $BASE_DIR/core/ — использую python напрямую"
fi
echo ""

# ---------- 10b. init: S98routerbot ----------
cat > "$INIT_DIR/S98routerbot" << 'EOF98'
#!/bin/sh
PROG=/opt/bin/routerbot_wrapper.sh
ARGS=""
PIDFILE=/var/run/routerbot.pid

kill_all_routerbot() {
    PIDS=$(ps w | grep -E "routerbot_wrapper|router_bot/main.py" | grep -v grep | awk '{print $1}')
    for p in $PIDS; do
        kill "$p" 2>/dev/null
    done
    sleep 1
    PIDS=$(ps w | grep "router_bot/main.py" | grep -v grep | awk '{print $1}')
    for p in $PIDS; do
        kill -9 "$p" 2>/dev/null
    done
    # Зачищаем осиротевшие Flashkeen (pty-сессии)
    PIDS=$(ps w | grep "/opt/bin/sh /opt/bin/flashkeen" | grep -v grep | awk '{print $1}')
    for p in $PIDS; do
        kill -9 "$p" 2>/dev/null
    done
    # И другие flashkeen-процессы, если остались
    PIDS=$(ps w | grep "flashkeen" | grep -v grep | grep -v "S98routerbot" | awk '{print $1}')
    for p in $PIDS; do
        kill -9 "$p" 2>/dev/null
    done
}

# S98 auto-copy wrapper: если исходник в /opt/router_bot/core/wrapper.sh
# новее рабочей копии в /opt/bin/routerbot_wrapper.sh — обновить.
if [ -f /opt/router_bot/core/wrapper.sh ] && [ -x /opt/bin/routerbot_wrapper.sh ]; then
    if [ /opt/router_bot/core/wrapper.sh -nt /opt/bin/routerbot_wrapper.sh ]; then
        cp -f /opt/router_bot/core/wrapper.sh /opt/bin/routerbot_wrapper.sh
        chmod +x /opt/bin/routerbot_wrapper.sh
        echo "wrapper.sh updated from /opt/router_bot/core/"
    fi
fi

case "$1" in
  start)
    if [ -f /var/run/routerbot.giveup ]; then
      echo "Router Bot is in GIVEUP state (too many failures)."
      echo "  Reset: rm /var/run/routerbot.giveup && $0 restart"
      exit 1
    fi
    if [ -f "$PIDFILE" ] && kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
      echo "Already running (PID $(cat $PIDFILE))"; exit 0
    fi
    kill_all_routerbot
    sleep 1
    echo "Starting Router Bot..."
    start-stop-daemon -S -b -m -p "$PIDFILE" -x "$PROG" -- $ARGS
    ;;
  stop)
    echo "Stopping Router Bot..."
    start-stop-daemon -K -p "$PIDFILE" 2>/dev/null
    kill_all_routerbot
    rm -f "$PIDFILE"
    ;;
  restart) rm -f /var/run/routerbot.giveup; $0 stop; sleep 3; $0 start ;;
  reset)
    rm -f /var/run/routerbot.giveup
    echo "Giveup marker removed. Now run: $0 start"
    ;;
  *) echo "Usage: $0 {start|stop|restart|reset}"; exit 1 ;;
esac
EOF98
chmod +x "$INIT_DIR/S98routerbot"
mkdir -p /opt/router_bot/init
cp -f "$INIT_DIR/S98routerbot" /opt/router_bot/init/S98routerbot
echo "✅ S98routerbot"

# ---------- 11. init: S99routerbot_health ----------
cat > "$INIT_DIR/S99routerbot_health" << 'EOF99'
#!/bin/sh
. /opt/router_bot/config.env

# Если wrapper сдался (много падений подряд) — не пинать
[ -f /var/run/routerbot.giveup ] && exit 0

PIDFILE=/var/run/routerbot.pid
STATE=/var/run/routerbot.fail

# 0. Автодетект WAN IP
if [ "$USE_VPN" = "yes" ] && [ -n "$VPN_IF" ]; then
    # автодетект WAN-интерфейса
    WAN_IF_NOW=""
    if [ -n "$WAN_IF" ] && ip -4 -o addr show dev "$WAN_IF" 2>/dev/null | grep -q ' inet '; then
        WAN_IF_NOW="$WAN_IF"
    else
        WAN_IF_NOW=$(ip route show default 2>/dev/null \
            | awk '/^default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
        [ -n "$WAN_IF_NOW" ] && [ "$WAN_IF_NOW" = "$VPN_IF" ] && WAN_IF_NOW=""
        echo "$WAN_IF_NOW" | grep -qE '^(opkgtun|nwg|wg|tun)' && WAN_IF_NOW=""
    fi
    WAN_SRC_NOW=""
    [ -n "$WAN_IF_NOW" ] && WAN_SRC_NOW=$(ip -4 -o addr show dev "$WAN_IF_NOW" 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 | head -1)
    if [ -n "$WAN_SRC_NOW" ] && [ "$WAN_SRC_NOW" != "$WAN_SRC" ]; then
        echo "WAN IP changed: $WAN_SRC -> $WAN_SRC_NOW"
        sed -i "s|^WAN_SRC=.*|WAN_SRC='$WAN_SRC_NOW'|" /opt/router_bot/config.env 2>/dev/null || true
        sed -i "s|^WAN_IF=.*|WAN_IF='$WAN_IF_NOW'|" /opt/router_bot/config.env 2>/dev/null || true
        WAN_SRC="$WAN_SRC_NOW"
        /opt/etc/init.d/S97tgroutes rebuild >/dev/null 2>&1 || true
    fi
fi

# 1. Маршруты Telegram
if [ "$USE_VPN" = "yes" ] && [ -n "$VPN_IF" ] && [ -n "$WAN_SRC" ]; then
    if ! ip route get 149.154.166.110 from "$WAN_SRC" 2>/dev/null | grep -q "$VPN_IF"; then
        echo "Restoring Telegram routes via $VPN_IF..."
        /opt/etc/init.d/S97tgroutes rebuild >/dev/null 2>&1 || true
    fi
fi

# 2. resolv.conf
if ! grep -q nameserver /etc/resolv.conf 2>/dev/null; then
    printf 'nameserver 127.0.0.1\nnameserver 8.8.8.8\noptions timeout:1 attempts:1 rotate\n' > /etc/resolv.conf
fi

# 3. Проверка связи с Telegram
TG=$(sed -n "s/^TG_BOT_TOKEN='\(.*\)'/\1/p" /opt/router_bot/config.env)
_c4=""
if [ "$DISABLE_IPV6" = "yes" ]; then
    _c4="-4"
fi

# Проверяем именно HTTP-код (любой ответ = сеть жива)
_http_code=$(/opt/bin/curl $_c4 -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "https://api.telegram.org/bot${TG}/getMe")

if [ "$_http_code" -ge 200 ] && [ "$_http_code" -lt 500 ]; then
    rm -f "$STATE"
else
    COUNT=$(cat "$STATE" 2>/dev/null || echo 0)
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$STATE"
    echo "Telegram unreachable (HTTP code: $_http_code, failure $COUNT)"
    if [ "$COUNT" -ge 3 ]; then
        rm -f "$STATE"
        /opt/etc/init.d/S98routerbot restart
    fi
    exit 0
fi

# 4. Процесс мёртв — перезапустить
if [ -f "$PIDFILE" ] && kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
    exit 0
fi

echo "Bot process is dead, restarting..."
/opt/etc/init.d/S98routerbot restart
EOF99
chmod +x "$INIT_DIR/S99routerbot_health"
mkdir -p /opt/router_bot/init
cp -f "$INIT_DIR/S99routerbot_health" /opt/router_bot/init/S99routerbot_health
echo "✅ S99routerbot_health"

# ---------- 12. logrotate ----------
mkdir -p /opt/etc/logrotate.d
cat > /opt/etc/logrotate.d/router_bot << EOF
$LOG_DIR/router_bot.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
echo "✅ logrotate"

# ---------- 13b. ensure_init (перезапись с case status) ----------
sh /opt/router_bot/ensure_init.sh

# ---------- 13. cron ----------
CRON_FILE="/opt/etc/crontab"
if [ -f "$CRON_FILE" ]; then
    grep -v "S99routerbot_health" "$CRON_FILE" > "$CRON_FILE.tmp" 2>/dev/null || true
    mv "$CRON_FILE.tmp" "$CRON_FILE" 2>/dev/null || true
    echo "*/1 * * * * /opt/etc/init.d/S99routerbot_health" >> "$CRON_FILE"
    echo "✅ cron: healthcheck раз в минуту"
fi

# ---------- 15. Запуск ----------
echo ""
echo "→ Запускаю Router Bot..."

if [ "$USE_VPN" = "yes" ]; then
    /opt/etc/init.d/S97tgroutes start >/dev/null 2>&1 || true
fi

_RB_START_RC=0; /opt/etc/init.d/S98routerbot start || _RB_START_RC=$?
sleep 5
if [ -f /var/run/routerbot.pid ] && kill -0 "$(cat /var/run/routerbot.pid)" 2>/dev/null; then
    echo "✅ Router Bot запущен (PID $(cat /var/run/routerbot.pid))"
else
    echo "⚠️  Router Bot не запустился. Проверьте:"
    echo "     tail -50 $LOG_DIR/router_bot.log"
    if [ "$_RB_START_RC" -ne 0 ]; then
        echo "     (S98routerbot start вернул код $_RB_START_RC)"
    fi
fi

# ---------- 16. Итог ----------
echo ""
echo "════════════════════════════════════════════"
echo "  ✅ Установка завершена"
echo "════════════════════════════════════════════"
echo ""
echo "  Модули:     $ENABLED"
echo "  WAN:        $WAN_IF ($WAN_SRC)"
if [ "$USE_VPN" = "yes" ]; then
    echo "  VPN:        $VPN_IF ($VPN_SRC) → table $WAN_TABLE"
else
    echo "  VPN:        не используется"
fi
echo ""
echo "  Проверьте Telegram — бот должен прислать приветствие."
echo "  Если нет — напишите боту /start."
echo ""
echo "  Управление:  /opt/etc/init.d/S98routerbot {start|stop|restart}"
echo "  Логи:        tail -f $LOG_DIR/router_bot.log"
echo "  Удаление:    $BASE_DIR/uninstall.sh"
echo ""
RB_INSTALL_SH_EOF

echo "  → uninstall.sh"
cat > /opt/router_bot/uninstall.sh << 'RB_UNINSTALL_SH_EOF'
#!/bin/sh
BASE_DIR="/opt/router_bot"
LOG_DIR="/opt/var/log"
INIT_DIR="/opt/etc/init.d"
CROTAB="/opt/etc/crontab"

echo ""
echo "════════════════════════════════════════════"
echo "  Router Bot — удаление"
echo "════════════════════════════════════════════"
echo ""

# ---------- 1. Читаем config.env ----------
USE_VPN="no"
VPN_IF=""
VPN_SRC=""
ROUTE_TABLE="main"
WAN_SRC=""

if [ -f "$BASE_DIR/config.env" ]; then
    . "$BASE_DIR/config.env"
fi

# ---------- 2. Остановка бота ----------
echo "→ Останавливаю бота..."
/opt/etc/init.d/S98routerbot stop 2>/dev/null || true
for p in $(ps w | grep "router_bot/main.py" | grep -v grep | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null
done
# чистим осиротевшие flashkeen
for p in $(ps w | grep "flashkeen" | grep -v grep | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null
done
sleep 1

# ---------- 2b. Остановка сервисов (auto) ----------
echo "→ Останавливаю сервисы модулей..."
if [ -x /opt/bin/python3 ] && [ -f /opt/router_bot/core/uninstall_helper.py ]; then
    /opt/bin/python3 /opt/router_bot/core/uninstall_helper.py --init 2>/dev/null | while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        [ -x "$INIT_DIR/$svc" ] && "$INIT_DIR/$svc" stop 2>/dev/null || true
    done
fi
sleep 1
# Fallback: kill по имени процесса для модулей без надёжного init
for proc in "[h]rneo" "[h]rweb" "[t]g-ws-proxy" "[n]eofit" \
            "[a]wg-manager" "[u]sque" "[k]een-pbr"; do
    for _p in $(ps w | grep -E "$proc" | grep -v grep | awk '{print $1}'); do
        kill -9 "$_p" 2>/dev/null || true
    done
done
sleep 1

# ---------- 3. Cron ----------
echo "→ Отключаю cron healthcheck..."
if [ -f "$CROTAB" ]; then
    grep -v "S99routerbot_health" "$CROTAB" > "${CROTAB}.tmp" 2>/dev/null || true
    mv "${CROTAB}.tmp" "$CROTAB" 2>/dev/null || true
fi

# ---------- 4. Маршруты Telegram ----------
if [ "$USE_VPN" = "yes" ] && [ -n "$VPN_IF" ]; then
    echo "→ Удаляю маршруты Telegram из table $ROUTE_TABLE..."
    ip route del 149.154.160.0/20 table "$ROUTE_TABLE" 2>/dev/null || true
    ip route del 91.108.4.0/22   table "$ROUTE_TABLE" 2>/dev/null || true
    ip route del 149.154.166.110 table "$ROUTE_TABLE" 2>/dev/null || true
fi

# ---------- 5. init-скрипты ----------
echo "→ Удаляю init-скрипты..."
/opt/etc/init.d/S97tgroutes stop 2>/dev/null || true
rm -f "$INIT_DIR/S97tgroutes"
rm -f "$INIT_DIR/S98routerbot"
rm -f /opt/bin/routerbot_wrapper.sh
rm -f "$INIT_DIR/S99routerbot_health"

# ---------- 6. logrotate + PID ----------
rm -f /opt/etc/logrotate.d/router_bot
rm -f /var/run/routerbot.pid /var/run/routerbot.fail

# ---------- 7. Данные и логи ----------
echo ""
echo "Файлы программы:"
echo "  • $BASE_DIR (модули, конфиг, данные)"
echo "  • $LOG_DIR/router_bot.log"
# --- Чистка файлов модулей (auto) ---
if [ -x /opt/bin/python3 ] && [ -f /opt/router_bot/core/uninstall_helper.py ]; then
    /opt/bin/python3 /opt/router_bot/core/uninstall_helper.py --init 2>/dev/null | while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        [ -x "$INIT_DIR/$svc" ] && "$INIT_DIR/$svc" stop 2>/dev/null || true
        rm -f "$INIT_DIR/$svc"
    done
    /opt/bin/python3 /opt/router_bot/core/uninstall_helper.py --paths 2>/dev/null | while IFS= read -r _p; do
        [ -z "$_p" ] && continue
        [ -e "$_p" ] && rm -rf "$_p"
    done
    echo "OK: внешние файлы очищены"
else
    echo "WARN: uninstall_helper.py не найден"
fi
echo ""
if [ -d "$BASE_DIR/data" ]; then
    rm -rf "$BASE_DIR/data/"*
    echo "OK: данные модулей очищены"
fi
echo ""

echo ""

echo ""
printf "Удалить эти файлы? (y/N): "
read ANS

if [ "$ANS" = "y" ] || [ "$ANS" = "Y" ]; then
    echo "→ Чищу данные новых модулей..."
    rm -rf "$BASE_DIR/data/hydraroute"
    rm -rf "$BASE_DIR/data/mtproxy"
    rm -rf "$BASE_DIR/data/keen_pbr"
    rm -rf "$BASE_DIR/data/neofit"
    rm -rf "$BASE_DIR/data/usque_keenetic"
    rm -f /opt/etc/HydraRoute/hrneo.conf.bak.*
    rm -rf "$BASE_DIR"
    rm -f "$LOG_DIR/router_bot.log"*
    echo "✅ Данные и логи удалены"
else
    echo "⚠️  Данные сохранены: $BASE_DIR"
fi

# ---------- 7b. Удаление /opt/etc/<module> (auto) ----------
_etc_mods=""
if [ -x /opt/bin/python3 ] && [ -f /opt/router_bot/core/uninstall_helper.py ]; then
    _etc_mods=$(/opt/bin/python3 /opt/router_bot/core/uninstall_helper.py --etc 2>/dev/null | while IFS= read -r _p; do
        [ -e "$_p" ] && echo "$_p"
    done | tr "\n" " ")
fi
if [ -n "$_etc_mods" ]; then
    echo ""
    echo "────────────────────────────────────────────"
    echo "  Конфиги модулей"
    echo "────────────────────────────────────────────"
    echo ""
    echo "Найдены каталоги с настройками:"
    for _d in $_etc_mods; do
        echo "  • $_d"
    done
    echo ""
    echo "⚠️  Это ваши личные настройки (правила, прокси, токены)."
    echo "    Удаляйте только если уверены, что не будете переустанавливать модули."
    echo ""
    printf "Удалить эти конфиги? (y/N): "
    read DEL_ETC
    if [ "$DEL_ETC" = "y" ] || [ "$DEL_ETC" = "Y" ]; then
        for _d in $_etc_mods; do
            rm -rf "$_d"
            echo "  ✓ удалён $_d"
        done
    else
        echo "  Конфиги модулей сохранены."
    fi
fi

# =================== продолжение в следующей части ===================

# ---------- 8. Зависимости ----------
echo ""
echo "────────────────────────────────────────────"
echo "  Зависимости"
echo "────────────────────────────────────────────"
echo ""

INSTALLED=""

if [ -x /opt/bin/python3 ] && /opt/bin/python3 -c "import telegram" 2>/dev/null; then
    V=$(/opt/bin/python3 -c "import telegram; print(telegram.__version__)" 2>/dev/null)
    INSTALLED="$INSTALLED\n    • python-telegram-bot (v$V) — pip-пакет"
fi

for pkg_bin in \
    "python3:/opt/bin/python3" \
    "python3-pip:/opt/bin/pip3" \
    "curl:/opt/bin/curl" \
    "ca-certificates:/opt/etc/ssl/certs/ca-certificates.crt" \
    "openssh-client:/opt/bin/ssh" \
    "openssh-client-utils:/opt/bin/ssh-keyscan" \
    "openssh-keygen:/opt/bin/ssh-keygen"
do
    pkg="${pkg_bin%%:*}"
    bin="${pkg_bin#*:}"
    if [ -e "$bin" ]; then
        INSTALLED="$INSTALLED\n    • $pkg — opkg-пакет"
    fi
done

if [ -z "$INSTALLED" ]; then
    echo "Ничего из наших зависимостей не найдено."
else
    echo "Установлено:"
    printf "$INSTALLED\n"
    echo ""
    echo "⚠️  ВНИМАНИЕ: python3, curl, openssh могут использоваться"
    echo "    другими программами. Если не уверены — откажитесь."
    echo ""
    printf "Удалить их тоже? (y/N): "
    read DEL_DEPS

    if [ "$DEL_DEPS" = "y" ] || [ "$DEL_DEPS" = "Y" ]; then
        echo ""
        echo "→ Удаляю pip-пакет..."
        /opt/bin/pip3 uninstall -y python-telegram-bot 2>/dev/null || true

        echo "→ Удаляю opkg-пакеты..."
        opkg remove openssh-client-utils 2>/dev/null || true
        opkg remove openssh-keygen 2>/dev/null || true
        opkg remove openssh-client 2>/dev/null || true
        opkg remove python3-pip 2>/dev/null || true
        opkg remove curl 2>/dev/null || true
        opkg remove ca-certificates 2>/dev/null || true

        echo ""
        printf "Удалить python3? Может использоваться другими скриптами. (y/N): "
        read DEL_PY
        if [ "$DEL_PY" = "y" ] || [ "$DEL_PY" = "Y" ]; then
            opkg remove python3 2>/dev/null || true
        else
            echo "  python3 оставлен."
        fi
        echo "✅ Зависимости удалены (по выбору)"
    else
        echo "  Зависимости оставлены."
    fi
fi

# ---------- 9. resolv.conf ----------
if [ -f /etc/resolv.conf ]; then
    if grep -q "^nameserver 8.8.8.8" /etc/resolv.conf 2>/dev/null; then
        echo ""
        printf "Убрать nameserver 8.8.8.8 из /etc/resolv.conf? (y/N): "
        read DEL_DNS
        if [ "$DEL_DNS" = "y" ] || [ "$DEL_DNS" = "Y" ]; then
            grep -v "^nameserver 8.8.8.8" /etc/resolv.conf > /etc/resolv.conf.tmp 2>/dev/null || true
            mv /etc/resolv.conf.tmp /etc/resolv.conf 2>/dev/null || true
            echo "  ✅ DNS обновлён"
        fi
    fi
fi

# ---------- 10. Итог ----------
echo ""
echo "════════════════════════════════════════════"
echo "  ✅ Удаление завершено"
echo "════════════════════════════════════════════"
echo ""
echo "  Если отказались удалять зависимости —"
echo "  они остались в системе."
echo ""
RB_UNINSTALL_SH_EOF

echo "  → core/wrapper.sh"
cat > /opt/router_bot/core/wrapper.sh << 'RB_CORE_WRAPPER_SH_EOF'
#!/bin/sh
LOG=/opt/var/log/router_bot.log
GIVEUP=/var/run/routerbot.giveup
MAX_FAILS=10
FAILS=0

# Если маркер есть — не запускаться
if [ -f "$GIVEUP" ]; then
    echo "$(date '+%F %T') wrapper: giveup marker present, exit" >> "$LOG"
    exit 0
fi

# Проверка/восстановление config.env.
#  - если файл отсутствует и есть бэкап: восстановить
#  - если файл новее бэкапа: обновить бэкап
#  - если файла нет и бэкапа нет: GIVEUP (запускать бессмысленно)
check_config() {
    CONF=/opt/router_bot/config.env
    BAK=/opt/router_bot/config.env.bak
    if [ -f "$CONF" ]; then
        if [ ! -f "$BAK" ] || [ "$CONF" -nt "$BAK" ]; then
            cp -p "$CONF" "$BAK" 2>/dev/null || true
        fi
        return 0
    fi
    if [ -f "$BAK" ]; then
        cp -p "$BAK" "$CONF"
        chmod 600 "$CONF"
        echo "$(date '+%F %T') wrapper: config.env restored from backup" >> "$LOG"
        return 0
    fi
    echo "$(date '+%F %T') wrapper: CRITICAL: config.env missing and no backup" >> "$LOG"
    echo "$(date '+%F %T') wrapper: run 'rb config init' or reinstall" >> "$LOG"
    touch "$GIVEUP"
    return 1
}

check_config || exit 1

# Ждём DNS готовности
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
    if /opt/bin/python3 -c "import socket; socket.gethostbyname('api.telegram.org')" >/dev/null 2>&1; then
        echo "$(date '+%F %T') wrapper: DNS OK" >> "$LOG"
        break
    fi
    sleep 5
done

while true; do
    if [ -f "$GIVEUP" ]; then
        echo "$(date '+%F %T') wrapper: giveup marker detected, stopping" >> "$LOG"
        exit 0
    fi

    check_config || exit 1
    echo "$(date '+%F %T') wrapper: Starting bot..." >> "$LOG"
    T0=$(date +%s)
    /opt/bin/python3 /opt/router_bot/main.py >> "$LOG" 2>&1
    T1=$(date +%s)
    RUNTIME=$((T1 - T0))

    if [ "$RUNTIME" -lt 60 ]; then
        FAILS=$((FAILS + 1))
        echo "$(date '+%F %T') wrapper: Bot died after ${RUNTIME}s (fail $FAILS/$MAX_FAILS)" >> "$LOG"
        if [ "$FAILS" -ge "$MAX_FAILS" ]; then
            echo "$(date '+%F %T') wrapper: GIVE UP after $FAILS quick failures" >> "$LOG"
            echo "$(date '+%F %T') wrapper: Marker: $GIVEUP" >> "$LOG"
            echo "$(date '+%F %T') wrapper: To reset: rm $GIVEUP && /opt/etc/init.d/S98routerbot restart" >> "$LOG"
            touch "$GIVEUP"
            exit 1
        fi
    else
        if [ "$FAILS" -gt 0 ]; then
            echo "$(date '+%F %T') wrapper: Bot ran ${RUNTIME}s, counter reset (was $FAILS)" >> "$LOG"
        fi
        FAILS=0
        echo "$(date '+%F %T') wrapper: Bot died after ${RUNTIME}s, restart in 10s" >> "$LOG"
    fi
    sleep 10
done
RB_CORE_WRAPPER_SH_EOF

echo "  → restore_init.sh"
cat > /opt/router_bot/restore_init.sh << 'RB_RESTORE_INIT_EOF'
#!/bin/sh
# Восстанавливает отсутствующие init-скрипты и вспомогательные конфиги.
# Трогает только те файлы, которых нет. Идемпотентен.

RESTORE_ANY=0

for _f in S98routerbot S99routerbot_health S97tgroutes; do
    if [ -f "/opt/router_bot/init/$_f" ] && [ ! -f "/opt/etc/init.d/$_f" ]; then
        mkdir -p /opt/etc/init.d
        cp -f "/opt/router_bot/init/$_f" "/opt/etc/init.d/$_f"
        chmod +x "/opt/etc/init.d/$_f"
        echo "  + /opt/etc/init.d/$_f"
        RESTORE_ANY=1
    fi
done

if [ -f /opt/router_bot/core/wrapper.sh ] && [ ! -x /opt/bin/routerbot_wrapper.sh ]; then
    mkdir -p /opt/bin
    cp -f /opt/router_bot/core/wrapper.sh /opt/bin/routerbot_wrapper.sh
    chmod +x /opt/bin/routerbot_wrapper.sh
    echo "  + /opt/bin/routerbot_wrapper.sh"
    RESTORE_ANY=1
fi

if [ ! -f /opt/etc/logrotate.d/router_bot ]; then
    mkdir -p /opt/etc/logrotate.d
    cat > /opt/etc/logrotate.d/router_bot << 'LREOF'
/opt/var/log/router_bot.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LREOF
    echo "  + /opt/etc/logrotate.d/router_bot"
    RESTORE_ANY=1
fi

if [ -f /opt/etc/crontab ] && ! grep -q "S99routerbot_health" /opt/etc/crontab; then
    echo "*/1 * * * * /opt/etc/init.d/S99routerbot_health" >> /opt/etc/crontab
    echo "  + cron healthcheck"
    RESTORE_ANY=1
fi

if [ "$RESTORE_ANY" = "0" ]; then
    echo "  ✅ Все init-скрипты на месте"
fi
RB_RESTORE_INIT_EOF

echo "  → ensure_init.sh"
cat > /opt/router_bot/ensure_init.sh << 'RB_ENSURE_INIT_SH_EOF'
#!/bin/sh
# Идемпотентно создаёт init-скрипты, logrotate, cron.
# Вызывается из install.sh в обоих режимах (install и reinstall).

INIT_DIR=/opt/etc/init.d
BOT_INIT=/opt/router_bot/init
LOG_DIR=/opt/var/log

mkdir -p "$INIT_DIR" "$BOT_INIT" "$LOG_DIR"

# ============ S97tgroutes ============
cat > "$INIT_DIR/S97tgroutes" << 'EOF97'
#!/bin/sh
# Маршруты Telegram через VPN-туннель.
# WAN_IF и WAN_SRC определяются автоматически.
. /opt/router_bot/config.env

[ "$USE_VPN" = "yes" ] || exit 0
[ -n "$VPN_IF" ] || exit 0
[ -n "$VPN_SRC" ] || exit 0
[ -n "$ROUTE_TABLE" ] || ROUTE_TABLE="16385"
WAN_IF_CFG="${WAN_IF:-}"

TG_NETS="149.154.166.110 149.154.160.0/20 91.108.4.0/22"

get_wan_if() {
    if [ -n "$WAN_IF_CFG" ] && \
       ip link show "$WAN_IF_CFG" >/dev/null 2>&1 && \
       ip -4 -o addr show dev "$WAN_IF_CFG" 2>/dev/null | grep -q ' inet '; then
        echo "$WAN_IF_CFG"
        return 0
    fi
    local ifc
    ifc=$(ip route show default 2>/dev/null \
        | awk '/^default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    if [ -n "$ifc" ] && [ "$ifc" != "$VPN_IF" ] \
       && ! echo "$ifc" | grep -qE '^(opkgtun|nwg|wg|tun)'; then
        echo "$ifc"
        return 0
    fi
    ifc=$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    if [ -n "$ifc" ] && [ "$ifc" != "$VPN_IF" ] \
       && ! echo "$ifc" | grep -qE '^(opkgtun|nwg|wg|tun)'; then
        echo "$ifc"
        return 0
    fi
    return 1
}

get_wan_src() {
    local iface="$1"
    [ -n "$iface" ] || return 1
    ip -4 -o addr show dev "$iface" 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 | head -1
}

rebuild_rules() {
    local WAN_IF_NOW WAN_SRC_NOW
    WAN_IF_NOW=$(get_wan_if) || return 1
    WAN_SRC_NOW=$(get_wan_src "$WAN_IF_NOW")
    [ -n "$WAN_SRC_NOW" ] || return 1

    if [ "$WAN_IF_NOW" != "$WAN_IF_CFG" ] || [ "$WAN_SRC_NOW" != "$WAN_SRC" ]; then
        sed -i "s|^WAN_IF=.*|WAN_IF='$WAN_IF_NOW'|" /opt/router_bot/config.env 2>/dev/null || true
        sed -i "s|^WAN_SRC=.*|WAN_SRC='$WAN_SRC_NOW'|" /opt/router_bot/config.env 2>/dev/null || true
        echo "WAN detected: $WAN_IF_NOW ($WAN_SRC_NOW)"
    fi

    for src in $(ip rule show | awk -v tbl="$ROUTE_TABLE" '$0 ~ "lookup " tbl " " {for(i=1;i<=NF;i++) if($i=="from") print $(i+1)}'); do
        case "$src" in
            [0-9]*) ip rule del from "$src" lookup "$ROUTE_TABLE" 2>/dev/null || true ;;
        esac
    done
    for net in $TG_NETS; do
        _i=0
        while [ "$_i" -lt 10 ]; do
            ip rule del to "$net" 2>/dev/null || break
            _i=$((_i+1))
        done
        ip route del "$net" 2>/dev/null || true
        ip route del "$net" table "$ROUTE_TABLE" 2>/dev/null || true
    done

    ip rule add from "$WAN_SRC_NOW" lookup "$ROUTE_TABLE" priority 1152 2>/dev/null || true
    p=1100
    for net in $TG_NETS; do
        ip rule add to "$net" lookup "$ROUTE_TABLE" priority $p 2>/dev/null || true
        p=$((p+1))
    done
    for net in $TG_NETS; do
        ip route replace "$net" dev "$VPN_IF" src "$VPN_SRC" table "$ROUTE_TABLE" 2>/dev/null || true
    done
}

case "$1" in
  start)   sleep 20; rebuild_rules || exit 0 ;;
  stop)
    for net in $TG_NETS; do
        _i=0
        while [ "$_i" -lt 10 ]; do
            ip rule del to "$net" 2>/dev/null || break
            _i=$((_i+1))
        done
        ip route del "$net" 2>/dev/null || true
        ip route del "$net" table "$ROUTE_TABLE" 2>/dev/null || true
    done
    for src in $(ip rule show | awk -v tbl="$ROUTE_TABLE" '$0 ~ "lookup " tbl " " {for(i=1;i<=NF;i++) if($i=="from") print $(i+1)}'); do
        case "$src" in
            [0-9]*) ip rule del from "$src" lookup "$ROUTE_TABLE" 2>/dev/null || true ;;
        esac
    done
    ;;
  rebuild) rebuild_rules ;;
  *) echo "Usage: $0 {start|stop|rebuild}"; exit 1 ;;
esac
EOF97
chmod +x "$INIT_DIR/S97tgroutes"
cp -f "$INIT_DIR/S97tgroutes" "$BOT_INIT/S97tgroutes"

# ============ S98routerbot (с case status) ============
cat > "$INIT_DIR/S98routerbot" << 'EOF98'
#!/bin/sh
PROG=/opt/bin/routerbot_wrapper.sh
ARGS=""
PIDFILE=/var/run/routerbot.pid

kill_all_routerbot() {
    PIDS=$(ps w | grep -E "routerbot_wrapper|router_bot/main.py" | grep -v grep | awk '{print $1}')
    for p in $PIDS; do kill "$p" 2>/dev/null; done
    sleep 1
    PIDS=$(ps w | grep "router_bot/main.py" | grep -v grep | awk '{print $1}')
    for p in $PIDS; do kill -9 "$p" 2>/dev/null; done
    PIDS=$(ps w | grep "/opt/bin/sh /opt/bin/flashkeen" | grep -v grep | awk '{print $1}')
    for p in $PIDS; do kill -9 "$p" 2>/dev/null; done
    PIDS=$(ps w | grep "flashkeen" | grep -v grep | grep -v "S98routerbot" | awk '{print $1}')
    for p in $PIDS; do kill -9 "$p" 2>/dev/null; done
}

if [ -f /opt/router_bot/core/wrapper.sh ] && [ -x /opt/bin/routerbot_wrapper.sh ]; then
    if [ /opt/router_bot/core/wrapper.sh -nt /opt/bin/routerbot_wrapper.sh ]; then
        cp -f /opt/router_bot/core/wrapper.sh /opt/bin/routerbot_wrapper.sh
        chmod +x /opt/bin/routerbot_wrapper.sh
        echo "wrapper.sh updated from /opt/router_bot/core/"
    fi
fi

case "$1" in
  start)
    if [ -f /var/run/routerbot.giveup ]; then
      echo "Router Bot is in GIVEUP state (too many failures)."
      echo "  Reset: rm /var/run/routerbot.giveup && $0 restart"
      exit 1
    fi
    if [ -f "$PIDFILE" ] && kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
      echo "Already running (PID $(cat $PIDFILE))"; exit 0
    fi
    kill_all_routerbot
    sleep 1
    echo "Starting Router Bot..."
    start-stop-daemon -S -b -m -p "$PIDFILE" -x "$PROG" -- $ARGS
    ;;
  stop)
    echo "Stopping Router Bot..."
    start-stop-daemon -K -p "$PIDFILE" 2>/dev/null
    kill_all_routerbot
    rm -f "$PIDFILE"
    ;;
  restart) rm -f /var/run/routerbot.giveup; $0 stop; sleep 3; $0 start ;;
  reset)
    rm -f /var/run/routerbot.giveup
    echo "Giveup marker removed. Now run: $0 start"
    ;;
  status)
    if [ -f /var/run/routerbot.giveup ]; then
        echo "Router Bot is in GIVEUP state (too many failures)"
        echo "  Reset: rm /var/run/routerbot.giveup && $0 restart"
        exit 1
    fi
    if [ -f "$PIDFILE" ] && kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
        echo "Router Bot is running (PID $(cat $PIDFILE))"
        exit 0
    else
        echo "Router Bot is stopped"
        exit 3
    fi
    ;;
  *) echo "Usage: $0 {start|stop|restart|reset|status}"; exit 1 ;;
esac
EOF98
chmod +x "$INIT_DIR/S98routerbot"
cp -f "$INIT_DIR/S98routerbot" "$BOT_INIT/S98routerbot"

# ============ S99routerbot_health ============
cat > "$INIT_DIR/S99routerbot_health" << 'EOF99'
#!/bin/sh
. /opt/router_bot/config.env

[ -f /var/run/routerbot.giveup ] && exit 0

PIDFILE=/var/run/routerbot.pid
STATE=/var/run/routerbot.fail

# 0. Автодетект WAN IP
if [ "$USE_VPN" = "yes" ] && [ -n "$VPN_IF" ]; then
    WAN_IF_NOW=""
    if [ -n "$WAN_IF" ] && ip -4 -o addr show dev "$WAN_IF" 2>/dev/null | grep -q ' inet '; then
        WAN_IF_NOW="$WAN_IF"
    else
        WAN_IF_NOW=$(ip route show default 2>/dev/null \
            | awk '/^default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
        [ -n "$WAN_IF_NOW" ] && [ "$WAN_IF_NOW" = "$VPN_IF" ] && WAN_IF_NOW=""
        echo "$WAN_IF_NOW" | grep -qE '^(opkgtun|nwg|wg|tun)' && WAN_IF_NOW=""
    fi
    WAN_SRC_NOW=""
    [ -n "$WAN_IF_NOW" ] && WAN_SRC_NOW=$(ip -4 -o addr show dev "$WAN_IF_NOW" 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 | head -1)
    if [ -n "$WAN_SRC_NOW" ] && [ "$WAN_SRC_NOW" != "$WAN_SRC" ]; then
        echo "WAN IP changed: $WAN_SRC -> $WAN_SRC_NOW"
        sed -i "s|^WAN_SRC=.*|WAN_SRC='$WAN_SRC_NOW'|" /opt/router_bot/config.env 2>/dev/null || true
        sed -i "s|^WAN_IF=.*|WAN_IF='$WAN_IF_NOW'|" /opt/router_bot/config.env 2>/dev/null || true
        WAN_SRC="$WAN_SRC_NOW"
        /opt/etc/init.d/S97tgroutes rebuild >/dev/null 2>&1 || true
    fi
fi

# 1. Маршруты Telegram
if [ "$USE_VPN" = "yes" ] && [ -n "$VPN_IF" ] && [ -n "$WAN_SRC" ]; then
    if ! ip route get 149.154.166.110 from "$WAN_SRC" 2>/dev/null | grep -q "$VPN_IF"; then
        echo "Restoring Telegram routes via $VPN_IF..."
        /opt/etc/init.d/S97tgroutes rebuild >/dev/null 2>&1 || true
    fi
fi

# 2. resolv.conf
if ! grep -q nameserver /etc/resolv.conf 2>/dev/null; then
    printf 'nameserver 127.0.0.1\nnameserver 8.8.8.8\noptions timeout:1 attempts:1 rotate\n' > /etc/resolv.conf
fi

# 3. Проверка связи с Telegram
TG=$(sed -n "s/^TG_BOT_TOKEN='\(.*\)'/\1/p" /opt/router_bot/config.env)
_c4=""
if [ "$DISABLE_IPV6" = "yes" ]; then
    _c4="-4"
fi
_http_code=$(/opt/bin/curl $_c4 -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "https://api.telegram.org/bot${TG}/getMe")

if [ "$_http_code" -ge 200 ] && [ "$_http_code" -lt 500 ]; then
    rm -f "$STATE"
else
    COUNT=$(cat "$STATE" 2>/dev/null || echo 0)
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$STATE"
    echo "Telegram unreachable (HTTP code: $_http_code, failure $COUNT)"
    if [ "$COUNT" -ge 3 ]; then
        rm -f "$STATE"
        /opt/etc/init.d/S98routerbot restart
    fi
    exit 0
fi

if [ -f "$PIDFILE" ] && kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
    exit 0
fi

echo "Bot process is dead, restarting..."
/opt/etc/init.d/S98routerbot restart
EOF99
chmod +x "$INIT_DIR/S99routerbot_health"
cp -f "$INIT_DIR/S99routerbot_health" "$BOT_INIT/S99routerbot_health"

# ============ logrotate ============
mkdir -p /opt/etc/logrotate.d
cat > /opt/etc/logrotate.d/router_bot << 'LREOF'
/opt/var/log/router_bot.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LREOF

# ============ cron healthcheck ============
if [ -f /opt/etc/crontab ] && ! grep -q "S99routerbot_health" /opt/etc/crontab; then
    echo "*/1 * * * * /opt/etc/init.d/S99routerbot_health" >> /opt/etc/crontab
fi

echo "  ✅ ensure_init.sh: init-скрипты, logrotate, cron обновлены"
RB_ENSURE_INIT_SH_EOF
chmod +x /opt/router_bot/ensure_init.sh
chmod +x /opt/router_bot/restore_init.sh

chmod +x /opt/router_bot/install.sh
chmod +x /opt/router_bot/uninstall.sh

# ============================================================
#  Генерация манифеста хэшей (для следующей переустановки)
# ============================================================
if command -v sha256sum >/dev/null 2>&1; then
    : > /opt/router_bot/.manifest
    find /opt/router_bot -type f \
        ! -path '*/data/*' \
        ! -path '*/.user_backup/*' \
        ! -path '*/__pycache__/*' \
        ! -name '*.pyc' \
        ! -name '*.pyo' \
        ! -name '.manifest' \
        ! -name 'VERSION' \
        ! -name 'config.env*' \
        2>/dev/null | while IFS= read -r _f; do
            sha256sum "$_f" 2>/dev/null
        done > /opt/router_bot/.manifest
    _cnt=$(wc -l < /opt/router_bot/.manifest 2>/dev/null | tr -d ' ')
    [ -z "$_cnt" ] && _cnt=0
    echo "  → Манифест: $_cnt файлов"
fi

echo ""
echo "Файлы распакованы в /opt/router_bot/"
echo ""
# Остановка работающего экземпляра
/opt/etc/init.d/S98routerbot stop 2>/dev/null || true
for p in $(ps w | grep "router_bot/main.py" | grep -v grep | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null
done
sleep 1

echo "→ Запускаю установщик..."
echo ""
sh /opt/router_bot/install.sh
_RC=$?

# ---------- Генерация манифеста (heredoc-based setup.sh) ----------
if [ "$_RC" = "0" ] && command -v sha256sum >/dev/null 2>&1; then
    : > /opt/router_bot/.manifest
    find /opt/router_bot -type f \
        ! -path '*/data/*' \
        ! -path '*/.user_backup/*' \
        ! -path '*/__pycache__/*' \
        ! -path '*/backup/*' \
        ! -name '*.pyc' \
        ! -name '*.pyo' \
        ! -name '.manifest' \
        ! -name 'VERSION' \
        ! -name 'config.env*' \
        2>/dev/null | while IFS= read -r _f; do
            sha256sum "$_f" 2>/dev/null
        done > /opt/router_bot/.manifest
    _cnt=$(wc -l < /opt/router_bot/.manifest 2>/dev/null | tr -d ' ')
    [ -z "$_cnt" ] && _cnt=0
    echo ""
    echo "  → Манифест: $_cnt файлов"
fi
