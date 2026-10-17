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
    commands = []

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
        app.add_handler(MessageHandler(
            filters.TEXT & ~filters.COMMAND,
            self._handle_text,
        ))
        log.info('SSH Control module started')

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
        await update.message.reply_text(text, parse_mode='HTML', reply_markup=kb)

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
        if str(update.effective_chat.id) != self.chat_id:
            return
        text = (update.message.text or '').strip()
        if not text:
            return
        if self.state == 'idle':
            return

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

    async def _wizard_ip(self, update, ctx, text):
        self.temp['ip'] = text
        self.state = 'wizard:port'
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton('✅ Порт 22 (по умолчанию)', callback_data='ssh_control:port_default')],
            [InlineKeyboardButton('❌ Отмена', callback_data='ssh_control:cancel')],
        ])
        await update.message.reply_text(
            f"<b>Шаг 2/4.</b> Отправьте порт SSH или нажмите кнопку ниже:",
            parse_mode='HTML', reply_markup=kb,
        )

    async def _wizard_port(self, update, ctx, text):
        try:
            port = int(text)
            if not (1 <= port <= 65535):
                raise ValueError
        except ValueError:
            await update.message.reply_text('❌ Порт должен быть числом 1–65535. Попробуйте снова.')
            return
        self.temp['port'] = port
        self.state = 'wizard:user'
        await update.message.reply_text(
            f"<b>Шаг 3/4.</b> Отправьте имя пользователя:",
            parse_mode='HTML',
        )

    async def _wizard_user(self, update, ctx, text):
        self.temp['user'] = text
        self.state = 'wizard:pass'
        await update.message.reply_text(
            f"<b>Шаг 4/4.</b> Отправьте пароль.\n\n"
            f"⚠️ Я сразу удалю его из чата.",
            parse_mode='HTML',
        )
    async def _wizard_pass(self, update, ctx, text):
        log.info('wizard:pass received password len=%d', len(text))
        self.temp['password'] = text
        msg_id = update.message.message_id
        chat_id = update.message.chat_id
        await self._try_delete_msg(ctx, chat_id, msg_id)
        try:
            for delay in (3, 10, 30):
                ctx.job_queue.run_once(
                    self._delete_retry, when=delay,
                    data={'chat_id': chat_id, 'msg_id': msg_id},
                )
        except Exception as e:
            log.warning('job_queue failed: %s', e)

        ip = self.temp.get('ip', '')
        port = self.temp.get('port', 22)
        log.info('wizard:pass probing %s:%s', ip, port)

        try:
            status = await update.message.reply_text(
                f'🔐 Проверяю SSH-хост...\n\n'
                f'<code>{_esc(ip)}:{port}</code>\n'
                f'<i>Может занять до 20 секунд.</i>',
                parse_mode='HTML',
            )
            log.info('wizard:pass status sent id=%s', status.message_id)
        except Exception as e:
            log.exception('wizard:pass send status FAILED: %s', e)
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
                await status.edit_text(
                    f'❌ <b>Не удалось подключиться</b>\n\n'
                    f'Хост: <code>{_esc(ip)}:{port}</code>\n'
                    f'Ошибка: <i>{_esc(err)}</i>',
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
            await status.edit_text(
                f'🔐 <b>Проверка SSH host key</b>\n\n'
                f'Хост: <code>{_esc(ip)}:{port}</code>\n'
                f'Юзер: <code>{_esc(self.temp.get("user",""))}</code>\n\n'
                f'Тип: <code>{_esc(probe["key_type"] or "?")}</code>\n'
                f'Fingerprint:\n<code>{_esc(probe["fingerprint"])}</code>\n\n'
                f'✅ Принять и сохранить хост?',
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
            await update.message.reply_text('❌ Хост не найден.')
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

        msg = await update.message.reply_text(
            f"⏳ Выполняю: <code>{_esc(code[:200])}</code>",
            parse_mode='HTML',
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton('🛑 Отменить', callback_data='ssh_control:abort')],
            ]),
        )
        self.interactive_msg_id = msg.message_id

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
                    message_id=msg.message_id,
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

        status = await update.message.reply_text(
            f'⏳ Выполняю блок ({len(script.splitlines())} строк)...',
            reply_markup=InlineKeyboardMarkup([
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
            await status.edit_text(
                f'❌ <b>Ошибка</b>\n\n<i>{_esc(str(e))}</i>',
                parse_mode='HTML',
            )
            return

        try:
            await status.delete()
        except Exception:
            pass

        out_clean = _filter_ssh_noise(out or '')
        err_clean = _filter_ssh_noise(err)
        body = out_clean
        if err_clean:
            body += ('\n' if body else '') + f'[stderr]\n{err_clean}'

        header = f'$ script [{len(script.splitlines())} lines]\n[exit code: {rc}]\n\n'
        full = header + body

        if len(full) <= MAX_MSG:
            await self._send_block(update, full)
        else:
            for chunk in _split(full):
                await self._send_block(update, chunk)

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
            [
                InlineKeyboardButton('✅ Да (y)', callback_data='ssh_control:answer:y'),
                InlineKeyboardButton('❌ Нет (n)', callback_data='ssh_control:answer:n'),
            ],
            [
                InlineKeyboardButton('⏎ Enter', callback_data='ssh_control:answer:enter'),
                InlineKeyboardButton('🛑 Прервать', callback_data='ssh_control:answer:kill'),
            ],
        ])
        try:
            await ctx.bot.send_message(
                chat_id=self.chat_id,
                text=f"❓ <b>Требуется ответ</b>\n\n<pre>{_esc(tail)}</pre>",
                parse_mode='HTML',
                reply_markup=kb,
            )
            self.interactive_question_sent = True
        except Exception:
            pass

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

        if self.interactive_msg_id:
            try:
                await ctx.bot.delete_message(
                    chat_id=chat_id, message_id=self.interactive_msg_id,
                )
            except Exception:
                pass
            self.interactive_msg_id = None

        if len(body) <= MAX_MSG:
            await ctx.bot.send_message(
                chat_id=chat_id,
                text=f"<pre>{_esc(body)}</pre>",
                parse_mode='HTML',
            )
        else:
            for chunk in _split(body):
                await ctx.bot.send_message(
                    chat_id=chat_id,
                    text=f"<pre>{_esc(chunk)}</pre>",
                    parse_mode='HTML',
                )

        self.interactive_out_buffer = []
        self.state = f'exec:{hid}'
        self.active_hid = hid

    async def _send_block(self, update, text):
        try:
            await update.message.reply_text(
                f"<pre>{_esc(text)}</pre>", parse_mode='HTML',
            )
        except Exception:
            await update.message.reply_text(text)

    async def _edit(self, q, text, kb):
        try:
            await q.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
        except Exception as e:
            if 'not modified' not in str(e).lower():
                raise