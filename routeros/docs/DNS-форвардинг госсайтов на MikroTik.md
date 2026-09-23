---
type: инструкция
направление: Сети/СКС
тема: DNS
оборудование: MikroTik RouterOS 7.17+
дата: 2026-09-21
статус: рабочая
проверено: 2026-09-21
теги:
  - сеть/dns
  - mikrotik
  - routeros
  - госуслуги
  - фнс
repo: https://github.com/USERNAME/mikrotik-ru-gov-dns
---

# DNS-форвардинг госсайтов на MikroTik

> [!abstract] Суть
> Часть российских госсайтов не резолвится корректно через зарубежные публичные DNS (`8.8.8.8`, `1.1.1.1`). Лечится условной пересылкой (conditional forwarding) нужных зон на российский резолвер средствами RouterOS.

## Проблема

Симптом у клиента: Госуслуги не открываются, при этом остальной интернет работает. В настройках сети прописан `8.8.8.8` или `1.1.1.1`.

Первичная диагностика даёт противоречивую картину:

- корневые серверы «не знают» о записи;
- Cloudflare отвечает, что не знает;
- Google знает;
- Яндекс знает, но отдаёт совсем другие адреса.

## Диагностика

### Корневые серверы — ложный след

Корневые держат только делегирование зоны `.ru` и отвечают **реферралом**, а не адресом. Ответа по конкретному имени от них не бывает никогда — это штатное поведение, а не признак проблемы.

Правильная цепочка: корень → `a.dns.ripn.net` (серверы .RU) → NS домена.

### Структура зоны gosuslugi.ru

| Запрос | Ответ |
|---|---|
| `gosuslugi.ru` NS | `ns1.gosuslugi.ru`, `ns2.gosuslugi.ru`, `ns4-l2.nic.ru`, `ns8-l2.nic.ru` |
| `gosuslugi.ru` A | `213.59.253.7`, `213.59.254.7` (TTL 600) |
| `gosuslugi.ru` SOA | `ns1.gosuslugi.ru support-egov.rtlabs.ru 2026091801` |
| `ns1.gosuslugi.ru` | `213.59.253.4` |
| **`www.gosuslugi.ru`** | **CNAME → `www.gslb.gosuslugi.ru`** |
| `gslb.gosuslugi.ru` NS | `213.59.253.3`, `213.59.254.3` (PJSC Rostelecom, RU) |

### Ключевая находка

Прямой запрос поддомена через зарубежный резолвер:

```
www.gslb.gosuslugi.ru  →  Status: 2 (SERVFAIL)
  "Name servers did not respond [213.59.253.3, 213.59.254.3]"
  EDE 22: At delegation gslb.gosuslugi.ru

esia.gosuslugi.ru      →  Status: 2 (SERVFAIL)
  EDE 23: No response received from name servers for gslb.gosuslugi.ru
```

`gslb.gosuslugi.ru` — **отдельно делегированная зона**, которую обслуживает GSLB-балансировщик Ростелекома (Global Server Load Balancing). Он выдаёт адрес в зависимости от сети и региона источника запроса и **не отвечает на запросы из-за пределов РФ** — молчит, а не возвращает NXDOMAIN.

> [!important] NXDOMAIN ≠ SERVFAIL
> Разница принципиальная при диагностике.
> `NXDOMAIN` — имени не существует.
> `SERVFAIL` — резолвер не смог дойти до авторитетного сервера, цепочка оборвалась.
> В выводе `dig` смотреть строку `status:`.

## Почему резолверы расходятся

| Наблюдение | Причина |
|---|---|
| Корневые «не знают» | Штатный реферрал, они не рекурсивные |
| Cloudflare «не знает» | SERVFAIL: анкаст выводит на узлы вне РФ, до GSLB не достучаться |
| Google знает | Апекс `gosuslugi.ru` отдают обычные NS. `www` работает нестабильно — из кэша узла, который когда-то дотянулся |
| Яндекс знает, адреса другие | Резолверы внутри РФ, GSLB отвечает и отдаёт региональную привязку. **Это штатная работа балансировщика, не подмена** |

Вывод: сравнивать ответы по `gosuslugi.ru` между зарубежными и российскими резолверами бессмысленно — зарубежные физически не видят GSLB-зону.

## Какие домены реально затронуты

Проверено по состоянию на дату заметки:

| Домен | Что отдаёт | Нужен форвардинг |
|---|---|---|
| `gosuslugi.ru` | делегированная GSLB-зона, NS молчат извне РФ | **критично** |
| `www.nalog.gov.ru` | CNAME → `s19269.cdn.ngenix.net`, TTL 30 | **да** — CDN NGENIX выбирает edge по адресу резолвера |
| `npd.nalog.ru` | CNAME → `s78717.cdn.ngenix.net` | **да** |
| `lkfl2.nalog.ru` | CNAME → `lkfl21.gi.nalog.ru` → `213.24.64.175` | нет, статика |
| `zakupki.gov.ru` | A `95.167.245.92`, TTL 600 | нет, один адрес для всех |
| `www.roseltorg.ru` | A `185.79.118.12` | нет |
| `www.sberbank-ast.ru` | A `193.104.207.65` | нет |
| `www.rts-tender.ru` | A `185.179.85.62`, TTL 5 | нет |

SERVFAIL, как у `gslb.gosuslugi.ru`, больше нигде нет. Реальную пользу форвардинг даёт там, где сверху CDN или GSLB: Госуслуги и сайты ФНС. Для ЕИС и ЭТП правила безвредны, но проблему не решают — если там что-то не открывается, причина не в DNS.

## Решение

### Требования

RouterOS **7.17+** — в этой версии появился `/ip dns forwarders`. Проверить:

```
/system resource print
```

### Конфигурация

```routeros
/ip dns forwarders
add name=yandex dns-servers=77.88.8.8,77.88.8.1

/ip dns static
add name=gosuslugi.ru              type=FWD forward-to=yandex match-subdomain=yes comment="Госуслуги"
add name=xn--c1aapkosapc.xn--p1ai  type=FWD forward-to=yandex match-subdomain=yes comment="госуслуги.рф"
add name=nalog.gov.ru              type=FWD forward-to=yandex match-subdomain=yes comment="ФНС"
add name=nalog.ru                  type=FWD forward-to=yandex match-subdomain=yes comment="ФНС, старый домен и ЛК"
add name=cdn.ngenix.net            type=FWD forward-to=yandex match-subdomain=yes comment="CDN ФНС"
add name=zakupki.gov.ru            type=FWD forward-to=yandex match-subdomain=yes comment="ЕИС"
add name=roseltorg.ru              type=FWD forward-to=yandex match-subdomain=yes
add name=sberbank-ast.ru           type=FWD forward-to=yandex match-subdomain=yes
add name=rts-tender.ru             type=FWD forward-to=yandex match-subdomain=yes
add name=tektorg.ru                type=FWD forward-to=yandex match-subdomain=yes
add name=zakazrf.ru                type=FWD forward-to=yandex match-subdomain=yes
add name=etp-ets.ru                type=FWD forward-to=yandex match-subdomain=yes
```

`match-subdomain=yes` — принципиально. Именно он накрывает `www.gosuslugi.ru`, `esia.gosuslugi.ru` и всю делегированную зону `gslb.gosuslugi.ru`, ради которой всё затевается. Остальной трафик продолжает ходить через `/ip dns servers`.

### Для RouterOS ниже 7.17

`forwarders` нет, но `type=FWD` есть — адрес указывается напрямую. Резервного сервера в этом варианте не будет, `forward-to` принимает один адрес:

```routeros
/ip dns static
add name=gosuslugi.ru type=FWD forward-to=77.88.8.8 match-subdomain=yes
```

### Чтобы клиенты шли через роутер

```routeros
/ip dns
set allow-remote-requests=yes

/ip dhcp-server network
set [find] dns-server=192.168.88.1
```

Перехват устройств с прописанным вручную `8.8.8.8`:

```routeros
/ip firewall nat
add chain=dstnat action=redirect to-ports=53 protocol=udp dst-port=53 \
    in-interface-list=LAN comment="перехват DNS"
add chain=dstnat action=redirect to-ports=53 protocol=tcp dst-port=53 \
    in-interface-list=LAN
```

## Нюанс с CDN

Правило на `nalog.gov.ru` заворачивает к Яндексу только запросы имён **внутри этой зоны**, а цель CNAME лежит в чужом домене `cdn.ngenix.net`.

В обычном сценарии это не страшно — Яндекс рекурсит всю цепочку и возвращает CNAME вместе с A-записями одним ответом. Но если клиент спросит `s19269.cdn.ngenix.net` отдельно, запрос уйдёт через дефолтные серверы и edge выберется не тот. Отдельное правило на CDN-домен закрывает этот случай.

## Побочный эффект: address-list

У `/ip dns static` есть параметр `address-list` — резолвер сам складывает полученные адреса в firewall address-list:

```routeros
/ip dns static
set [find name=nalog.gov.ru]    address-list=RU-GOV
set [find name=cdn.ngenix.net]  address-list=RU-GOV
set [find name=gosuslugi.ru]    address-list=RU-GOV
```

Дальше список используется в mangle для policy-routing — загнать госсайты в конкретный аплинк, если у клиента их два. Для CDN с TTL 30 это единственный вменяемый способ собрать актуальный набор адресов, руками там ловить нечего.

## Чего форвардинг не лечит

> [!warning] DoH в браузерах
> Chrome, Firefox и Яндекс.Браузер с включённым DNS-over-HTTPS ходят по HTTPS на `dns.google` / `cloudflare-dns.com` и правила на роутере игнорируют. Характерный симптом: `nslookup` из консоли отрабатывает, а в браузере сайт не открывается.
> Лечится отключением DoH политикой либо блокировкой известных DoH-эндпоинтов на файрволе.

Также не решается форвардингом:

- ГОСТ-TLS и КриптоПро на ЭТП;
- блокировки по IP на стороне площадки;
- проблемы ЕИС `zakupki.gov.ru` — там один статический адрес для всех.

## Проверка

На роутере:

```routeros
/ip dns cache flush
/ip dns static print where type=FWD
/ip dns cache print where name~"gosuslugi|nalog|ngenix"
/ip firewall address-list print where list=RU-GOV
```

С клиента:

```bash
nslookup www.gosuslugi.ru 192.168.88.1
nslookup esia.gosuslugi.ru 192.168.88.1
nslookup www.nalog.gov.ru 192.168.88.1
```

Ожидаем адреса в `213.59.x.x` для Госуслуг, а не SERVFAIL.

Сравнение резолверов вручную:

```bash
dig www.gosuslugi.ru @1.1.1.1          # смотреть status: SERVFAIL vs NXDOMAIN
dig +cd www.gosuslugi.ru @1.1.1.1      # исключить DNSSEC как причину
dig www.gosuslugi.ru @77.88.8.8
nslookup www.gosuslugi.ru 213.59.253.3 # напрямую к GSLB, изнутри РФ
```

## Скрипты

Готовые скрипты вынесены в репозиторий (см. свойство `repo` в заголовке заметки):

- `mikrotik/ru-gov-dns-forward.rsc` — идемпотентная установка, RouterOS 7.17+
- `mikrotik/ru-gov-dns-forward-legacy.rsc` — вариант без `forwarders`
- `mikrotik/ru-gov-dns-remove.rsc` — полный откат
- `scripts/dns-check.sh` — сравнение ответов по списку доменов через несколько резолверов
- `domains.txt` — список зон, общий для скриптов

## Ссылки

- [[MikroTik — базовая настройка]]
- [[Диагностика DNS]]
- [MikroTik Docs — DNS](https://help.mikrotik.com/docs/spaces/ROS/pages/37748767/DNS)
- [Яндекс DNS](https://dns.yandex.ru/)
