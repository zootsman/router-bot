"""Точка входа фреймворка router_bot."""
import asyncio
import logging
import os
import socket
import subprocess

# --- IPv4-патч: до импорта telegram, чтобы все соединения шли по IPv4 ---
_orig_getaddrinfo = socket.getaddrinfo
def _ipv4_only(host, port, family=0, type=0, proto=0, flags=0):
    return _orig_getaddrinfo(host, port, socket.AF_INET, type, proto, flags)
socket.getaddrinfo = _ipv4_only
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

    return '\n'.join(lines), InlineKeyboardMarkup(kb)


async def _show_category(q, ctx, cat_name: str):
    """Показывает содержимое категории со статусом каждого модуля."""
    router = ctx.application.bot_data['router']
    mods = [m for m in router.all() if getattr(m, 'category', None) == cat_name]
    if not mods:
        await q.answer('Категория пуста', show_alert=True)
        return

    cat_title = getattr(mods[0], 'category_title', cat_name.capitalize())
    cat_icon = getattr(mods[0], 'category_icon', '\U0001f4c1')

    # Кто установлен — для проверки конфликтов
    installed = set()
    for mod in mods:
        try:
            fn = getattr(mod, 'get_installed', None)
            if fn and fn():
                installed.add(mod.name)
        except Exception as e:
            log.debug('get_installed %s failed: %s', mod.name, e)

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

        # Проверка конфликтов — формат dict{name: reason} или list[name]
        cw = getattr(mod, 'conflicts_with', None)
        if cw:
            items = cw.items() if isinstance(cw, dict) else [(n, '') for n in cw]
            for cname, reason in items:
                if cname not in installed:
                    continue
                other = router.get(cname)
                other_title = other.title if other else cname
                if reason:
                    lines.append(
                        f'   \u26a0\ufe0f Конфликт с <b>{other_title}</b>: '
                        f'<i>{reason}</i>'
                    )
                else:
                    lines.append(
                        f'   \u26a0\ufe0f Конфликт с <b>{other_title}</b>'
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



async def _open_module_card(update, ctx, mod_name: str, icon: str, title: str):
    """Открывает карточку модуля командой. Если у модуля нет send_card_message —
    присылает сообщение с кнопкой."""
    router = ctx.application.bot_data['router']
    mod = router.get(mod_name)
    if not mod:
        await update.message.reply_text(f'{title} недоступен')
        return
    if hasattr(mod, 'send_card_message'):
        try:
            await mod.send_card_message(update, ctx)
            return
        except Exception as e:
            log.exception('send_card_message %s failed: %s', mod_name, e)

    await update.message.reply_text(
        f'{icon} <b>{title}</b>\n\nНажмите кнопку ниже, чтобы открыть модуль.',
        parse_mode='HTML',
        reply_markup=InlineKeyboardMarkup([[
            InlineKeyboardButton(f'{icon} Открыть {title}',
                                 callback_data=f'{mod_name}:main'),
        ]]),
    )


async def _cmd_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    router = ctx.application.bot_data['router']
    text, kb = await _build_main_menu(router)
    await update.message.reply_text(text, parse_mode='HTML', reply_markup=kb)


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
    msg = await update.message.reply_text(
        '\U0001f310 Проверяю зеркала Entware... (5-10 сек)',
    )
    results = await check_mirrors()
    current = get_current_mirror()
    text = build_mirrors_text(results, current)
    kb = build_mirrors_kb(results)
    try:
        await msg.edit_text(text, parse_mode='HTML', reply_markup=kb)
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
    enabled = {m.name for m in router.all()}

    lines = ['\U0001f916 <b>Router Bot</b>', '', '<b>Основные команды:</b>']
    lines.append('/start   \u2014 главное меню')
    lines.append('/help    \u2014 эта справка')
    lines.append('/restart \u2014 перезапуск бота')
    lines.append('/reboot  \u2014 перезагрузка роутера')
    lines.append('/mirrors \u2014 проверка зеркал Entware')

    mod_cmds = []
    if 'net_watch' in enabled:
        mod_cmds.append('/net     \u2014 Net Watch')
        mod_cmds.append('/status  \u2014 список клиентов')
        mod_cmds.append('/stats   \u2014 статистика')
    if 'ssh_control' in enabled:
        mod_cmds.append('/ssh     \u2014 SSH Control')
    if 'system' in enabled:
        mod_cmds.append('/sys     \u2014 Состояние системы')
    if 'hydraroute' in enabled:
        mod_cmds.append('/hr      \u2014 HydraRoute')
    if 'flashkeen' in enabled:
        mod_cmds.append('/fk      \u2014 Flashkeen')
    if 'xkeen' in enabled:
        mod_cmds.append('/xk      \u2014 XKeen')
    if 'bird' in enabled:
        mod_cmds.append('/bd      \u2014 BIRD')
    if 'mtproxy' in enabled:
        mod_cmds.append('/mt      \u2014 MTProxy')
    if 'keen_pbr' in enabled:
        mod_cmds.append('/kp      \u2014 Keen-PBR')
    if 'neofit' in enabled:
        mod_cmds.append('/nf      \u2014 NeoFit')
    if 'usque_keenetic' in enabled:
        mod_cmds.append('/usque   \u2014 Usque WARP')

    if mod_cmds:
        lines.append('')
        lines.append('<b>Модули:</b>')
        lines.extend(mod_cmds)

    lines.append('')
    lines.append('<b>Активные модули:</b>')
    for mod in router.all():
        desc = getattr(mod, 'description', '')
        if desc:
            lines.append(f'{mod.icon} <b>{mod.title}</b> \u2014 {desc}')
        else:
            lines.append(f'{mod.icon} <b>{mod.title}</b>')

    lines.append('')
    lines.append('<i>Полный список команд \u2014 нажмите / в поле ввода.</i>')

    kb = InlineKeyboardMarkup([
        [InlineKeyboardButton('\U0001f680 Открыть главное меню', callback_data='router:main')],
    ])
    await update.message.reply_text(
        '\n'.join(lines), parse_mode='HTML', reply_markup=kb,
    )

async def _cmd_net(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    router = ctx.application.bot_data['router']
    mod = router.get('net_watch')
    if mod and hasattr(mod, 'send_card_message'):
        await mod.send_card_message(update, ctx)
    else:
        await update.message.reply_text('Net Watch недоступен')


async def _cmd_ssh(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    router = ctx.application.bot_data['router']
    mod = router.get('ssh_control')
    if mod and hasattr(mod, 'send_card_message'):
        await mod.send_card_message(update, ctx)
    else:
        await update.message.reply_text('SSH Control недоступен')


async def _cmd_sys(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    await _open_module_card(update, ctx, 'system', '🖥', 'System')


async def _cmd_hr(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    await _open_module_card(update, ctx, 'hydraroute', '\U0001f40d', 'HydraRoute')


async def _cmd_fk(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    await _open_module_card(update, ctx, 'flashkeen', '\U0001f4be', 'Flashkeen')


async def _cmd_xk(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    await _open_module_card(update, ctx, 'xkeen', '\U0001f43e', 'XKeen')


async def _cmd_bd(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    await _open_module_card(update, ctx, 'bird', '\U0001f426', 'BIRD')


async def _cmd_mt(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    await _open_module_card(update, ctx, 'mtproxy', '\U0001f310', 'MTProxy')


async def _cmd_kp(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    await _open_module_card(update, ctx, 'keen_pbr', '\U0001f6e4', 'Keen-PBR')


async def _cmd_nf(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    await _open_module_card(update, ctx, 'neofit', '\U0001f500', 'NeoFit')


async def _cmd_usque(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    await _open_module_card(update, ctx, 'usque_keenetic', '\U0001f310', 'Usque WARP')


async def _on_router_main(query, ctx):
    """Callback 'router:main' — возврат в главное меню."""
    await query.answer()
    router = ctx.application.bot_data['router']
    text, kb = await _build_main_menu(router)
    try:
        await query.edit_message_text(text, parse_mode='HTML', reply_markup=kb)
    except Exception as e:
        if 'not modified' not in str(e).lower():
            raise


async def post_init(app):
    # Записываем время старта сессии для статистики Net Watch
    try:
        import json as _json
        import os as _os
        from datetime import datetime as _dt
        stats_path = '/opt/router_bot/data/net_watch/stats.json'
        _os.makedirs(_os.path.dirname(stats_path), exist_ok=True)
        data = {}
        if _os.path.exists(stats_path):
            try:
                with open(stats_path) as f:
                    data = _json.load(f)
            except Exception:
                data = {}
        data['session_started'] = _dt.now().isoformat(timespec='seconds')
        tmp = stats_path + '.tmp'
        with open(tmp, 'w') as f:
            _json.dump(data, f, ensure_ascii=False, indent=2)
        _os.replace(tmp, stats_path)
        log.info('Session started at %s', data['session_started'])
    except Exception as e:
        log.warning('session_started write failed: %s', e)

    router = app.bot_data['router']

    # 1. Меню команд — глобальные + только для активных модулей
    enabled_names = {m.name for m in router.all()}

    cmds = [
        BotCommand('start',   '\U0001f680 Главное меню'),
        BotCommand('help',    '\u2753 Помощь'),
        BotCommand('restart', '\U0001f504 Перезапуск бота'),
        BotCommand('reboot',  '\U0001f504 Перезагрузка роутера'),
        BotCommand('mirrors', '\U0001f310 Проверка зеркал Entware'),
    ]
    if 'net_watch' in enabled_names:
        cmds.append(BotCommand('net', '\U0001f4e1 Net Watch'))
    if 'ssh_control' in enabled_names:
        cmds.append(BotCommand('ssh', '\U0001f4bb SSH Control'))
    if 'system' in enabled_names:
        cmds.append(BotCommand('sys', '\U0001f5a5 Система'))
    if 'hydraroute' in enabled_names:
        cmds.append(BotCommand('hr', '\U0001f40d HydraRoute'))
    if 'flashkeen' in enabled_names:
        cmds.append(BotCommand('fk', '\U0001f4be Flashkeen'))
    if 'xkeen' in enabled_names:
        cmds.append(BotCommand('xk', '\U0001f43e XKeen'))
    if 'bird' in enabled_names:
        cmds.append(BotCommand('bd', '\U0001f426 BIRD'))
    if 'mtproxy' in enabled_names:
        cmds.append(BotCommand('mt', '\U0001f310 MTProxy'))
    if 'keen_pbr' in enabled_names:
        cmds.append(BotCommand('kp', '\U0001f6e4 Keen-PBR'))
    if 'neofit' in enabled_names:
        cmds.append(BotCommand('nf', '\U0001f500 NeoFit'))
    if 'usque_keenetic' in enabled_names:
        cmds.append(BotCommand('usque', '\U0001f310 Usque WARP'))
    for mod in router.all():
        for cmd, desc in getattr(mod, 'commands', []):
            cmds.append(BotCommand(cmd, desc))

    try:
        await app.bot.set_my_commands(cmds)
        log.info('Commands registered: %s', [c.command for c in cmds])
    except Exception as e:
        log.warning('set_my_commands failed: %s', e)

    # 2. Инициализация модулей
    for mod in router.all():
        try:
            await mod.startup(app)
        except Exception as e:
            log.exception('Module %s startup failed: %s', mod.name, e)

    log.info('Router bot started')


def main():
    logging.basicConfig(
        format='%(asctime)s [%(levelname)s] %(message)s',
        level=logging.INFO,
        handlers=[
            logging.FileHandler('/opt/var/log/router_bot.log'),
        ],
    )
    for noisy in ('httpx', 'httpcore', 'telegram.ext.Updater', 'telegram.request'):
        logging.getLogger(noisy).setLevel(logging.CRITICAL)

    load_config()

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

    if 'net_watch' in enabled_set:
        from modules.net_watch.module import NetWatchModule
        router.register(NetWatchModule(chat_id))

    if 'ssh_control' in enabled_set:
        from modules.ssh_control.module import SSHControlModule
        router.register(SSHControlModule(chat_id))

    if 'system' in enabled_set:
        from modules.system.module import SystemModule
        router.register(SystemModule(chat_id))

    if 'hydraroute' in enabled_set:
        from modules.hydraroute.module import HydraRouteModule
        router.register(HydraRouteModule(chat_id))

    if 'flashkeen' in enabled_set:
        from modules.flashkeen.module import FlashkeenModule
        router.register(FlashkeenModule(chat_id))

    if 'xkeen' in enabled_set:
        from modules.xkeen.module import XKeenModule
        router.register(XKeenModule(chat_id))

    if 'bird' in enabled_set:
        from modules.bird.module import BirdModule
        router.register(BirdModule(chat_id))

    if 'mtproxy' in enabled_set:
        from modules.mtproxy.module import MTProxyModule
        router.register(MTProxyModule(chat_id))

    if 'keen_pbr' in enabled_set:
        from modules.keen_pbr.module import KeenPbrModule
        router.register(KeenPbrModule(chat_id))

    if 'neofit' in enabled_set:
        from modules.neofit.module import NeoFitModule
        router.register(NeoFitModule(chat_id))

    if 'usque_keenetic' in enabled_set:
        from modules.usque_keenetic.module import UsqueKeeneticModule
        router.register(UsqueKeeneticModule(chat_id))

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

    enabled_names = {m.name for m in router.all()}
    if 'net_watch' in enabled_names:
        app.add_handler(CommandHandler('net', _cmd_net))
    if 'ssh_control' in enabled_names:
        app.add_handler(CommandHandler('ssh', _cmd_ssh))
    if 'system' in enabled_names:
        app.add_handler(CommandHandler('sys', _cmd_sys))
    if 'hydraroute' in enabled_names:
        app.add_handler(CommandHandler('hr', _cmd_hr))
    if 'flashkeen' in enabled_names:
        app.add_handler(CommandHandler('fk', _cmd_fk))
    if 'xkeen' in enabled_names:
        app.add_handler(CommandHandler('xk', _cmd_xk))
    if 'bird' in enabled_names:
        app.add_handler(CommandHandler('bd', _cmd_bd))
    if 'mtproxy' in enabled_names:
        app.add_handler(CommandHandler('mt', _cmd_mt))
    if 'keen_pbr' in enabled_names:
        app.add_handler(CommandHandler('kp', _cmd_kp))
    if 'neofit' in enabled_names:
        app.add_handler(CommandHandler('nf', _cmd_nf))
    if 'usque_keenetic' in enabled_names:
        app.add_handler(CommandHandler('usque', _cmd_usque))

    # Общий callback — обрабатывает router:main отдельно, остальное — в роутер
    async def _global_callback(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        q = update.callback_query
        if q.data.startswith('router:cat:'):
            cat_name = q.data[len('router:cat:'):]
            await q.answer()
            return await _show_category(q, ctx, cat_name)
        if q.data == 'bird:edit_new':
            mod = ctx.application.bot_data['router'].get('bird')
            if mod:
                await mod._ask_new_config(q, ctx)
            return
        if q.data == 'router:mirrors':
            return await _on_mirrors(q, ctx)
        if q.data == 'router:mirrors_check':
            return await _on_mirrors_check(q, ctx)
        if q.data.startswith('router:mirror_apply:'):
            return await _on_mirror_apply(q, ctx, q.data[len('router:mirror_apply:'):])
        if q.data == 'mtproxy:edit_new':
            mod = ctx.application.bot_data['router'].get('mtproxy')
            if mod:
                await mod._ask_new_config(q, ctx)
            return
        if q.data == 'router:restart_confirm':
            return await _do_restart_confirm(q, ctx)
        if q.data == 'router:reboot_confirm':
            return await _do_reboot_confirm(q, ctx)
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

    log.info('Starting router bot...')
    app.run_polling(drop_pending_updates=True)