# Router Bot

Многомодульный Telegram-бот для управления роутерами (преимущественно Keenetic и Linux-маршрутизаторами).

## Возможности

- **Ядро (`core`):** модульная архитектура загрузки плагинов, конфиги, утилиты, обертка командной строки (`rb`).
- **Модули (`modules`):**
  - **`net_watch`** — мониторинг сетевой активности и пинг-чекереры.
  - **`ssh_control`** — управление SSH-подключениями к удаленным узлам.
  - **`system`** — системный мониторинг (CPU, RAM, диск, службы).
  - **`hydraroute`** — управление маршрутизацией и hydra-интеграцией.
  - **`flashkeen` / `xkeen`** — утилиты для настройки и оптимизации роутеров Keenetic.
  - **`bird`** — динамическая маршрутизация (BIRD routing daemon).
  - **`mtproxy`** — управление MTProxy.
  - **`keen_pbr`** — Policy-Based Routing для Keenetic.
  - **`neofit`** — системные утилиты и твики.
  - **`usque_keenetic`** — дополнительные интеграции с Keenetic.

## Установка

Для установки или обновления используйте встроенный скрипт:

```bash
sh router_bot_setup.sh
```
```bash
opkg update && opkg install curl ca-certificates
curl -fsSL https://raw.githubusercontent.com/zootsman/router-bot/master/router_bot_setup.sh -o /tmp/router_bot_setup.sh
chmod +x /tmp/router_bot_setup.sh
sh /tmp/router_bot_setup.sh
```

## Управление через командную строку (`rb`)

После установки в системе доступна удобная утилита командной строки **`rb`**:

### Сервис
- `rb start` (или `s`) — запустить бота
- `rb stop` (или `x`) — остановить бота
- `rb restart` (или `r`) — перезапустить бота
- `rb reset` — сбросить giveup-маркер (после 10 падений)
- `rb status` (или `st`) — статус (процессы, порт, состояние)

### Диагностика
- `rb logs [N]` — показать последние `N` строк лога (по умолчанию 40)
- `rb follow` (или `f`) — просмотр лога в реальном времени
- `rb version` (или `v`) — версия бота
- `rb config` (или `c`) — содержимое файла `config.env`
- `rb modules` (или `m`) — список включенных модулей
- `rb routes` — просмотр Telegram-маршрутов (table 16385)
- `rb health` — запустить healthcheck
- `rb rebuild` — перестроить маршруты Telegram
- `rb procs` — дерево процессов бота

### Обслуживание
- `rb update` (или `u`) — обновить
- `rb uninstall` — подсказка по удалению

---

## Структура проекта

- `main.py` — точка входа бота.
- `core/` — ядро, конфиги, роутер команд.
- `modules/` — подключаемые функциональные модули.
- `uninstall.sh` — скрипт удаления.
