# routeros/

Скрипты и конфиги для MikroTik RouterOS.

Подробная документация по каждому скрипту (установка, проверка, типовые ошибки) —
в [`docs/`](docs/): по одному `.md`-файлу на скрипт, имя совпадает с именем скрипта.

## Способы установки

В RouterOS нет «скачать и выполнить одной строкой»: `import` работает только с
файлом, который уже лежит на роутере. Поэтому все скрипты ставятся одним из трёх
способов.

| Способ | Когда применяется | Команды |
|---|---|---|
| **A. Разовый импорт** | Конфиг применяется один раз (firewall-правила, scheduler, первичная настройка). | `/tool fetch url="<raw-URL>"` → `/import file-name=<файл>` |
| **B. Named script + scheduler** | Скрипт должен выполняться регулярно (IP-апдейтеры, бэкап). | `/system script add name=<имя> policy=read,write,test source=[/file get <файл> contents]` → `/system scheduler add ... on-event="/system script run <имя>"` |
| **C. Импорт прямо из планировщика** | Логика живёт в `.rsc`-файле и перечитывается на каждом запуске. | `/system scheduler add ... on-event="/import file-name=<файл>"` |

Базовый URL для `fetch`:
`https://raw.githubusercontent.com/gpas45/scripts/main/routeros/<файл>`

> [!NOTE]
> На свежем роутере часы не выставлены, поэтому проверка TLS-сертификата
> GitHub не проходит — добавляйте к `fetch` флаг `check-certificate=no`,
> пока NTP не отработал.

> [!IMPORTANT]
> **На новых устройствах сначала device-mode.** На моделях последних выпусков
> (RouterOS 7.17+) с завода включён ограничивающий `device-mode`; в режиме
> `home` запрещены `fetch` и `scheduler`, то есть не работает ни установка
> через `/tool fetch`, ни любой запуск по расписанию. Симптом —
> `not allowed by device-mode`.
>
> ```rsc
> /system device-mode print
> /system device-mode update mode=advanced
> ```
>
> Изменение нужно подтвердить физически в течение ~5 минут: кнопка
> **reset**/**mode** на устройстве либо снятие питания. Обычный
> `/system reboot` запрос отменяет. Подробно — в [`INSTALL.md`](INSTALL.md).

Загрузить файл можно и без `fetch`: Winbox/WebFig → **Files** → перетащить
`.rsc` (или по SFTP/scp).

## Первичная настройка роутера

| Файл | Назначение | Установка |
|---|---|---|
| `autorun.rsc` | Минимальный bootstrap: адресация на `ether1` + шлюз, DHCP-клиент (выключен), списки интерфейсов WAN/LAN/StS/VPN, `masquerade`, пароль admin, отключение небезопасных сервисов (telnet, ftp, www, api, api-ssl), MAC-сервера и IPv6, часовой пояс и NTP. Перед импортом замените заглушки `CHANGE_ME` и **пустое** `address=`. | **A.** Сначала правка заглушек (WebFig → Files → Edit), затем `/import file-name=autorun.rsc`. Подробно — [`docs/autorun.md`](docs/autorun.md). |
| `initial-setup-ros7.rsc` | Расширенный шаблон для **RouterOS 7**: bridge, interface-lists (WAN/LAN/StS/VPN), полный firewall (port knocking 1234→2345→3456 на порт 12345, anti-bruteforce, ICMP-цепочка, заготовки правил GRE/IPsec/L2TP), NAT, DNS-резолвер, харднинг сервисов, OSPF-фильтры, автообновление прошивки RouterBOARD. | **A**, на чистую железку (`/system reset-configuration no-defaults=yes`). Полная инструкция — [`INSTALL.md`](INSTALL.md), разбор — [`docs/initial-setup.md`](docs/initial-setup.md). |
| `initial-setup-ros6.rsc` | То же для **RouterOS 6** (6.41+): NTP через `server-dns-names`, отключение IPv6 через `/system package disable`, OSPF-фильтры в синтаксисе `/routing filter`, топик логирования `wireless`. | **A**, см. [`INSTALL.md`](INSTALL.md). После импорта нужна перезагрузка — отключение пакетов применяется только после неё. |
| `INSTALL.md` | Инструкция по установке `initial-setup-*.rsc`: быстрый `fetch`+`import`, ручная загрузка, сброс на чистую железку, шаги после импорта, перевод firewall из `passthrough` в `drop`. | — |

## Firewall и address-lists

| Файл | Назначение | Установка |
|---|---|---|
| `rdp-bruteforce.rsc` | Защита от перебора RDP (TCP/3389): ступенчатое (`rdp_stage1`…`rdp_stage5`) добавление источников в `black-list attackers` с баном на 4w2d и правилом `drop` в filter. Списки `RDP` (доверенные клиенты) и `management` заполняются вручную; `192.168.0.0/16` не банится. | **A** (правила создаются один раз): `/import file-name=rdp-bruteforce.rsc`. Затем перенести правило `drop` в начало цепочки `forward` и наполнить списки `RDP`/`management`. Подробно — [`docs/rdp-bruteforce.md`](docs/rdp-bruteforce.md). |
| `cloudflare-ip-updater.rsc` | Обновление address-list `CF` актуальными IPv4-подсетями Cloudflare. Требует RouterOS 6.43+ (`fetch ... as-value`). | **B**, расписание `interval=7d start-time=03:31:00`. Разово — **A**. Подробно — [`docs/cloudflare-ip-updater.md`](docs/cloudflare-ip-updater.md). |
| `telegram-ip-updater.rsc` | Обновление address-list `TG` актуальными IPv4-подсетями Telegram (`core.telegram.org/resources/cidr.txt`). RouterOS 6.43+. | **B**, расписание `interval=1d start-time=03:30:00`. Подробно — [`docs/telegram-ip-updater.md`](docs/telegram-ip-updater.md). |
| `google-ip-updater.rsc` | Обновление address-list `VPN_ytb` диапазонами Google из `goog.json` — для policy-routing на Google/YouTube. Чистит только свои записи (по `comment=google-auto`). RouterOS 6.43+. | **B**, расписание `interval=7d start-time=03:41:00`. Подробно — [`docs/google-ip-updater.md`](docs/google-ip-updater.md). |

## Маршрутизация и каналы

| Файл | Назначение | Установка |
|---|---|---|
| `check-isp.rsc` | Dual-WAN: проверка двух провайдеров пингом через каждый аплинк и сброс conntrack-записей упавшего канала (`connection-mark` `con-isp1`/`con-isp2`). Маршруты и mangle-метки настраиваются отдельно. | **C**: `/system scheduler add name=check-isp interval=30s policy=read,write,test on-event="/import file-name=check-isp.rsc"`. Подробно — [`docs/check-isp.md`](docs/check-isp.md). |
| `ospf_filter_rules.rsc` | Фильтры OSPF (RouterOS 7): принимать и анонсировать только частные подсети RFC 1918, остальное — `reject`. | **A**: `/import file-name=ospf_filter_rules.rsc`, затем привязать цепочки: `/routing ospf instance set [find name="default"] in-filter-chain=ospf-in out-filter-chain=ospf-out`. Подробно — [`docs/ospf-filter-rules.md`](docs/ospf-filter-rules.md). |

## DNS

| Файл | Назначение | Установка |
|---|---|---|
| `ru-gov-dns-forward.rsc` | Условная пересылка DNS российских госсайтов (Госуслуги, ФНС, ЭТП, VK/MAX) на резолвер внутри РФ через `/ip dns forwarders` + статические записи `type=FWD` c `match-subdomain=yes`; опционально наполняет address-list `RU-GOV`. Требует **RouterOS 7.17+**. Идемпотентен — свои записи помечает комментарием `ru-gov-dns` и пересоздаёт. | **A**: `/import file-name=ru-gov-dns-forward.rsc`. Повторный запуск безопасен. Разбор проблемы и настройка клиентов — [`docs/DNS-форвардинг госсайтов на MikroTik.md`](docs/DNS-форвардинг%20госсайтов%20на%20MikroTik.md). |
| `ru-gov-dns-forward-legacy.rsc` | То же для RouterOS 7.x **ниже 7.17**, где нет `/ip dns forwarders`: `forward-to` принимает один IP, резервного сервера нет. | **A**: `/import file-name=ru-gov-dns-forward-legacy.rsc`. |

## Обслуживание

| Файл | Назначение | Установка |
|---|---|---|
| `BackupAndUpdate.rsc` | Автоматический бэкап MikroTik (система + конфиг) с отправкой на e-mail, уведомления о новых версиях RouterOS и автообновление RouterOS/прошивки RouterBOARD. Версия 26.02.22, минимум RouterOS 6.43.7. | **B**, но имя скрипта обязательно `BackupAndUpdate`. Перед установкой заполнить секцию `MODIFY THIS SECTION AS NEEDED` (минимум `emailAddress`, `scriptMode`) и настроить **Tools → Email**. Пошагово — [`docs/backupandupdate.md`](docs/backupandupdate.md). |
| `routerboard_fwupgrade.rsc` | Задание планировщика: сверяет `current-firmware` с `upgrade-firmware` при каждой загрузке и, если есть новее, обновляет прошивку RouterBOARD с перезагрузкой. | **A** (создаёт scheduler): `/import file-name=routerboard_fwupgrade.rsc`. Подробно — [`docs/routerboard-fwupgrade.md`](docs/routerboard-fwupgrade.md). |
| `routerboard_starwars.rsc` | Имперский марш на системном динамике через 15 секунд после загрузки. | **A** (создаёт scheduler): `/import file-name=routerboard_starwars.rsc`. Подробно — [`docs/routerboard-starwars.md`](docs/routerboard-starwars.md). |

## docs/

| Файл | Содержимое |
|---|---|
| `<имя скрипта>.md` | Документация по каждому скрипту: назначение, требования, установка, проверка результата, типовые ошибки. Оформление под Obsidian (callouts, wiki-ссылки), но читается и на GitHub. |
| `DNS-форвардинг госсайтов на MikroTik.md` | Разбор, почему госсайты не резолвятся через зарубежные DNS (делегированная GSLB-зона, CDN NGENIX), и настройка условного форвардинга. |
| `check-list-router.md` | Чек-лист настройки роутера MikroTik (RouterOS 7) с контрольными точками. |
| `check-list-router-print.py` | Генератор PDF-версии чек-листа (`fpdf2`, шрифты DejaVu) → `check-list-router-print.pdf`. |
| `mikrotik_check-list_router.pdf` | Исходный PDF чек-листа (автор — Скоромнов Д. А.). |
| `mikrotik_product_matrix_26012101.xlsx` | Продуктовая матрица MikroTik. |
| `howto/` | Скриншоты-инструкции для `BackupAndUpdate` (имя скрипта, настройки e-mail, задача планировщика). |
