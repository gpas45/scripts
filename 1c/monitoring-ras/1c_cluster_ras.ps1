<#
.SYNOPSIS
    Сбор метрик кластера 1С:Предприятие 8.3 через RAS/RAC для Zabbix.

.DESCRIPTION
    Порт сборщика из статьи Infostart «Мониторинг кластера 1С 8.3 в Zabbix»
    (https://infostart.ru/1c/articles/1632627/) с источника COM+ (V83.COMConnector)
    на штатный сервер администрирования RAS (ras.exe) и клиент RAC (rac.exe).
    Автор статьи в «Планах по развитию» сам указывал переход COM+ -> RAS/RAC.

    Отдаёт единый JSON той же структуры, что и оригинал:
        { cluster{...}, workingservers[...], processes[...], bases{ list[...] } }
    пригодный как Zabbix master item; из него JSONPath'ом достаются метрики и
    строятся LLD (информационные базы, рабочие серверы, рабочие процессы).

    Один вызов делает фиксированное число обращений к RAS независимо от числа
    метрик (cluster info/list, server/session/connection/process/license/
    infobase summary list) — дешевле, чем запуск rac на каждую метрику.

    Что осталось на стороне ОС/агента (в API администрирования кластера этого
    нет): статус службы, наличие logcfg.xml, загрузка CPU по ядрам и на процесс.
    Зато при переходе на RAS больше не нужен хак с реестром ProcessNameFormat и
    сопоставление perfmon-счётчиков rphost_<PID> — RAC отдаёт PID напрямую.

.PARAMETER Mode
    json | discovery.ib | discovery.process | discovery.server

.PARAMETER RacPath
    Путь к rac.exe. По умолчанию — самая свежая установка платформы.

.PARAMETER RasServer
    Адрес RAS в виде host:port (порт по умолчанию 1545).

.PARAMETER ClusterUser / ClusterPwd
    Учётка администратора кластера (если задана).

.PARAMETER CorpLicensePattern
    Regex short-presentation КОРП/базовых лицензий, исключаемых из счётчика ПРОФ
    (как в статье: КОРП 500 и базовые). Проверьте формат на своей платформе.

.NOTES
    Кроссплатформенный: Windows PowerShell 5.1 (powershell) или PowerShell 7+
    (pwsh) на Linux. Путь и имя rac (rac.exe / rac) определяются автоматически.

.EXAMPLE
    # Windows
    powershell -NoProfile -ExecutionPolicy Bypass -File 1c_cluster_ras.ps1 json
    # Linux
    pwsh -NoProfile -File ./1c_cluster_ras.ps1 json -RasServer 1c-srv:1545
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('json', 'discovery.ib', 'discovery.process', 'discovery.server')]
    [string]$Mode = 'json',

    [string]$RacPath,
    [string]$RasServer = 'localhost:1545',
    [string]$ClusterUser = '',
    [string]$ClusterPwd = '',
    [string]$CorpLicensePattern = 'ORG8B .{3} 500|ORGL8 .{3} 1'
)

$ErrorActionPreference = 'Stop'
# На Linux/pwsh в неинтерактивном режиме смена кодировки может кинуть исключение.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# Windows PowerShell 5.1 не определяет $IsWindows — там платформа всегда Windows.
$script:OnWindows = ($null -eq $IsWindows) -or $IsWindows

# --- Поиск rac (rac.exe / rac) -------------------------------------------
# Кроссплатформенно: сначала PATH, затем стандартные каталоги установки платформы.
function Resolve-RacPath {
    param([string]$Explicit)

    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) { return $Explicit }
        throw "rac не найден по указанному пути: $Explicit"
    }

    if ($script:OnWindows) {
        $racName = 'rac.exe'
        $roots = @("$env:ProgramFiles\1cv8", "${env:ProgramFiles(x86)}\1cv8")
    }
    else {
        $racName = 'rac'
        $roots = @('/opt/1cv8', '/opt/1C', '/usr/local/1cv8', '/usr/lib/1cv8')
    }

    # 1) rac в PATH.
    $onPath = Get-Command $racName -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($onPath) { return $onPath.Source }

    # 2) Рекурсивный поиск в каталогах установки, самая свежая версия — первой.
    $roots = $roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    if (-not $roots) { throw 'Каталог платформы 1С не найден. Укажите путь параметром -RacPath.' }

    $rac = Get-ChildItem -Path $roots -Recurse -Filter $racName -ErrorAction SilentlyContinue |
        Sort-Object -Property FullName -Descending |
        Select-Object -First 1

    if (-not $rac) { throw "$racName не найден. Укажите путь параметром -RacPath." }
    return $rac.FullName
}

# --- Запуск rac и разбор ответа ------------------------------------------
# rac печатает записи блоками "ключ : значение", разделёнными пустой строкой.
function Invoke-Rac {
    param([string[]]$Arguments)

    $auth = @()
    if ($ClusterUser) { $auth += "--cluster-user=$ClusterUser" }
    if ($ClusterPwd) { $auth += "--cluster-pwd=$ClusterPwd" }

    $all = @($RasServer) + $Arguments + $auth
    $raw = & $script:Rac @all 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "rac завершился с кодом $LASTEXITCODE: $($raw -join ' ')"
    }
    return $raw
}

function ConvertFrom-RacList {
    param([string[]]$Lines)

    $records = New-Object System.Collections.Generic.List[hashtable]
    $current = @{}
    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($current.Count -gt 0) { $records.Add($current); $current = @{} }
            continue
        }
        $idx = $line.IndexOf(':')
        if ($idx -lt 0) { continue }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        $current[$key] = $val
    }
    if ($current.Count -gt 0) { $records.Add($current) }
    return $records
}

function Get-Field {
    param([hashtable]$Record, [string]$Name, $Default = '')
    if ($Record -and $Record.ContainsKey($Name)) { return $Record[$Name] }
    return $Default
}

function Get-Int { param($Value) try { return [int]$Value } catch { return 0 } }
function Get-Long { param($Value) try { return [long]$Value } catch { return 0 } }
function Get-Dbl { param($Value) try { return [double](($Value -replace ',', '.')) } catch { return 0.0 } }

function Measure-AppId {
    param($Sessions, [string[]]$AppIds)
    @($Sessions | Where-Object { $AppIds -contains (Get-Field $_ 'app-id') }).Count
}

# Краткая карточка сессии для «топовых» сессий рабочего процесса.
function Get-SessionBrief {
    param([hashtable]$Session, [hashtable]$IbNameById)
    if (-not $Session) { return $null }
    [ordered]@{
        infoBase       = $IbNameById[(Get-Field $Session 'infobase')]
        SessionID      = Get-Field $Session 'session-id'
        AppID          = Get-Field $Session 'app-id'
        userName       = Get-Field $Session 'user-name'
        MemoryCurrent  = Get-Long (Get-Field $Session 'memory-current')
        cpuTimeCurrent = Get-Long (Get-Field $Session 'cpu-time-current')
        dbProcTook     = Get-Long (Get-Field $Session 'db-proc-took')
    }
}

# --- Сбор данных ----------------------------------------------------------
$script:Rac = Resolve-RacPath -Explicit $RacPath

$clusters = ConvertFrom-RacList (Invoke-Rac @('cluster', 'list'))
if ($clusters.Count -eq 0) { throw 'Кластеры не найдены (проверьте RAS/учётку).' }
$clusterId = Get-Field $clusters[0] 'cluster'
$cl = @("--cluster=$clusterId")

$clusterInfo = (ConvertFrom-RacList (Invoke-Rac (@('cluster', 'info') + $cl)))[0]
$servers     = ConvertFrom-RacList (Invoke-Rac (@('server', 'list') + $cl))
$infobases   = ConvertFrom-RacList (Invoke-Rac (@('infobase', 'summary', 'list') + $cl))
$sessions    = ConvertFrom-RacList (Invoke-Rac (@('session', 'list') + $cl))
$connections = ConvertFrom-RacList (Invoke-Rac (@('connection', 'list') + $cl))
$processes   = ConvertFrom-RacList (Invoke-Rac (@('process', 'list') + $cl))
$licenses    = ConvertFrom-RacList (Invoke-Rac (@('license', 'list') + $cl))

# --- Индексы --------------------------------------------------------------
# Сессия по uuid — чтобы обогатить записи лицензий пользователем/базой.
$sessById = @{}
foreach ($s in $sessions) { $sessById[(Get-Field $s 'session')] = $s }

# Имя ИБ по uuid.
$ibNameById = @{}
foreach ($ib in $infobases) { $ibNameById[(Get-Field $ib 'infobase')] = (Get-Field $ib 'name') }

# Пользовательские (клиентские) лицензии — привязаны к сессии.
$clientLicenses = @($licenses | Where-Object { Get-Field $_ 'session' })
# Множество uuid сессий, на которые выдана лицензия (для подсчёта «пользователей»).
$licensedSessions = @{}
foreach ($lic in $clientLicenses) { $licensedSessions[(Get-Field $lic 'session')] = $true }
# ПРОФ = клиентские лицензии, не подпадающие под КОРП/базовые.
$proLicenses = @($clientLicenses | Where-Object {
        (Get-Field $_ 'short-presentation') -notmatch $CorpLicensePattern
    })

switch ($Mode) {

    'discovery.ib' {
        $data = foreach ($ib in $infobases) {
            [ordered]@{
                '{#IBUUID}'  = Get-Field $ib 'infobase'
                '{#IBNAME}'  = Get-Field $ib 'name'
                '{#IBDESCR}' = Get-Field $ib 'descr'
            }
        }
        (@{ data = @($data) } | ConvertTo-Json -Depth 4 -Compress)
    }

    'discovery.process' {
        $data = foreach ($p in $processes) {
            [ordered]@{
                '{#PROCUUID}' = Get-Field $p 'process'
                '{#PROCHOST}' = Get-Field $p 'host'
                '{#PROCPORT}' = Get-Field $p 'port'
                '{#PROCPID}'  = Get-Field $p 'pid'
            }
        }
        (@{ data = @($data) } | ConvertTo-Json -Depth 4 -Compress)
    }

    'discovery.server' {
        $data = foreach ($srv in $servers) {
            [ordered]@{
                '{#SRVUUID}' = Get-Field $srv 'server'
                '{#SRVNAME}' = Get-Field $srv 'name'
                '{#SRVHOST}' = Get-Field $srv 'agent-host'
            }
        }
        (@{ data = @($data) } | ConvertTo-Json -Depth 4 -Compress)
    }

    'json' {
        # --- cluster (параметры + счётчики сеансов) ------------------------
        $prolicenseUsers = foreach ($lic in $proLicenses) {
            $s = $sessById[(Get-Field $lic 'session')]
            [ordered]@{
                infoBase = if ($s) { $ibNameById[(Get-Field $s 'infobase')] } else { '' }
                userName = if ($s) { Get-Field $s 'user-name' } else { '' }
                host     = if ($s) { Get-Field $s 'host' } else { '' }
                license  = Get-Field $lic 'short-presentation'
            }
        }

        $cluster = [ordered]@{
            uuid                        = $clusterId
            name                        = Get-Field $clusterInfo 'name'
            host                        = Get-Field $clusterInfo 'host'
            MainPort                    = Get-Int (Get-Field $clusterInfo 'main-port')
            MaxMemorySize               = Get-Long (Get-Field $clusterInfo 'max-memory-size')
            KillByMemoryWithDump        = (Get-Field $clusterInfo 'kill-by-memory-with-dump') -eq 'yes'
            LoadBalancingMode           = Get-Field $clusterInfo 'load-balancing-mode'
            SessionFaultToleranceLevel  = Get-Int (Get-Field $clusterInfo 'session-fault-tolerance-level')
            ExpirationTimeout           = Get-Int (Get-Field $clusterInfo 'expiration-timeout')
            LifeTimeLimit               = Get-Int (Get-Field $clusterInfo 'lifetime-limit')
            SecurityLevel               = Get-Int (Get-Field $clusterInfo 'security-level')
            KillProblemProcesses        = (Get-Field $clusterInfo 'kill-problem-processes') -eq 'yes'
            workingservers_count        = @($servers).Count
            sessions_count              = @($sessions).Count
            connections_count           = @($connections).Count
            users_count                 = @($clientLicenses).Count
            clients_count               = Measure-AppId $sessions @('1CV8', '1CV8C')
            ws_count                    = Measure-AppId $sessions @('WSConnection')
            http_count                  = Measure-AppId $sessions @('HTTPServiceConnection')
            jobs_count                  = Measure-AppId $sessions @('BackgroundJob')
            com_count                   = Measure-AppId $sessions @('COMConnection')
            web_count                   = Measure-AppId $sessions @('WebServerExtension')
            prolicense_count            = @($proLicenses).Count
            prolicense_users            = @($prolicenseUsers)
        }

        # --- workingservers -------------------------------------------------
        # CPU по ядрам (counter_processor_*) в RAC отсутствует — остаётся на ОС.
        $workingservers = foreach ($srv in $servers) {
            [ordered]@{
                uuid             = Get-Field $srv 'server'
                Name             = Get-Field $srv 'name'
                HostName         = Get-Field $srv 'agent-host'
                MainPort         = Get-Int (Get-Field $srv 'agent-port')
                connections_limit = Get-Int (Get-Field $srv 'connections-limit')
                infobases_limit  = Get-Int (Get-Field $srv 'infobases-limit')
                memory_limit     = Get-Long (Get-Field $srv 'memory-limit')
            }
        }

        # --- processes (rphost) --------------------------------------------
        # Сессии, сгруппированные по процессу — для users/sessions/top-сессий.
        $sessByProc = @{}
        foreach ($s in $sessions) {
            $pid1c = Get-Field $s 'process'
            if (-not $sessByProc.ContainsKey($pid1c)) { $sessByProc[$pid1c] = New-Object System.Collections.Generic.List[hashtable] }
            $sessByProc[$pid1c].Add($s)
        }

        $procMetrics = foreach ($p in $processes) {
            $procUuid = Get-Field $p 'process'
            $ps = if ($sessByProc.ContainsKey($procUuid)) { $sessByProc[$procUuid] } else { @() }

            $topMem  = $ps | Sort-Object { Get-Long (Get-Field $_ 'memory-current') }   -Descending | Select-Object -First 1
            $topCpu  = $ps | Sort-Object { Get-Long (Get-Field $_ 'cpu-time-current') } -Descending | Select-Object -First 1
            $topDb   = $ps | Sort-Object { Get-Long (Get-Field $_ 'db-proc-took') }     -Descending | Select-Object -First 1

            $procLicUsers = @($ps | Where-Object { $licensedSessions.ContainsKey((Get-Field $_ 'session')) }).Count

            [ordered]@{
                PID            = Get-Field $p 'pid'
                MainPort       = Get-Int (Get-Field $p 'port')
                HostName       = Get-Field $p 'host'
                StartedAt      = Get-Field $p 'started-at'
                MemorySize     = Get-Long (Get-Field $p 'memory-size')
                connections    = Get-Int (Get-Field $p 'connections')
                Running        = (Get-Field $p 'running') -eq 'yes'
                Use            = Get-Field $p 'use'
                IsEnable       = (Get-Field $p 'is-enable') -eq 'yes'
                AvailablePerf  = Get-Int (Get-Field $p 'available-perfomance')
                AvgCallTime    = Get-Dbl (Get-Field $p 'avg-call-time')
                sessions       = @($ps).Count
                users          = $procLicUsers
                session_mem    = Get-SessionBrief $topMem $ibNameById
                session_CPU    = Get-SessionBrief $topCpu $ibNameById
                session_proc_took = Get-SessionBrief $topDb $ibNameById
            }
        }

        # --- bases ----------------------------------------------------------
        $sessByIb = @{}
        foreach ($s in $sessions) {
            $ibId = Get-Field $s 'infobase'
            if (-not $sessByIb.ContainsKey($ibId)) { $sessByIb[$ibId] = New-Object System.Collections.Generic.List[hashtable] }
            $sessByIb[$ibId].Add($s)
        }

        $baseList = foreach ($ib in $infobases) {
            $ibId = Get-Field $ib 'infobase'
            $bs = if ($sessByIb.ContainsKey($ibId)) { $sessByIb[$ibId] } else { @() }

            $ibUsers = @($bs | Where-Object { $licensedSessions.ContainsKey((Get-Field $_ 'session')) }).Count

            # Регламентные задания под пользователями вида reg000.
            $regList = $bs |
                Where-Object { (Get-Field $_ 'user-name') -match '^reg\d{3}' } |
                Group-Object { Get-Field $_ 'user-name' } |
                ForEach-Object { [ordered]@{ username = $_.Name; count = $_.Count } }

            [ordered]@{
                BaseName    = Get-Field $ib 'name'
                Description = Get-Field $ib 'descr'
                sessions    = @($bs).Count
                users       = $ibUsers
                reglaments  = @($regList)
            }
        }

        # --- Итог -----------------------------------------------------------
        $result = [ordered]@{
            cluster        = $cluster
            workingservers = @($workingservers)
            processes      = @($procMetrics)
            bases          = [ordered]@{ list = @($baseList) }
        }
        ($result | ConvertTo-Json -Depth 8 -Compress)
    }
}
