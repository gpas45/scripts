<#
.SYNOPSIS
    Сбор метрик кластера 1С:Предприятие 8.3 через RAS/RAC для Zabbix.

.DESCRIPTION
    Опрашивает сервер администрирования (RAS) утилитой rac.exe и отдаёт данные
    в формате, удобном для Zabbix:

      * json                - один JSON-объект со всеми метриками кластера
                              (master item + dependent items с JSONPath);
      * discovery.ib        - LLD-список информационных баз;
      * discovery.process   - LLD-список рабочих процессов (rphost).

    Один вызов делает фиксированное число обращений к RAS (cluster/infobase/
    session/connection/process/license/lock list) независимо от количества
    метрик — поэтому дешевле «мастер-айтемом», чем сотней активных проверок.

.PARAMETER Mode
    json | discovery.ib | discovery.process

.PARAMETER RacPath
    Путь к rac.exe. По умолчанию берётся самая свежая установка платформы.

.PARAMETER RasServer
    Адрес RAS в виде host:port (порт по умолчанию 1545).

.PARAMETER ClusterUser / ClusterPwd
    Учётка администратора кластера (если задана в кластере).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass 1c_cluster_ras.ps1 json
    powershell -NoProfile -ExecutionPolicy Bypass 1c_cluster_ras.ps1 discovery.ib
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('json', 'discovery.ib', 'discovery.process')]
    [string]$Mode = 'json',

    [string]$RacPath,
    [string]$RasServer = 'localhost:1545',
    [string]$ClusterUser = '',
    [string]$ClusterPwd = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Поиск rac.exe --------------------------------------------------------
function Resolve-RacPath {
    param([string]$Explicit)

    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) { return $Explicit }
        throw "rac.exe не найден по указанному пути: $Explicit"
    }

    $roots = @(
        "$env:ProgramFiles\1cv8",
        "${env:ProgramFiles(x86)}\1cv8"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    if (-not $roots) { throw 'Каталог платформы 1С (1cv8) не найден. Укажите путь параметром -RacPath.' }

    $rac = Get-ChildItem -Path $roots -Recurse -Filter 'rac.exe' -ErrorAction SilentlyContinue |
        Sort-Object -Property FullName -Descending |
        Select-Object -First 1

    if (-not $rac) { throw 'rac.exe не найден. Укажите путь параметром -RacPath.' }
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
    if ($Record.ContainsKey($Name)) { return $Record[$Name] }
    return $Default
}

# --- Основной сбор --------------------------------------------------------
$script:Rac = Resolve-RacPath -Explicit $RacPath

$clusters = ConvertFrom-RacList (Invoke-Rac @('cluster', 'list'))
if ($clusters.Count -eq 0) { throw 'Кластеры не найдены (проверьте RAS/учётку).' }
$clusterId = Get-Field $clusters[0] 'cluster'
$cl = @("--cluster=$clusterId")

$infobases   = ConvertFrom-RacList (Invoke-Rac (@('infobase', 'summary', 'list') + $cl))
$sessions    = ConvertFrom-RacList (Invoke-Rac (@('session', 'list') + $cl))
$connections = ConvertFrom-RacList (Invoke-Rac (@('connection', 'list') + $cl))
$processes   = ConvertFrom-RacList (Invoke-Rac (@('process', 'list') + $cl))
$licenses    = ConvertFrom-RacList (Invoke-Rac (@('license', 'list') + $cl))

# lock list поддерживается не во всех сборках — не роняем весь сбор из-за него
$locks = @()
try { $locks = ConvertFrom-RacList (Invoke-Rac (@('lock', 'list') + $cl)) } catch { $locks = @() }

# Сессии, сгруппированные по инфобазе
$sessionsByIb = @{}
foreach ($s in $sessions) {
    $ib = Get-Field $s 'infobase'
    if (-not $sessionsByIb.ContainsKey($ib)) { $sessionsByIb[$ib] = 0 }
    $sessionsByIb[$ib]++
}

switch ($Mode) {

    'discovery.ib' {
        $data = foreach ($ib in $infobases) {
            [ordered]@{
                '{#IBUUID}' = Get-Field $ib 'infobase'
                '{#IBNAME}' = Get-Field $ib 'name'
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

    'json' {
        $procMetrics = foreach ($p in $processes) {
            [ordered]@{
                uuid           = Get-Field $p 'process'
                host           = Get-Field $p 'host'
                port           = [int](Get-Field $p 'port' 0)
                pid            = Get-Field $p 'pid'
                running        = (Get-Field $p 'running') -eq 'yes'
                connections    = [int](Get-Field $p 'connections' 0)
                memory_size    = [long](Get-Field $p 'memory-size' 0)
                memory_excess  = [long](Get-Field $p 'memory-excess-time' 0)
                avail_perf     = [int](Get-Field $p 'available-perfomance' 0)
                avg_call_time  = [double]((Get-Field $p 'avg-call-time' 0) -replace ',', '.')
                capacity       = [int](Get-Field $p 'capacity' 0)
            }
        }

        $ibMetrics = foreach ($ib in $infobases) {
            $id = Get-Field $ib 'infobase'
            [ordered]@{
                uuid     = $id
                name     = Get-Field $ib 'name'
                sessions = [int]($sessionsByIb[$id])
            }
        }

        $result = [ordered]@{
            cluster = [ordered]@{
                uuid        = $clusterId
                infobases   = @($infobases).Count
                sessions    = @($sessions).Count
                connections = @($connections).Count
                processes   = @($processes).Count
                licenses    = @($licenses).Count
                locks       = @($locks).Count
            }
            processes = @($procMetrics)
            infobases = @($ibMetrics)
        }
        ($result | ConvertTo-Json -Depth 5 -Compress)
    }
}
