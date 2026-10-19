# Router Bot

Многомодульный Telegram-бот для управления роутерами **Keenetic** (Entware) и другими Linux-маршрутизаторами. Работает на BusyBox `ash`, не требует `bash`.

Модульная архитектура: каждый плагин — независимый класс со своим UI, обработчиками и состоянием. Основной фреймворк — тонкий: роутинг callback'ов, меню, конфиг, обновления.

---

## Возможности

- **12 модулей** — от мониторинга сети до управления BGP и Xray
- **Управление из Telegram и из терминала** — CLI-утилита `rb` с 20+ командами
- **Установка/обновление одной командой**, повторный запуск работает как upgrade
- **Сохранение пользовательских правок** — при обновлении изменённые файлы бэкапятся в `.user_backup/`
- **Автоперезапуск при падениях** — wrapper делает до 10 попыток (потом GIVEUP, сбрасывается через `rb reset`)
- **Healthcheck раз в минуту** через cron + автодетект смены WAN-IP
- **Умный выбор VPN-туннеля** для `api.telegram.org` с проверкой доступности
- **Валидация токена и chat_id** при установке через `api.telegram.org/getMe` и `sendMessage`
- **Работа только по IPv4** — отключает IPv6 для getaddrinfo (обход проблем с провайдерами)

---

## Модули

| Модуль | Команда | Описание |
|--------|---------|----------|
| 📡 **Net Watch** | `/net`, `/status`, `/stats` | Мониторинг сетевых клиентов: список онлайн, история подключений, блокировка по MAC, определение моделей по SSDP, статистика трафика |
| 💻 **SSH Control** | `/ssh` | Управление SSH-хостами: интерактивные команды, скрипты, PIN-код fingerprint при добавлении |
| 🖥 **System** | `/sys` | CPU/RAM/Swap/Disk, версия и модель KeeneticOS, проверка и установка обновлений прошивки через ndmc |
| 🐍 **HydraRoute** | `/hr` | HydraRoute Neo / HRweb / hrdns: установка, обновление, watchlist, проверка домена (`match`) |
| 💾 **Flashkeen** | `/fk` | Менеджер дисков и Entware: интерактивный терминал прямо в Telegram |
| 🐾 **XKeen** | `/xk` | Xray/Mihomo маршрутизация: управление, обновления, диагностика, смена канала |
| 🐦 **BIRD** | `/bd` | Демон BGP/OSPF, работа с протоколами, маршрутами и интерфейсами |
| 🌐 **MTProxy** | `/mt` | MTProto-прокси для Telegram, ссылка-приглашение в один клик |
| 🛤 **Keen-PBR** | `/kp` | Policy-Based Routing, валидация YAML, диагностика |
| 🔀 **NeoFit** | `/nf` | Веб-панель управления Xray/Sing-Box (порт `:92`) |
| ☁️ **Usque WARP** | `/usque` | Cloudflare WARP (MASQUE) клиент |
| 🛡 **AWG Manager** | `/awg` | AmneziaWG / Sing-box: туннели, веб-панель на `:2222`, MCP-сервер |

Модули можно включать/выключать через `ENABLED_MODULES` в `config.env`. У модулей категории `services` есть общее подменю «Сервис» в главном меню.

---

## Требования

- **Keenetic** с прошивкой 4.1+ (или любой Linux с BusyBox `ash`)
- **Entware** (`opkg`) установлен в `/opt`
- `python3` (>=3.11) + `python-telegram-bot[job-queue]` (>=20.x)
- `curl`, `openssh-client`, `openssh-keygen`, `ca-certificates`
- `/bin/ndmc` (на Keenetic присутствует из коробки)

Протестировано на **Keenetic Viva**, BusyBox v1.37.0, `mipselsf-k3.4`, Python 3.13.

---

## Установка

### Быстрая (одной командой)

```sh
opkg update && opkg install curl ca-certificates
curl -fsSL https://raw.githubusercontent.com/zootsman/router-bot/master/router_bot_setup.sh -o /tmp/router_bot_setup.sh
chmod +x /tmp/router_bot_setup.sh
sh /tmp/router_bot_setup.sh
```
Локальная установка, если скрипт уже на устройстве
```sh
sh router_bot_setup.sh
```
После установки доступна утилита (rb)
Управление из терминала
```sh
Команда.           | Описание
rb start / rb s    | Запустить бота
rb stop / rb x     | Остановить
rb restart / rb r  | Перезапустить
rb reset.          | Сбросить GIVEUP-маркер (после 10 падений)
rb status / rb st  | Статус: процессы, PID, маршруты TG, версия
```
Диагностика
```sh
Команда           | Описание
rb logs [N]       | Последние N строк лога (по умолчанию 40)
rb follow / rb f  | Хвост лога в реальном времени
rb version / rb v | Версия бота
rb modules / rb m | Включённые модули
rb procs / rb ps  | Дерево процессов бота
rb routes         | Маршруты Telegram (table 16385)
rb tgtest.        | Диагностика связи с Telegram: DNS, TCP, HTTP, маршруты
rb ipv6 [on\|off] | Вкл/выкл IPv6 (по умолчанию — только IPv4)
rb health         | Запустить healthcheck вручную
rb rebuild        | Перестроить маршруты Telegram
```
Конфиг
```sh
Команда                 | Описание
rb config / rb c        | Показать config.env
rb config init          | Создать заново (визард с валидацией)
rb config tun           | Перенастроить туннель к api.telegram.org
rb config edit          | Открыть в $EDITOR (nano/vi)
rb config restore       | Восстановить из .bak
rb config backup        | Обновить бэкап
rb config check         | Проверить обязательные ключи
rb config get KEY       | Показать значение ключа
rb config set KEY VALUE | Изменить ключ
```
Обновление/удаление
```sh
Команда             | Описание
rb update / rb u    | Скачать и запустить свежий установщик
rb uninstall        | Подсказка по удалению
