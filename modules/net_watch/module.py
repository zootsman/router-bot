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
    ('\U0001f4fa', 'телевизор / медиа',
        ['-tv', 'tv-', 'bravia', 'chromecast', 'apple-tv', 'androidtv', 'smarttv',
         'телевизор', 'smart-tv']),
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


def device_icon(name: str, vendor: str = '', ssdp_model: str = '',
                hostname: str = '') -> str:
    """Иконка по имени / ssdp-модели / hostname / производителю."""
    n = (name or '').lower()
    v = (vendor or '').lower()
    m = (ssdp_model or '').lower()
    h = (hostname or '').lower()
    combined = f'{n} {m} {h}'

    for icon, _, keys in NAME_RULES:
        for k in keys:
            if k in combined:
                return icon

    if 'apple' in v:
        return '\U0001f4f1'
    if 'microsoft' in v or 'xbox' in v:
        return '\U0001f3ae'
    if 'synology' in v or 'qnap' in v:
        return '\U0001f4be'
    if 'hewlett' in v or 'canon' in v or 'epson' in v or 'brother' in v:
        return '\U0001f5a8\ufe0f'

    return '\U0001f4f6'


def device_type(name: str, vendor: str = '', ssdp_model: str = '',
                hostname: str = '') -> str:
    n = (name or '').lower()
    v = (vendor or '').lower()
    m = (ssdp_model or '').lower()
    h = (hostname or '').lower()
    combined = f'{n} {m} {h}'
    for icon, label, keys in NAME_RULES:
        for k in keys:
            if k in combined:
                return label
    if 'apple' in v:
        return 'смартфон / планшет'
    if 'microsoft' in v or 'xbox' in v:
        return 'игровая консоль'
    if 'synology' in v or 'qnap' in v:
        return 'NAS / хранилище'
    if 'hewlett' in v or 'canon' in v or 'epson' in v or 'brother' in v:
        return 'принтер / МФУ'
    return 'устройство'


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
        await bot.send_message(
            chat_id=CHAT_ID, text=text,
            parse_mode='HTML', reply_markup=markup,
        )
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
    app.bot_data['state'] = state
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
    commands = [
        ('status', '📡 Список активных клиентов'),
        ('stats',  '📊 Статистика'),
    ]

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
        await update.message.reply_text(text, parse_mode='HTML', reply_markup=kb)

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