"""Общие утилиты для всех модулей."""
import json
import os

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

    if targets:
        kb_rows.append([InlineKeyboardButton(
            '\u2705 Удалить с этими настройками',
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

ENTWARE_MIRRORS = [
    'http://bin.entware.net/mipselsf-k3.4',
    'http://mirrors.nju.edu.cn/entware/mipselsf-k3.4',
    'http://mirrors.bfsu.edu.cn/entware/mipselsf-k3.4',
    'https://mirror.vinet.io/entware/mipselsf-k3.4',
    'http://entware.mirror.digitalpacific.com.au/mipselsf-k3.4',
]

OPKG_CONF = '/opt/etc/opkg.conf'


def _check_one_sync(url, timeout=4):
    start = _time.time()
    try:
        r = _sp.run(
            ['/opt/bin/curl', '-sI', '--max-time', str(timeout),
             '-o', '/dev/null', '-w', '%{http_code}',
             url + '/Packages.gz'],
            capture_output=True, text=True, timeout=timeout + 2,
        )
        elapsed = _time.time() - start
        code = (r.stdout or '').strip()
        ok = code in ('200', '301', '302', '304')
        return {'url': url, 'time': round(elapsed, 2), 'ok': ok, 'code': code}
    except Exception as e:
        return {'url': url, 'time': 0, 'ok': False, 'code': str(e)[:40]}


async def check_mirrors():
    import asyncio as _a
    tasks = [_a.to_thread(_check_one_sync, u) for u in ENTWARE_MIRRORS]
    return await _a.gather(*tasks)


def get_current_mirror():
    if not __import__('os').path.exists(OPKG_CONF):
        return ''
    try:
        with open(OPKG_CONF) as f:
            for line in f:
                if line.startswith('src/gz') or line.startswith('src '):
                    parts = line.split()
                    if len(parts) >= 3:
                        url = parts[-1]
                        # нормализуем до базового (без /keenetic)
                        for base in ENTWARE_MIRRORS:
                            if url.startswith(base):
                                return base
                        return url
    except Exception:
        pass
    return ''


def apply_mirror(new_base):
    """Переписывает opkg.conf, меняя известные зеркала Entware на новое."""
    import os as _os
    if not _os.path.exists(OPKG_CONF):
        return False, 'opkg.conf не найден'
    try:
        with open(OPKG_CONF) as f:
            lines = f.readlines()
    except Exception as e:
        return False, f'Ошибка чтения: {e}'

    changed = 0
    new_lines = []
    for line in lines:
        orig = line
        stripped = line.strip()
        if stripped.startswith('src/gz') or stripped.startswith('src '):
            parts = stripped.split()
            if len(parts) >= 3:
                url = parts[-1]
                # меняем, если URL относится к одному из известных зеркал
                for old_base in ENTWARE_MIRRORS:
                    if url.startswith(old_base):
                        new_url = url.replace(old_base, new_base, 1)
                        # заменим в строке только URL
                        idx = line.find(url)
                        line = line[:idx] + new_url + line[idx+len(url):]
                        changed += 1
                        break
        new_lines.append(line)

    if changed == 0:
        return False, 'Нечего менять (нет известных зеркал в конфиге)'

    try:
        with open(OPKG_CONF, 'w') as f:
            f.writelines(new_lines)
        return True, f'Обновлено строк: {changed}'
    except Exception as e:
        return False, f'Ошибка записи: {e}'


def build_mirrors_text(results, current):
    """Формирует текст карточки со списком зеркал."""
    lines = ['\U0001f310 <b>Зеркала Entware</b>', '']
    if current:
        lines.append(f'Текущее: <code>{current}</code>')
    lines.append('')
    lines.append('<b>Проверка отклика:</b>')
    for i, r in enumerate(results, 1):
        mark = '\u2705' if r['ok'] else '\u274c'
        t = f"{r['time']}с" if r['ok'] else r['code'][:20]
        short = r['url'].replace('http://', '').replace('https://', '')[:40]
        lines.append(f'{mark} {i}. <code>{short}</code> — {t}')
    return '\n'.join(lines)


def build_mirrors_kb(results):
    from telegram import InlineKeyboardButton, InlineKeyboardMarkup
    rows = []
    for i, r in enumerate(results, 1):
        if r['ok']:
            rows.append([InlineKeyboardButton(
                f'\U0001f4e6 Применить #{i}',
                callback_data=f'router:mirror_apply:{i-1}')])
    rows.append([InlineKeyboardButton(
        '\U0001f504 Проверить снова', callback_data='router:mirrors_check')])
    rows.append([InlineKeyboardButton(
        '\u2b05\ufe0f Назад', callback_data='router:main')])
    return InlineKeyboardMarkup(rows)