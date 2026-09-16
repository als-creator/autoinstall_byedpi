# ByeDPI Universal Installer

Универсальный установщик и конфигуратор **ByeDPI** для **любого дистрибутива
Linux** — без пакетного менеджера. Скрипт сам скачивает готовый бинарник
`ciadpi` с GitHub (hufrea/byedpi releases), сам определяет архитектуру и сам
получает права root (root → sudo → su), поэтому работает и на Arch, и на
Debian/Ubuntu, и на ALT Linux (где нет sudo), и на Fedora, и на любых других.

Установка одной командой:

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi/main/install_byedpi_generic.sh -o /tmp/byedpi.sh && sh /tmp/byedpi.sh
```

> **Нужен установщик именно для Arch Linux (пакет из AUR)?** — смотрите
> [als-creator/autoinstall_byedpi_archlinux](https://github.com/als-creator/autoinstall_byedpi_archlinux).
>
> **Нужен установщик для ALT Linux (пакет через apt-get)?** — смотрите
> [als-creator/autoinstall_byedpi_altlinux](https://github.com/als-creator/autoinstall_byedpi_altlinux).

---

## Описание сервиса

**ByeDPI** — локальный прокси-демон, который «разжимает» ответы по протоколам
DPI (Deep Packet Inspection) провайдера. Он не подменяет DNS и не маскирует
трафик полностью, а лишь корректирует способ отправки запросов так, чтобы
блокирующая сторона не могла по характерным признакам отличить реальный трафик
и зарезать его.

Как это применяется на практике:

- YouTube / rutracker / instagram и прочие заблокированные домены продолжают
  работать без VPN.
- Весь остальной трафик идёт мимо ByeDPI и не затрагивается.

### Что делает скрипт

1. Определяет архитектуру (`x86_64`, `aarch64`, `armv7l`, `armv6`, `i686`,
   `mips`, `mipsel`, `powerpc`) и скачивает готовый бинарник `ciadpi` с GitHub
   (hufrea/byedpi releases) в `/usr/local/bin/ciadpi`.
2. Пишет конфигурацию отдельными файлами: `/etc/byedpi/port`, `/etc/byedpi/rule`,
   `/etc/byedpi/hosts` и управляющий `/etc/byedpi/conf` с переменными-указателями
   на эти файлы.
3. При первой установке **сам подбирает стратегию**: прогоняет список доменов
   через несколько кандидатов правил desync и записывает лучшее в `rule`
   (пересборка — командой `--test`).
4. Создаёт сервис: через **systemd**, если он используется, иначе через
   `/etc/init.d/byedpi`. Демон запускается через launcher `byedpi-start`,
   который собирает опции ciadpi из отдельных файлов при каждом старте.
5. Включает автозапуск и выводит статус.

Демон слушает на `127.0.0.1:<порт>` (по умолчанию `14228`).

> **Права root:** скрипт сам определяет способ повышения прав — от root
> напрямую, иначе через `sudo`, иначе через `su -s /bin/sh -c '...' root`
> (например, ALT Linux, где sudo обычно нет).

---

## Содержимое репозитория

| Файл | Назначение |
|---|---|
| `install_byedpi_generic.sh` | Сам универсальный установщик. Скачивается и запускается одной командой (см. ниже) |
| `Стратегии byedpi.txt` | Готовые стратегии desync с пояснением синтаксиса `--auto`. Можно копировать строки в файл `/etc/byedpi/rule` вручную |
| `ZeroOmegaOptions-2025-08-07T17_33_48.644Z.bak` | Готовый бэкап настроек прокси-расширения SwitchyOmega (ZeroOmega): домены YouTube, rutracker, instagram, discord и др. Импортируется через «Восстановить из файла» |
| `LICENSE` | Лицензия GPL-3.0 |

---

## Установка

### Требования

- Любой дистрибутив Linux с доступом в интернет.
- Права на повышение до root: `sudo` или пароль root для `su`.
- Для работы скрипта нужны `curl` и `tar` (обычно уже установлены).
- Для автотеста стратегий — `curl` и работающий DNS.

### Автоматическая установка

По умолчанию (без флагов) скрипт ставит ByeDPI в **SOCKS-режиме** для
расширения браузера:

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi/main/install_byedpi_generic.sh -o /tmp/byedpi.sh && sh /tmp/byedpi.sh
```

### Установка с флагами

**Вариант 1. Без расширений (весь TCP 80/443 через ByeDPI, фильтр по SNI):**

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi/main/install_byedpi_generic.sh -o /tmp/byedpi.sh && sh /tmp/byedpi.sh --ipset
```

**Вариант 2. SOCKS-прокси для расширения браузера (явно):**

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi/main/install_byedpi_generic.sh -o /tmp/byedpi.sh && sh /tmp/byedpi.sh --extension
```

> **Какой вариант выбрать?**
> - `--ipset` — всё работает само, расширения в браузере не нужны (но нужен
>   root и правится файл `hosts`).
> - `--extension` — нужна настройка расширения в браузере, зато root не нужен.
>
> Подробнее — в разделе «Как использовать: ipset или extension».

---

## Управление

### Статус

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi/main/install_byedpi_generic.sh -o /tmp/byedpi.sh && sh /tmp/byedpi.sh --status
```

### Полное удаление (отключение)

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi/main/install_byedpi_generic.sh -o /tmp/byedpi.sh && sh /tmp/byedpi.sh --off
```

`--off` останавливает и удаляет сервисы (`byedpi.service` или
`/etc/init.d/byedpi`), правила iptables, конфиг `/etc/byedpi` и бинарник
`/usr/local/bin/ciadpi`.

### Сервис вручную

Запуск:

```bash
sudo systemctl start byedpi
```

Перезапуск после смены настроек:

```bash
sudo systemctl restart byedpi
```

Статус:

```bash
sudo systemctl status byedpi
```

Остановка:

```bash
sudo systemctl stop byedpi
```

Если systemd не используется — те же действия через init-скрипт:

```bash
/etc/init.d/byedpi restart
```

---

## Как использовать: ipset или extension

| | `--ipset` | `--extension` |
|---|---|---|
| Расширения браузера | не нужны | нужны (FoxyProxy / SmartProxy / SwitchyOmega 3) |
| Охват | домены из hostlist (фильтр по SNI) | только то, что настроено в расширении |
| Root | нужен (правила в ядре) | не нужен |
| UDP/QUIC | не обрабатывается | не обрабатывается |

### ipset — работа без расширений

Правило `iptables -t nat` `REDIRECT` (порты 80/443, TCP) заворачивает **весь**
исходящий трафик в локальный порт ByeDPI. Дальше ByeDPI смотрит на SNI (домен)
в TLS-запросе и десинхронизирует только те соединения, чей домен есть в
hostlist — как это делает расширение в SOCKS-режиме. Это надёжно работает и для
CDN-доменов (googlevideo), у которых тысячи IP: фильтр идёт по домену, а не по
IP, поэтому ipset и таймер обновления не нужны. Остальной трафик идёт напрямую.

Отредактировать список доменов:

```bash
sudo nano /etc/byedpi/hosts
```

Перезапустить демон:

```bash
sudo systemctl restart byedpi
```

### extension — SOCKS-прокси

ByeDPI поднимает SOCKS на `127.0.0.1:<порт>`. Настройте прокси-расширение на
этот адрес и импортируйте список доменов. Готовый бэкап настроек SwitchyOmega
(`ZeroOmegaOptions-*.bak`) лежит в репозитории — импортируется через
«Восстановить из файла» в настройках расширения.

---

## Как изменить настройки

Порт, правило desync и список доменов лежат в **отдельных файлах** — менять их
можно по одному, не трогая остальные:

| Что настраиваем | Файл |
|---|---|
| список доменов | `/etc/byedpi/hosts` |
| стратегия desync | `/etc/byedpi/rule` |
| порт | `/etc/byedpi/port` |
| управляющий конфиг | `/etc/byedpi/conf` |

`conf` — управляющий файл с **переменными-указателями** на `rule`/`port`/`hosts`.
Демон запускается через launcher `byedpi-start`, который при каждом старте
читает эти файлы и собирает опции ciadpi — правки вступают в силу перезапуском
сервиса без переустановки.

### Изменить список доменов (ipset-режим)

Редактируем файл:

```bash
sudo nano /etc/byedpi/hosts
```

Перезапускаем демон:

```bash
sudo systemctl restart byedpi
```

### Сменить порт

Вписать число, например `14229`:

```bash
sudo nano /etc/byedpi/port
```

Перезапустить демон:

```bash
sudo systemctl restart byedpi
```

В ipset-режиме перезапустите также правила перенаправления:

```bash
sudo systemctl restart byedpi-redirect
```

### Смена стратегии desync (автоподбор)

Правило лежит в файле `rule` одной строкой. Готовые варианты — в файле
`Стратегии byedpi.txt` репозитория.

Редактируем правило:

```bash
sudo nano /etc/byedpi/rule
```

Перезапускаем демон:

```bash
sudo systemctl restart byedpi
```

**Автоподбор:** при первой установке (и по команде `--test`) скрипт прогоняет
список доменов через нескольких кандидатов правил и записывает в `rule` то,
которое открывает больше всего ресурсов из списка:

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi/main/install_byedpi_generic.sh -o /tmp/byedpi.sh && sh /tmp/byedpi.sh --test
```

Пропустить автоподбор при установке можно флагом `--no-test`.

Коротко про синтаксис правил:

- `-s0 -o1` — отключение шифрования и отправка первой части (4 байта) сразу;
- `-Ar ... -At` — группы повторения при сбросе/таймауте;
- `-f-1 --md5sig` — отправка заведомо лишней части с MD5-подписью;
- `-r1+s` — повтор первой части с задержкой;
- `-As,n` — группа повторения с беспорядочной отправкой;
- `-Ku -a5` — отключение UDP и задержка повторов 5 мс;
- `-An` — отсутствие активной группы по умолчанию.

---

## Рекомендации по настройке браузера

Для extension-режима используются расширения-переключатели прокси:

- FoxyProxy
- SmartProxy
- Proxy SwitchyOmega 3

Готовый бэкап настроек SwitchyOmega лежит в репозитории. Набор доменов покрывает
страницы, плеер и превью YouTube: `*.youtube.com`, `*.googlevideo.com` (видео),
`*.ytimg.com` / `i.ytimg.com` (превью и картинки), `yt3.ggpht.com` /
`*.ggpht.com` / `yt3.googleusercontent.com` (аватары), а также rutracker,
instagram, discord и др.

---

## Ограничения transparent-режима

Transparent-режим (ipset) перенаправляет только TCP. UDP (например, QUIC от
YouTube) не обрабатывается — при необходимости отключите QUIC в браузере
(`chrome://flags/#enable-quic` → Disabled), чтобы видео шло по TCP 443.

---

## Безопасность

- Определяет права автоматически: от root напрямую, иначе через `sudo`, иначе
  через `su -s /bin/sh -c '...' root`.
- В ipset-режиме отсекает служебные подсети (локальные адреса) от
  перенаправления, чтобы не заворачивать собственный трафик.

---

## Полный список флагов

```
Использование: install_byedpi_generic.sh [--ipset|--extension] [--off|--status|--test] [--port N] [--no-test]
  --ipset         метод ipset: весь TCP 80/443 через ByeDPI, фильтр по SNI
  --extension     метод extension: SOCKS-прокси для браузерного расширения
  --test          перезапустить автотест стратегий и обновить /etc/byedpi/rule
  --no-test       пропустить автотест стратегий при установке
  --off | --remove  отключить и удалить всё
  --status|--info   показать текущее состояние
  --port N        изменить порт
```

---

## Поддерживаемые архитектуры

Бинарник `ciadpi` скачивается с GitHub под конкретную архитектуру:

- `x86_64` (Intel/AMD 64-бит)
- `aarch64` / `arm64` (ARM 64-бит, Raspberry Pi 4+)
- `armv7l` / `armhf` (ARM 32-бит)
- `armv6`
- `i686` / `x86`
- `mips` / `mipsel`
- `powerpc` / `ppc`

## Лицензия

Проект распространяется под лицензией GPL-3.0 — см. файл `LICENSE`.