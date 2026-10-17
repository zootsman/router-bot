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
    ACTIONS, is_installed, get_installed_version,
    UNINSTALL_TARGETS, SCAN_PATTERNS,
    get_hr_web_url, get_versions, check_updates,
    load_last_seen, save_last_seen,
)

log = logging.getLogger(__name__)
from core.utils import (
    existing_targets, sync_opts, build_uninstall_menu,
    collect_uninstall_cmd, toggle_opt,
    scan_leftovers, build_leftovers_message,
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
    commands = []

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
        await asyncio.sleep(60)
        while True:
            try:
                await self._check_and_notify()
            except Exception as e:
                log.debug('hr update watch failed: %s', e)
            await asyncio.sleep(12 * 3600)

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
            if ins and lat and ins != lat:
                if last.get(pkg) != lat:
                    newly[pkg] = {'installed': ins, 'latest': lat}
        if newly:
            await self._send_update_notification(newly)
        new_state = {pkg: d['latest']
                     for pkg, d in info.items() if d.get('latest')}
        save_last_seen(new_state)

    async def _send_update_notification(self, newly):
        lines = ['🆕 <b>Обновления HydraRoute</b>', '']
        for pkg, d in newly.items():
            lines.append(f'🟢 <b>{pkg}</b>: '
                         f'<code>{d["installed"]}</code> → '
                         f'<code>{d["latest"]}</code>')
        lines.append('')
        lines.append('Обновить сейчас?')
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('✅ Да, обновить',
                                  callback_data='hydraroute:go:update')],
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

    def send_card_message(self, update, ctx):
        text, kb = self._build_card()
        return update.message.reply_text(text, parse_mode='HTML', reply_markup=kb)

    conflicts_with = {
        'xkeen': 'оба используют /opt/etc/xray и запускают демон xray',
    }

    def get_installed(self) -> bool:
        return is_installed()

    def get_status_short(self) -> str:
        return '✅' if is_installed() else '❌'

    def _build_card(self):
        installed = is_installed()
        lines = [f'{self.icon} <b>{self.title}</b>', '']
        if installed:
            vs = get_versions()
            neo = vs.get('neo')   or '—'
            web = vs.get('web')   or '—'
            dns = vs.get('hrdns') or '—'
            lines.append(f'📦 Neo: <code>{neo}</code>')
            lines.append(f'🖥️ Web: <code>{web}</code>')
            lines.append(f'📡 hrdns: <code>{dns}</code>')
            url = get_hr_web_url()
            lines.append(f'🌐 Веб: <a href="{url}">{url}</a>')
        else:
            lines.append('❌ Не установлен')
        if not installed:
            try:
                import os as _os
                if _os.path.isdir('/opt/sbin/.xkeen'):
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
                '📥 Установить', callback_data='hydraroute:ask:install')])
        else:
            rows.append([InlineKeyboardButton(
                '🔍 Проверить обновления',
                callback_data='hydraroute:ask:check_updates')])
            rows.append([InlineKeyboardButton(
                '📤 Обновить', callback_data='hydraroute:ask:update')])
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
            text = (
                f'{a["icon"]} <b>{a["title"]}</b>\n\n'
                f'{a["desc"]}\n\n'
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
            await self._start_action(ctx, key, a)
            return

        if action == 'kill':
            await q.answer('Прерываю...')
            self._kill()
            await q.edit_message_text(
                '🛑 Операция прервана.\n\nНапишите /start для возврата в меню.',
            )
            return

        if action == 'ans:y':
            await self._answer(q, ctx, b'y\n')
            return
        if action == 'ans:n':
            await self._answer(q, ctx, b'n\n')
            return
        if action == 'ans:enter':
            await self._answer(q, ctx, b'\n')
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
        lines.append('')
        if any_update:
            lines.append('Доступны обновления.')
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('📥 Обновить',
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
            await update.message.reply_text('🔑 Записываю токен...')
            await self._start_action(ctx, 'keenetic',
                {'icon': '🔑', 'title': 'Keenetic token', 'cmd': cmd})
            return
        if self._match_editing:
            self._match_editing = False
            from .actions import build_match_cmd
            cmd = build_match_cmd(text)
            await update.message.reply_text(
                f'🎯 Проверяю для <code>{text}</code>...',
                parse_mode='HTML')
            await self._start_action(ctx, 'match',
                {'icon': '🎯', 'title': 'Match domain', 'cmd': cmd})
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
    async def _start_action(self, ctx, key, action):
        self._last_action = key
        if self._running:
            return

        self._running = True
        self._awaiting_answer = False

        status_text = (
            f'{action["icon"]} <b>{action["title"]}</b>\n\n'
            f'<pre>Запускаю...</pre>'
        )
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('🛑 Отменить', callback_data='hydraroute:kill')],
        ])
        msg = await ctx.bot.send_message(
            chat_id=self.chat_id,
            text=status_text,
            parse_mode='HTML',
            reply_markup=kb,
        )
        self._status_msg_id = msg.message_id
        asyncio.create_task(self._run_action(ctx, action))

    async def _run_action(self, ctx, action):
        cmd = action['cmd']
        log.info('hydraroute action cmd: %s', cmd)

        master, slave = pty.openpty()
        try:
            proc = subprocess.Popen(
                ['sh', '-c', cmd],
                stdin=slave,
                stdout=slave,
                stderr=slave,
                close_fds=True,
                start_new_session=True,
                env={**os.environ, 'DEBIAN_FRONTEND': 'noninteractive'},
            )
        except Exception as e:
            os.close(master)
            os.close(slave)
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
        last_update = 0.0
        idle_start = time.time()

        try:
            while True:
                if self._proc is None:
                    break
                ret = proc.poll()
                if ret is not None:
                    buf += self._drain_master(master)
                    break

                try:
                    data = os.read(master, 4096)
                    idle_start = time.time()
                except BlockingIOError:
                    await asyncio.sleep(0.15)
                    if time.time() - idle_start > 2.0 and proc.poll() is not None:
                        buf += self._drain_master(master)
                        break
                    continue
                except OSError:
                    break
                if not data:
                    break

                buf += data
                if len(buf) > 600000:
                    buf = buf[-500000:]

                now = time.time()
                if now - last_update >= 1.2:
                    last_update = now
                    await self._update_status(ctx, buf)

                if not self._awaiting_answer and _has_question(buf[-500:]):
                    await self._ask_question(ctx, buf)
        except Exception as e:
            log.exception('hydraroute run error: %s', e)
        finally:
            try:
                os.close(master)
            except Exception:
                pass
            self._master_fd = None

        rc = proc.wait()
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
        if not self._status_msg_id:
            return
        text_buf = buf.decode('utf-8', errors='replace')
        tail = text_buf[-2000:] if len(text_buf) > 2000 else text_buf
        try:
            await ctx.bot.edit_message_text(
                chat_id=self.chat_id,
                message_id=self._status_msg_id,
                text=f'⏳ <b>Выполняется...</b>\n\n<pre>{_esc(tail)}</pre>',
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton('🛑 Отменить', callback_data='hydraroute:kill')],
                ]),
            )
        except Exception as e:
            if 'not modified' not in str(e).lower():
                log.debug('edit status: %s', e)

    async def _ask_question(self, ctx, buf):
        self._awaiting_answer = True
        text_buf = buf.decode('utf-8', errors='replace')
        tail = text_buf[-400:] if len(text_buf) > 400 else text_buf
        kb = InlineKeyboardMarkup([
            [
                InlineKeyboardButton('✅ Да (y)', callback_data='hydraroute:ans:y'),
                InlineKeyboardButton('❌ Нет (n)', callback_data='hydraroute:ans:n'),
            ],
            [
                InlineKeyboardButton('⏎ Enter', callback_data='hydraroute:ans:enter'),
                InlineKeyboardButton('🛑 Прервать', callback_data='hydraroute:kill'),
            ],
        ])
        try:
            q = await ctx.bot.send_message(
                chat_id=self.chat_id,
                text=f'❓ <b>Требуется ответ</b>\n\n<pre>{_esc(tail)}</pre>',
                parse_mode='HTML',
                reply_markup=kb,
            )
            self._question_msg_id = q.message_id
        except Exception as e:
            log.warning('ask_question failed: %s', e)

    async def _answer(self, q, ctx, data):
        if not self._proc or not self._master_fd:
            await q.answer('Процесс уже завершён', show_alert=False)
            return
        try:
            os.write(self._master_fd, data)
        except OSError as e:
            log.warning('write to master failed: %s', e)
        await q.answer(f'Отправлено: {data.decode().strip() or "Enter"}')
        try:
            await q.message.delete()
        except Exception:
            pass
        self._awaiting_answer = False
        self._question_msg_id = None

    async def _finish(self, ctx, buf, rc):
        self._running = False
        self._awaiting_answer = False
        was_uninstall = (self._last_action == 'uninstall')
        was_cleanup = (self._last_action == 'cleanup')
        was_match = (self._last_action == 'match')
        was_watchlist = (self._last_action == 'watchlist')

        text = buf.decode('utf-8', errors='replace')
        text = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', text)
        text = re.sub(r'\r', '', text)
        text = text.strip()

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
            getattr(self, '_last_action', None) == 'install'
            and rc == 0
            and is_installed()
        )
        self._last_action = None

        if self._question_msg_id:
            try:
                await ctx.bot.delete_message(
                    chat_id=self.chat_id, message_id=self._question_msg_id,
                )
            except Exception:
                pass
            self._question_msg_id = None

        icon = '✅' if rc == 0 else '❌'
        if was_watchlist and self._status_msg_id:
            lines = text.splitlines()
            total = len(lines)
            if total > 100:
                preview_lines = (lines[:50]
                    + ['', f'... (опущено {total-100} строк) ...', '']
                    + lines[-50:])
                preview = '\n'.join(preview_lines)
            else:
                preview = text
            if len(preview) > 3500:
                preview = preview[:3500] + '\n...'
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id,
                    message_id=self._status_msg_id,
                    text=f'📋 <b>Watchlist</b> — {total} строк\n\n<pre>{_esc(preview)}</pre>',
                    parse_mode='HTML', reply_markup=None,
                )
            except Exception as e:
                log.debug('watchlist M1 edit failed: %s', e)
            try:
                from telegram import InputFile
                import io as _io
                fbuf = _io.BytesIO(text.encode('utf-8'))
                fbuf.name = 'watchlist.txt'
                await ctx.bot.send_document(
                    chat_id=self.chat_id,
                    document=InputFile(fbuf, filename='watchlist.txt'),
                    caption=f'📋 Watchlist — полный список ({total} строк)',
                    reply_markup=InlineKeyboardMarkup([
                        [InlineKeyboardButton('⬅️ Назад',
                                              callback_data='hydraroute:main')],
                    ]),
                )
            except Exception as e:
                log.warning('watchlist file send failed: %s', e)
            self._status_msg_id = None
            return

        if was_match and self._status_msg_id:
            stripped = text.strip() if text else ''
            if stripped.startswith('OK'):
                parts = stripped.split(None, 3)
                if len(parts) >= 4:
                    pol = parts[1]
                    dom = parts[3]
                    final = (f'🟢 <b>Маршрутизируется через HR</b>\n\n'
                             f'Домен: <code>{_esc(dom)}</code>\n'
                             f'Политика: <b>{_esc(pol)}</b>')
                else:
                    final = (f'🟢 <b>OK</b>\n\n'
                             f'<pre>{_esc(stripped)}</pre>')
            elif stripped.startswith('NO'):
                final = ('⚪ <b>Не найдено в HR</b>\n'
                         '<i>Пойдёт напрямую через WAN.</i>')
            else:
                final = '🎯 <b>Match</b>'
                if stripped:
                    final += f'\n\n<pre>{_esc(stripped[-1500:])}</pre>'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('🔄 Ещё',
                                      callback_data='hydraroute:ask:match')],
                [InlineKeyboardButton('⬅️ Назад',
                                      callback_data='hydraroute:main')],
            ])
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id,
                    message_id=self._status_msg_id,
                    text=final,
                    parse_mode='HTML',
                    reply_markup=kb,
                )
            except Exception as e:
                log.debug('final match M1 failed: %s', e)
            self._status_msg_id = None
            return

        if self._status_msg_id:
            if was_cleanup:
                m1_title = '🗑 <b>Удаление остатков</b>'
            elif was_uninstall:
                m1_title = '🗑 <b>Удаление HydraRoute</b>'
            elif offer_start:
                m1_title = '📦 <b>Установка HydraRoute</b>'
            else:
                m1_title = '⚙️ <b>Операция</b>'

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
                f'{icon} <b>Установка HydraRoute завершена</b>\n'
                f'<i>exit code: {rc}</i>'
            )
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('⬅️ Назад',
                                      callback_data='hydraroute:main')],
            ])
        elif was_cleanup:
            header = f'{icon} <b>Остатки удалены</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('⬅️ Назад',
                                      callback_data='hydraroute:main')],
            ])
        elif was_match:
            stripped = text.strip() if text else ''
            if stripped.startswith('OK'):
                header = (f'🟢 <b>Маршрутизируется через HR</b>\n\n'
                          f'<pre>{_esc(stripped)}</pre>')
            elif stripped.startswith('NO'):
                header = ('⚪ <b>Не найдено в HR</b>\n'
                          '<i>Пойдёт напрямую через WAN.</i>')
            else:
                header = '🎯 <b>Match</b>'
                if stripped:
                    header += f'\n\n<pre>{_esc(stripped[-1500:])}</pre>'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('⬅️ Назад',
                                      callback_data='hydraroute:main')],
            ])
        else:
            header = f'{icon} <b>Завершено</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('⬅️ Назад',
                                      callback_data='hydraroute:main')],
            ])

        body = header
        if not was_match and rc != 0 and text:
            err_tail = '\n'.join(text.split('\n')[-15:])
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