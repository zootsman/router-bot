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
)

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
    commands = []

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
                import os as _os
                if _os.path.isdir('/opt/etc/HydraRoute'):
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
            [InlineKeyboardButton('\U0001f4e6 Обновить ядро Xray',
                                  callback_data='xkeen:ask:update_xray')],
            [InlineKeyboardButton('\U0001f4e6 Обновить ядро Mihomo',
                                  callback_data='xkeen:ask:update_mihomo')],
            [InlineKeyboardButton('\U0001f30d Обновить геофайлы',
                                  callback_data='xkeen:ask:update_geo')],
            [InlineKeyboardButton('\U0001f4e6 Обновить XKeen',
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
        await update.message.reply_text(text, parse_mode='HTML', reply_markup=kb)

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
            text = (
                f'{a["icon"]} <b>{a["title"]}</b>\n\n'
                f'{a["desc"]}\n\n'
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
            await self._start_action(ctx, key, a)
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
        if not self._proc_pid or self._master is None:
            log.warning('answer: сессия закрыта (pid=%s)', self._proc_pid)
            await q.answer('Сессия завершена', show_alert=False)
            return
        try:
            n = os.write(self._master, payload)
            log.info('answer: отправлено %r (%d bytes) pid=%s',
                     payload, n, self._proc_pid)
            await q.answer(
                f'Отправлено: {payload.decode(errors="replace").strip() or "Enter"}',
            )
        except OSError as e:
            log.warning('write failed: %s', e)
            await q.answer(f'Ошибка отправки: {e}', show_alert=True)
            return
        self._awaiting_yn = False
        try:
            await self._update_status(bot=q.bot)
        except Exception as e:
            log.debug('post-answer update failed: %s', e)
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
    async def _start_action(self, ctx, key, action):
        if self._running:
            return
        self._running = True
        self._last_action = key
        self._buf = b''
        self._last_edit = 0.0
        self._awaiting_yn = False

        msg = await ctx.bot.send_message(
            chat_id=self.chat_id,
            text=f'{action["icon"]} <b>{action["title"]}</b>\n\n<pre>запуск...</pre>',
            parse_mode='HTML',
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='xkeen:kill')],
            ]),
        )
        self._status_msg_id = msg.message_id

        fork_pid, master = pty.fork()
        if fork_pid == 0:
            try:
                os.environ['DEBIAN_FRONTEND'] = 'noninteractive'
                os.environ['TERM'] = 'dumb'
                os.execv('/bin/sh', ['sh', '-c', action['cmd']])
            except Exception:
                os._exit(1)

        self._proc_pid = fork_pid
        self._master = master

        asyncio.create_task(self._reader_loop(ctx, fork_pid, master))

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
        if not self._status_msg_id:
            return
        if bot is None and ctx is not None:
            bot = ctx.bot
        if bot is None:
            return

        text = _strip_ansi(self._buf.decode('utf-8', errors='replace'))
        tail = text[-1800:] if len(text) > 1800 else text

        items = _detect_menu_items(text)
        kb_rows = []
        if items:
            kb_rows.extend(_menu_row_buttons(items))

        if self._awaiting_yn:
            kb_rows.append([
                InlineKeyboardButton('\u2705 Да (y)', callback_data='xkeen:ans:y'),
                InlineKeyboardButton('\u274c Нет (n)', callback_data='xkeen:ans:n'),
            ])
            kb_rows.append([
                InlineKeyboardButton('\u23ce Enter', callback_data='xkeen:ans:enter'),
                InlineKeyboardButton('\U0001f6d1 Прервать', callback_data='xkeen:kill'),
            ])
        else:
            kb_rows.append([
                InlineKeyboardButton('\U0001f6d1 Отменить', callback_data='xkeen:kill'),
            ])

        kb = InlineKeyboardMarkup(kb_rows)
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
    async def _ask_question(self, ctx):
        """Ставит флаг ожидания и обновляет статусное сообщение
        с кнопками ответа."""
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

        # Фильтр безобидного шума opkg
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

        # Предложить запуск после успешной установки
        offer_start = (
            self._last_action == 'install'
            and rc == 0
            and is_installed()
            and get_service_status() != 'running'
        )
        self._last_action = None

        icon = '\u2705' if rc == 0 else '\u274c'

        # M1 — полным логом с заголовком
        if self._status_msg_id:
            if was_cleanup:
                m1_title = '\U0001f5d1 <b>Удаление остатков</b>'
            elif was_uninstall:
                m1_title = '\U0001f5d1 <b>Удаление XKeen</b>'
            elif offer_start:
                m1_title = '\U0001f4e6 <b>Установка XKeen</b>'
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

        # M2 — короткий
        if offer_start:
            header = (
                f'{icon} <b>Установка XKeen завершена</b>\n'
                f'<i>exit code: {rc}</i>'
            )
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
            header = f'{icon} <b>Завершено</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                      callback_data='xkeen:main')],
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

        # После успешного удаления — сканируем остатки
        if rc == 0 and was_uninstall:
            await self._check_leftovers(ctx)