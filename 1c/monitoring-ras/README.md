# Мониторинг кластера 1С 8.3 в Zabbix через RAS/RAC

Порт сборщика из статьи Infostart
[«Мониторинг кластера 1С 8.3 в Zabbix»](https://infostart.ru/1c/articles/1632627/)
с источника **COM+ (`V83.COMConnector`)** на штатный сервер администрирования
**RAS** (`ras.exe`) и консольный клиент **RAC** (`rac.exe`).

> Это не альтернатива статье, а её же дорожная карта: в разделе «Планы по
> развитию» автор прямо пишет, что планирует перевод мониторинга **с COM+ на
> RAS/RAC**. Здесь этот переход и реализован.

## Что делает статья

Скрипт на PowerShell подключается к агенту кластера через `V83.COMConnector` и
собирает данные в **один JSON-файл** `1c_server_data.json`, который затем парсит
сервер Zabbix (мастер-данные + 3 правила LLD + триггеры + дашборды/Grafana).
Структура JSON — четыре блока:

1. **cluster** — параметры сервера и кластера + сводка по сеансам;
2. **workingservers** — рабочие серверы кластера и их загрузка;
3. **processes** — рабочие процессы `rphost` и их параметры;
4. **bases.list** — информационные базы кластера и их параметры.

Коллектор в этой папке отдаёт **тот же JSON той же структуры**, но данные берёт
из RAC.

## Почему RAS/RAC лучше COM+

| | COM+ (`V83.COMConnector`) | RAS/RAC |
|---|---|---|
| Разрядность | COM-объект должен совпадать по битности с процессом PowerShell | не важно, сетевой протокол |
| Где запускать | обычно на самом сервере 1С | с любого хоста с `rac.exe` и доступом к 1545 |
| Регистрация компоненты | нужна регистрация `comcntr.dll` | не нужна |
| PID процессов | статья вынужденно чинит реестр `ProcessNameFormat` и матчит perfmon-счётчики `rphost_<PID>` | RAC отдаёт `pid` напрямую — хак больше не нужен |
| Параметры ИБ | статья парсит файл реестра кластера `1CV8Clst.lst` регуляркой | `rac infobase info` (при наличии прав на ИБ) |

## Соответствие: свойство COM-объекта → поле/команда RAC

### Блок 1 — cluster

`rac cluster info --cluster=<id>` (плюс сводка по `session list` / `license list`):

| Статья (COM) | RAC |
|---|---|
| `MaxMemorySize` | `max-memory-size` |
| `KillByMemoryWithDump` | `kill-by-memory-with-dump` |
| `LoadBalancingMode` | `load-balancing-mode` |
| `SessionFaultToleranceLevel` | `session-fault-tolerance-level` |
| `ExpirationTimeout` | `expiration-timeout` |
| `LifeTimeLimit` | `lifetime-limit` |
| `SecurityLevel` | `security-level` |
| `MainPort` | `main-port` |
| `KillProblemProcesses` | `kill-problem-processes` |
| `sessions_count` | число записей `session list` |
| `users_count` | число выданных клиентских лицензий (`license list` с полем `session`) |
| `clients_count` / `ws_count` / `http_count` / `jobs_count` / `com_count` / `web_count` | группировка `session list` по `app-id` (`1CV8`/`1CV8C`, `WSConnection`, `HTTPServiceConnection`, `BackgroundJob`, `COMConnection`, `WebServerExtension`) |
| `prolicense_count` / `prolicense_users` | `license list`, фильтр по `short-presentation` (КОРП/базовые исключаются, см. `-CorpLicensePattern`) |

### Блок 2 — workingservers

`rac server list --cluster=<id>`: `server`, `name`, `agent-host`, `agent-port`,
`connections-limit`, `infobases-limit`, `memory-limit`.
Загрузка CPU по ядрам (`counter_processor_total/12` в статье) — **в RAC
отсутствует**, остаётся на стороне ОС (см. ниже).

### Блок 3 — processes

`rac process list --cluster=<id>` + группировка `session list` по `process`:

| Статья | RAC |
|---|---|
| `PID` / `MainPort` / `HostName` / `StartedAt` | `pid` / `port` / `host` / `started-at` |
| `MemorySize` / `connections` / `Running` / `Use` / `IsEnable` | одноимённые поля |
| `available-perfomance`, `avg-call-time` | одноимённые поля |
| `users` / `sessions` | подсчёт по сгруппированным сессиям процесса |
| `session_mem` / `session_CPU` / `session_proc_took` | top-сессия процесса по `memory-current` / `cpu-time-current` / `db-proc-took` |
| `CPU_Usage` (perfmon `rphost_<PID>`) | **нет в RAC** — остаётся на ОС |

### Блок 4 — bases

`rac infobase summary list --cluster=<id>` + группировка сессий по `infobase`:

| Статья | RAC |
|---|---|
| `BaseName` / `Description` | `name` / `descr` |
| `sessions` / `users` | подсчёт по сессиям ИБ |
| `reglaments` | сессии с `user-name ~ ^reg\d{3}`, сгруппированные |
| `Blocked` / `StartBlocking` / `EndBlocking` / `DBServerName` / `DBBaseName` | `rac infobase info --cluster=<id> --infobase=<ib> --infobase-user=.. --infobase-pwd=..` → `sessions-deny` / `denied-from` / `denied-to` / `db-server` / `db-name` (требует прав на ИБ; здесь не включено, т.к. нужен пароль каждой базы) |

## Что принципиально остаётся на стороне ОС/агента

Этого нет в API администрирования кластера — собирайте штатными средствами
Zabbix-агента (как в статье), RAS их не заменяет:

| Метрика статьи | Ключ Zabbix |
|---|---|
| Статус службы агента 1С | `service_state["{$CLUSTER1C.SERVICE.NAME}"]` |
| Запущен технологический журнал (`logcfg.xml`) | `vfs.dir.count["...1cv8",".*logcfg.xml$",,file]` |
| Загрузка CPU по ядрам / общая | perfmon-счётчики `\238(N)\6` |
| CPU% на процесс `rphost` | perfmon `\230(rphost_<PID>)\6` (при переходе на RAS уже не обязателен) |
| Число ядер сервера | WMI `Win32_ComputerSystem` |

## Файлы

Две отдельные реализации коллектора под каждую ОС; **обе выдают идентичный JSON**,
поэтому Zabbix-шаблон и ключи (`onecras.*`) для них общие.

| Файл | Назначение |
|---|---|
| `1c_cluster_ras.ps1` | Коллектор для **Windows** (Windows PowerShell 5.1+). |
| `1c_cluster_ras.sh` | Коллектор для **Linux** (bash + awk, **без PowerShell**). |
| `userparameter_1c_ras.conf` | UserParameter'ы Zabbix-агента для Windows (`powershell`). |
| `userparameter_1c_ras_linux.conf` | UserParameter'ы для Linux (вызывают `.sh`). |
| `template_1c_cluster_ras.yaml` | Импортируемый шаблон Zabbix 6.0: мастер-айтем, зависимые элементы, 3 LLD, триггеры. |

Оба коллектора принимают одинаковые режимы (`json`, `discovery.ib`,
`discovery.process`, `discovery.server`) и сами находят `rac`/`rac.exe` (PATH и
типовые каталоги установки); путь переопределяется — на Windows параметром
`-RacPath`, на Linux переменной `RAC_PATH`.

### Зависимости Linux-версии

Сознательно минимальные — PowerShell на серверах 1С из коробки нет:

* `rac` — из состава платформы 1С (`/opt/1cv8/.../rac`);
* `awk` (`mawk`/`gawk`), `bash`, `find`, `sort`, `head` — есть в любом дистрибутиве.

Никаких `jq`, `python`, `pwsh` — разбор вывода `rac` и сборка JSON целиком на awk.

## Установка

### Windows

1. Убедиться, что RAS запущен как сервис (порт 1545):
   ```
   "C:\Program Files\1cv8\<версия>\bin\ras.exe" cluster --service --port=1545 localhost:1540
   ```
2. Скопировать `1c_cluster_ras.ps1` в `C:\Zabbix\Scripts\`, а
   `userparameter_1c_ras.conf` — в каталог конфигов агента.
3. Поднять `Timeout` агента до ~30 c. Проверить:
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Zabbix\Scripts\1c_cluster_ras.ps1 json
   ```

### Linux

1. Убедиться, что RAS запущен (обычно systemd-юнит `srv1cv8-ras`, порт 1545).
2. Скопировать `1c_cluster_ras.sh` в `/etc/zabbix/scripts/` (`chmod +x`), а
   `userparameter_1c_ras_linux.conf` — в `/etc/zabbix/zabbix_agentd.d/`.
3. Поднять `Timeout` агента до ~30 c. Проверить:
   ```
   /etc/zabbix/scripts/1c_cluster_ras.sh json 1c-srv:1545
   ```

4. Импортировать `template_1c_cluster_ras.yaml` в Zabbix и привязать к хосту
   (задать макросы `{$RAS.SERVER}`, при необходимости `{$RAS.CLUSTER.USER}` /
   `{$RAS.CLUSTER.PWD}`).

## Схема мониторинга в Zabbix (мастер-айтем)

Готовый шаблон `template_1c_cluster_ras.yaml` уже реализует всё описанное ниже —
импортируйте его и привяжите к хосту. Раздел объясняет его устройство.

> Пароль администратора кластера передаётся макросом `{$RAS.CLUSTER.PWD}` — на
> проде задайте его на хосте как **Secret text**, чтобы значение не светилось.

Как и в статье — один опрос отдаёт весь JSON, метрики достаются предобработкой:

1. **Мастер-айтем** `onecras.json` (Zabbix agent, интервал 1–2 мин, тип Text).
2. **Зависимые элементы** с предобработкой *JSONPath*:
   * `$.cluster.sessions_count`, `$.cluster.users_count`,
     `$.cluster.prolicense_count`, `$.cluster.clients_count` и т.д.
3. **LLD инфобаз** `onecras.discovery.ib`, прототип (Dependent):
   `$.bases.list[?(@.BaseName=='{#IBNAME}')].sessions.first()`.
4. **LLD процессов** `onecras.discovery.process`, прототипы по
   `$.processes[?(@.PID=='{#PROCPID}')].MemorySize.first()` и т.п.
5. **LLD серверов** `onecras.discovery.server`.

Триггеры (примеры из статьи): превышение памяти `rphost`, рост числа
регламентных `reg000` в рабочее время, срабатывание КОРП-лицензий (`prolicense`),
недоступность RAS (nodata по мастер-айтему).

## Ограничения

* Версия `rac`/`rac.exe` должна быть совместима с версией сервера 1С.
* Фильтр КОРП/базовых лицензий (Windows — `-CorpLicensePattern`, Linux —
  переменная `CORP_LICENSE_PATTERN`) стоит сверить с фактическим выводом
  `rac license list`. На Linux дефолт без интервалов `{3}` (`ORG8B ... 500`) —
  совместим с `mawk`; при использовании интервалов нужен `gawk`.
* Единицы `memory-size` зависят от версии платформы — сверяйтесь с консолью
  администрирования при настройке порогов.
* Параметры блокировки ИБ и имя БД (`infobase info`) требуют прав на каждую
  информационную базу — в коллектор не включены намеренно.
* Linux-версия (`.sh`) протестирована на синтетическом выводе `rac` (парсинг и
  JSON валидны); Windows-версия (`.ps1`) вычитана статически. На реальном
  кластере сверьте имена полей `rac` — в разных сборках платформы есть отличия.
