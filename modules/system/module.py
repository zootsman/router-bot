"""Модуль System — состояние роутера."""
import asyncio
import json
import logging
import os
import subprocess
from datetime import datetime, timedelta

from telegram import InlineKeyboardButton, InlineKeyboardMarkup

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


def get_selected_channel():
    """Читает UPDATE_CHANNEL из config.env."""
    try:
        with open(CONFIG_PATH) as f:
            for line in f:
                line = line.strip()
                if line.startswith('UPDATE_CHANNEL='):
                    return line.split('=', 1)[1].strip().strip('"').strip("'")
    except Exception:
        pass
    return 'stable'


def set_selected_channel(channel: str) -> bool:
    """Записывает UPDATE_CHANNEL в config.env."""
    try:
        lines = []
        found = False
        if os.path.exists(CONFIG_PATH):
            with open(CONFIG_PATH) as f:
                for line in f:
                    if line.startswith('UPDATE_CHANNEL='):
                        lines.append(f"UPDATE_CHANNEL='{channel}'\n")
                        found = True
                    else:
                        lines.append(line)
        if not found:
            lines.append(f"\n# Канал обновлений\nUPDATE_CHANNEL='{channel}'\n")
        tmp = CONFIG_PATH + '.tmp'
        with open(tmp, 'w') as f:
            f.writelines(lines)
        os.replace(tmp, CONFIG_PATH)
        return True
    except Exception as e:
        log.warning('set_selected_channel failed: %s', e)
        return False


def get_update_info():
    """Парсит `components check-update` + `show version`."""
    result = {
        'channel': '',
        'title': '',
        'release': '',           # доступная версия
        'current_version': '',    # текущая версия
        'update_available': False,
        'checking': False,
    }

    # 1. Текущая версия из show version (быстро, надёжно)
    try:
        p_cur = subprocess.run(
            ['/bin/ndmc', '-c', 'show version'],
            capture_output=True, text=True, timeout=10,
        )
        cur_text = (p_cur.stdout or '') + (p_cur.stderr or '')
        for line in cur_text.splitlines():
            if ':' not in line:
                continue
            k, v = line.split(':', 1)
            k = k.strip(); v = v.strip()
            if k == 'release':
                result['current_version'] = v
            elif k == 'sandbox' and not result['channel']:
                result['channel'] = v
    except Exception as e:
        log.debug('show version failed: %s', e)

    # 2. Проверка обновлений (может занять 10-20 сек)
    try:
        p = subprocess.run(
            ['/bin/ndmc', '-c', 'components check-update'],
            capture_output=True, text=True, timeout=30,
        )
        # Читаем И stdout, И stderr — ndmc может писать в любой
        out = (p.stdout or '') + '\n' + (p.stderr or '')
        for line in out.splitlines():
            if ':' not in line:
                continue
            k, v = line.split(':', 1)
            k = k.strip(); v = v.strip()
            if k == 'sandbox' and not result['channel']:
                result['channel'] = v
            elif k == 'title':
                result['title'] = v
            elif k == 'release':
                result['release'] = v
            elif k == 'update-available':
                result['update_available'] = (v.lower() == 'yes')
            elif k == 'checking':
                result['checking'] = (v.lower() == 'yes')
    except Exception as e:
        log.debug('check-update failed: %s', e)

    # 3. Fallback — если update-available не пришёл, считаем по версиям
    if (not result['update_available']
            and result['release'] and result['current_version']
            and result['release'] != result['current_version']):
        result['update_available'] = True

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


def build_system_card():
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

    # Информация об обновлениях
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




def start_firmware_update():
    """Запускает `components commit` через pty в фоне."""
    import threading
    import time
    import pty
    import subprocess

    def _worker():
        try:
            time.sleep(3)
            master, slave = pty.openpty()
            proc = subprocess.Popen(
                ['/bin/ndmc', '-c', 'components commit'],
                stdin=slave,
                stdout=slave,
                stderr=slave,
                close_fds=True,
                start_new_session=True,
            )
            os.close(slave)
            # читаем, но не блокируемся навсегда
            buf = b''
            start = time.time()
            while time.time() - start < 30:
                try:
                    data = os.read(master, 4096)
                    if not data:
                        break
                    buf += data
                except OSError:
                    break
                time.sleep(0.2)
                # если видим приглашение — отправляем y
                low = buf.lower()
                if b'(y/n)' in low or b'[y/n]' in low or b'continue' in low:
                    try:
                        os.write(master, b'y\n')
                    except OSError:
                        pass
                    buf = b''  # сбрасываем, чтобы не отправлять повторно
                # если видим про перезагрузку — выходим
                if b'reboot' in low or b'restarting' in low:
                    break
            try:
                os.close(master)
            except Exception:
                pass
        except Exception as e:
            log.exception('firmware update worker failed: %s', e)

    threading.Thread(target=_worker, daemon=True).start()
    log.info('Firmware update scheduled')


def _kb(update_available: bool = False):
    rows = []
    if update_available:
        rows.append([InlineKeyboardButton(
            '\u2b06\ufe0f Установить обновление',
            callback_data='system:update_ask',
        )])
    rows.append([InlineKeyboardButton(
        '\U0001f50d Проверить обновления',
        callback_data='system:check_upd',
    )])
    rows.append([InlineKeyboardButton('\U0001f504 Обновить', callback_data='system:refresh')])
    rows.append([InlineKeyboardButton('\U0001f310 Зеркала Entware',
                                      callback_data='router:mirrors')])
    rows.append([InlineKeyboardButton('\U0001f3e0 Модули', callback_data='router:main')])
    return InlineKeyboardMarkup(rows)


def _channel_menu_kb(current: str):
    def label(ch, name):
        mark = ' \u2705' if ch == current else ''
        return f'{name}{mark}'
    return InlineKeyboardMarkup([
        [InlineKeyboardButton(label('stable', 'stable \u2014 стабильный'), callback_data='system:set_ch:stable')],
        [InlineKeyboardButton(label('preview', 'preview \u2014 предварительный'), callback_data='system:set_ch:preview')],
        [InlineKeyboardButton(label('draft', 'draft \u2014 тестовый'), callback_data='system:set_ch:draft')],
        [InlineKeyboardButton('\u2b05\ufe0f Назад', callback_data='system:main')],
    ])


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
    commands = []  # /sys регистрируется в core/main.py как глобальная

    def __init__(self, chat_id):
        self.chat_id = str(chat_id)
        self._app = None
        self._update_task = None

    async def startup(self, app):
        self._app = app
        self._update_task = asyncio.create_task(self._update_watch_loop())
        log.info('System module started')

    async def on_leave(self):
        if getattr(self, '_update_task', None):
            self._update_task.cancel()

    async def _update_watch_loop(self):
        await asyncio.sleep(90)
        while True:
            try:
                await self._check_updates_and_notify()
            except Exception as e:
                log.debug('system update watch failed: %s', e)
            await asyncio.sleep(6 * 3600)

    async def _check_updates_and_notify(self):
        upd = await asyncio.to_thread(get_update_info)
        st = _load_update_state()

        if not upd.get('update_available'):
            st['last_check'] = datetime.now().isoformat()
            st.pop('last_notified_version', None)
            st.pop('snoozed_until', None)
            _save_update_state(st)
            return

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
        text = build_system_card()
        await update.message.reply_text(text, parse_mode='HTML', reply_markup=_kb())

    async def handle_callback(self, action, q, ctx):
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
            text = build_system_card()
            upd = get_update_info()
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

        if action == 'update_go':
            await q.answer('Запускаю обновление...')
            try:
                await q.edit_message_text(
                    '\u2b06\ufe0f <b>Обновление запущено</b>\n\n'
                    'Роутер перезагрузится через 10–30 секунд.\n'
                    'Не выключайте питание.\n\n'
                    '<i>После перезагрузки напишите /start.</i>',
                    parse_mode='HTML',
                )
            except Exception:
                pass
            start_firmware_update()
            return