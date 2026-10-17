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

            lines.append(f'Web UI: <code>{_esc(PBR_WEB)}</code>')
        else:
            lines.append('❌ Не установлен')
            # проверка конфликтов
            import os as _os
            if _os.path.isdir('/opt/etc/xkeen'):
                lines.append('')
                lines.append('⚠️ <b>Конфликт с XKeen</b>')
                lines.append('<i>Удалите XKeen перед установкой.</i>')
            if _os.path.isdir('/opt/etc/HydraRoute'):
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
                InlineKeyboardButton('\U0001f4c4 Перечитать', callback_data='keen_pbr:ask:reload'),
            ])
            rows.append([InlineKeyboardButton(
                '\U0001f4c4 Показать конфиг', callback_data='keen_pbr:show_config')])
            rows.append([InlineKeyboardButton(
                '\u2699\ufe0f Редактировать конфиг', callback_data='keen_pbr:edit_config')])
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
        await update.message.reply_text(text, parse_mode='HTML', reply_markup=kb)

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
            await self._start_action(ctx, key, a['cmd'])
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

    async def _start_action(self, ctx, key, cmd):
        if self._running:
            return
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
                [InlineKeyboardButton('\U0001f6d1 Отменить', callback_data='keen_pbr:kill')],
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
        try:
            while True:
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

    async def _update_status(self, ctx):
        if not self._status_msg_id:
            return
        text = _strip_ansi(self._buf.decode('utf-8', errors='replace'))
        tail = text[-1800:] if len(text) > 1800 else text
        try:
            await ctx.bot.edit_message_text(
                chat_id=self.chat_id,
                message_id=self._status_msg_id,
                text=f'⏳ <b>Выполняется...</b>\n\n<pre>{_esc(tail)}</pre>',
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton('\U0001f6d1 Отменить', callback_data='keen_pbr:kill')],
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
            and is_installed()
            and not is_running()
        )
        self._last_action = None

        icon = '\u2705' if rc == 0 else '\u274c'

        if self._status_msg_id:
            if was_cleanup:
                m1_title = '\U0001f5d1 <b>Удаление остатков</b>'
            elif was_uninstall:
                m1_title = '\U0001f5d1 <b>Удаление keen-pbr</b>'
            elif offer_start:
                m1_title = '\U0001f4e6 <b>Установка keen-pbr</b>'
            else:
                m1_title = '\u2699\ufe0f <b>Операция</b>'
            tail_m1 = text[-3500:] if len(text) > 3500 else text
            try:
                await ctx.bot.edit_message_text(
                    chat_id=self.chat_id,
                    message_id=self._status_msg_id,
                    text=f'{m1_title}\n\n<pre>{_esc(tail_m1)}</pre>',
                    parse_mode='HTML',
                    reply_markup=None,
                )
            except Exception as e:
                log.debug('final M1 update failed: %s', e)
            self._status_msg_id = None

        if offer_start:
            header = (
                f'{icon} <b>Установка keen-pbr завершена</b>\n'
                f'<i>exit code: {rc}</i>'
            )
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
            header = f'{icon} <b>Завершено</b> (exit code: {rc})'
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton('\u2b05\ufe0f Назад',
                                      callback_data='keen_pbr:main')],
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
            msg = await ctx.bot.send_message(
                chat_id=self.chat_id,
                text='\U0001f5d1 <b>Удаление keen-pbr</b>\n\n<pre>запуск...</pre>',
                parse_mode='HTML',
                reply_markup=InlineKeyboardMarkup([
                    [InlineKeyboardButton('\U0001f6d1 Отменить',
                                          callback_data='keen_pbr:kill')],
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
            safe = p.replace("'", "'\\\\''")
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
            text='\U0001f5d1 <b>Удаление остатков keen-pbr</b>\n\n<pre>запуск...</pre>',
            parse_mode='HTML',
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton('\U0001f6d1 Отменить',
                                      callback_data='keen_pbr:kill')],
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