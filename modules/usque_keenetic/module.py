"""Модуль usque-keenetic — Cloudflare WARP (MASQUE) для Keenetic."""
import asyncio, html, logging, os, pty, re, time
from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import ContextTypes

from .actions import (
    ACTIONS, UNINSTALL_CMD, UNINSTALL_TARGETS, SCAN_PATTERNS, USQUE_CONF,
    is_installed, is_running, get_version, get_status_short,
)
from core.utils import (
    existing_targets, sync_opts, build_uninstall_menu,
    collect_uninstall_cmd, toggle_opt,
    scan_leftovers, build_leftovers_message,
)

log = logging.getLogger(__name__)


def _esc(s): return html.escape(s or '')
def _strip_ansi(s):
    s = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', s)
    s = re.sub(r'\x1b\][^\x07]*\x07', '', s)
    return re.sub(r'\x1b[=>]', '', s)


class UsqueKeeneticModule:
    name = 'usque_keenetic'
    title = 'Usque WARP'
    icon = '\U0001f310'
    description = 'Cloudflare WARP (MASQUE)'
    category = 'services'
    category_title = 'Сервис'
    category_icon = '\U0001f6e0'
    conflicts_with = {
        'keen_pbr':   'пересечение policy-routing и nftables-меток',
        'xkeen':      'оба занимают туннели/маршрутизацию',
        'hydraroute': 'пересечение маршрутизации доменов',
    }
    commands = []

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
        log.info('Usque-keenetic module started')

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
            for p, name in [('/opt/etc/keen-pbr', 'Keen-PBR'),
                            ('/opt/etc/xkeen', 'XKeen'),
                            ('/opt/etc/HydraRoute', 'HydraRoute')]:
                if os.path.isdir(p):
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
                                     callback_data='usque_keenetic:ask:show_config'),
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
        await update.message.reply_text(text, parse_mode='HTML', reply_markup=kb)

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
            text = (f'{a["icon"]} <b>{a["title"]}</b>\n\n'
                    f'{a["desc"]}\n\nПодтвердить?')
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
                await self._start_action(ctx, key, a['cmd'])
            return
        await q.answer()

    async def _start_action(self, ctx, key, cmd):
        if self._running: return
        self._running = True
        self._last_action = key
        self._buf = b''
        self._last_edit = 0.0
        a = ACTIONS.get(key, {})
        icon = a.get('icon', '\u2699\ufe0f')
        title = a.get('title', key)
        msg = await ctx.bot.send_message(
            chat_id=self.chat_id,
            text=f'{icon} <b>{title}</b>\n\n<pre>запуск...</pre>',
            parse_mode='HTML',
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='usque_keenetic:kill')],
            ]),
        )
        self._status_msg_id = msg.message_id
        pid, master = pty.fork()
        if pid == 0:
            try:
                os.environ['TERM'] = 'dumb'
                os.execv('/bin/sh', ['sh', '-c', cmd])
            except Exception: os._exit(1)
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
        try:
            while True:
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

    async def _update_status(self, ctx):
        if not self._status_msg_id: return
        text = _strip_ansi(self._buf.decode('utf-8', errors='replace'))
        tail = text[-1800:] if len(text) > 1800 else text
        try:
            await ctx.bot.edit_message_text(
                chat_id=self.chat_id,
                message_id=self._status_msg_id,
                text=f'⏳ <b>Выполняется...</b>\n\n<pre>{_esc(tail)}</pre>',
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
        was_uninstall = (self._last_action == 'uninstall')
        was_cleanup = (self._last_action == 'cleanup')
        text = _strip_ansi(buf.decode('utf-8', errors='replace'))
        if rc == 0 and 'Collected errors' in text:
            new_lines, skip = [], False
            for ln in text.split('\n'):
                if 'Collected errors' in ln:
                    skip = True; continue
                if skip:
                    if ln.strip().startswith('*'):
                        if 'is not installed' in ln: continue
                        new_lines.append(ln); continue
                    else: skip = False
                new_lines.append(ln)
            text = '\n'.join(new_lines).strip()
        offer_start = (self._last_action == 'install' and rc == 0
                       and is_installed() and not is_running())
        self._last_action = None
        icon = '\u2705' if rc == 0 else '\u274c'

        if self._status_msg_id:
            if was_cleanup:     m1_title = '\U0001f5d1 <b>Удаление остатков usque</b>'
            elif was_uninstall: m1_title = '\U0001f5d1 <b>Удаление usque-keenetic</b>'
            elif offer_start:   m1_title = '\U0001f4e6 <b>Установка usque-keenetic</b>'
            else:               m1_title = '\u2699\ufe0f <b>Операция</b>'
            tail_m1 = text[-3500:] if len(text) > 3500 else text
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id,
                    message_id=self._status_msg_id,
                    text=f'{m1_title}\n\n<pre>{_esc(tail_m1)}</pre>',
                    parse_mode='HTML', reply_markup=None,
                )
            except Exception as e: log.debug('final M1 update failed: %s', e)
            self._status_msg_id = None

        if offer_start:
            header = (f'{icon} <b>Установка usque-keenetic завершена</b>\n'
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
            header = f'{icon} <b>Завершено</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                      callback_data='usque_keenetic:main')],
            ])
        body = header
        if rc != 0 and text.strip():
            err_tail = '\n'.join(text.strip().split('\n')[-15:])
            if len(err_tail) > 1500: err_tail = err_tail[-1500:]
            body += f'\n\n<pre>{_esc(err_tail)}</pre>'
        try:
            await ctx.bot.send_message(chat_id=self.chat_id, text=body,
                                       parse_mode='HTML', reply_markup=kb)
        except Exception as e: log.warning('final M2 send failed: %s', e)
        if rc == 0 and was_uninstall:
            await self._check_leftovers(ctx)

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
            msg = await ctx.bot.send_message(
                chat_id=self.chat_id,
                text='\U0001f5d1 <b>Удаление usque-keenetic</b>\n\n<pre>запуск...</pre>',
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton('\U0001f6d1 Отменить',
                                          callback_data='usque_keenetic:kill')],
                ]),
            )
            self._status_msg_id = msg.message_id
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
            safe = p.replace("'", "'\\\\''")
            parts.append(f"echo 'Удаляю: {safe}' ; rm -rf '{safe}'")
        parts.append(f"echo '' ; echo 'Готово: удалено {total} элементов'")
        cmd = ' ; '.join(parts)
        self._leftovers = []
        self._buf = b''; self._last_edit = 0.0
        self._running = True; self._last_action = 'cleanup'
        msg = await ctx.bot.send_message(
            chat_id=self.chat_id,
            text='\U0001f5d1 <b>Удаление остатков usque</b>\n\n<pre>запуск...</pre>',
            parse_mode='HTML',
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='usque_keenetic:kill')],
            ]),
        )
        self._status_msg_id = msg.message_id
        pid, master = pty.fork()
        if pid == 0:
            try:
                os.environ['TERM'] = 'dumb'
                os.execv('/bin/sh', ['sh', '-c', cmd])
            except Exception: os._exit(1)
        self._proc_pid = pid; self._master = master
        asyncio.create_task(self._reader_loop(ctx, pid, master))