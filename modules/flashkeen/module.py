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
)

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
    commands = []

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
        await update.message.reply_text(text, parse_mode='HTML', reply_markup=kb)

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
            await self._start_action(ctx, key, cmd)
            return

        if action == 'run':
            await q.answer('Запускаю...')
            await self._start_interactive(ctx)
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
        msg = await ctx.bot.send_message(
            chat_id=self.chat_id,
            text='\U0001f5d1 <b>Удаление остатков Flashkeen</b>\n\n<pre>запуск...</pre>',
            parse_mode='HTML',
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='flashkeen:kill')],
            ]),
        )
        self._status_msg_id = msg.message_id

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
            msg = await ctx.bot.send_message(
                chat_id=self.chat_id,
                text='\U0001f5d1 <b>Удаление Flashkeen</b>\n\n<pre>запуск...</pre>',
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton('\U0001f6d1 Отменить',
                                          callback_data='flashkeen:kill')],
                ]),
            )
            self._status_msg_id = msg.message_id

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
    async def _start_action(self, ctx, key, cmd):
        if self._running:
            return
        self._running = True
        self._last_action = key
        self._mode = 'action'
        self._buf = b''
        self._last_edit = 0.0

        msg = await ctx.bot.send_message(
            chat_id=self.chat_id,
            text='⏳ <b>Выполняется...</b>\n\n<pre>запуск...</pre>',
            parse_mode='HTML',
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='flashkeen:kill')],
            ]),
        )
        self._status_msg_id = msg.message_id

        pid, master = pty.fork()
        if pid == 0:
            # дочерний процесс — exec, никогда не возвращаемся
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
        self._awaiting_yn = True
        text = _strip_ansi(buf.decode('utf-8', errors='replace'))
        tail = text[-400:] if len(text) > 400 else text
        kb = InlineKeyboardMarkup([
            [
                InlineKeyboardButton('\u2705 Да (y)', callback_data='flashkeen:send:y'),
                InlineKeyboardButton('\u274c Нет (n)', callback_data='flashkeen:send:n'),
            ],
            [
                InlineKeyboardButton('\u23ce Enter', callback_data='flashkeen:send:enter'),
                InlineKeyboardButton('\U0001f6d1 Прервать', callback_data='flashkeen:kill'),
            ],
        ])
        try:
            q = await ctx.bot.send_message(
                chat_id=self.chat_id,
                text=f'\u2753 <b>Требуется ответ</b>\n\n<pre>{_esc(tail)}</pre>',
                parse_mode='HTML', reply_markup=kb,
            )
            self._question_msg_id = q.message_id
        except Exception as e:
            log.warning('ask_yn: %s', e)

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
    async def _start_interactive(self, ctx):
        if self._running:
            return
        self._running = True
        self._mode = 'interactive'
        self._buf = b''
        self._last_edit = 0.0

        launch = find_flashkeen() or FLASHKEEN_LAUNCH

        msg = await ctx.bot.send_message(
            chat_id=self.chat_id,
            text='⏳ <b>Запускаю Flashkeen...</b>',
            parse_mode='HTML',
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Закрыть',
                                      callback_data='flashkeen:kill')],
            ]),
        )
        self._status_msg_id = msg.message_id

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