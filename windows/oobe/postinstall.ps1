<#
.SYNOPSIS
    Пост-установочная настройка рабочей станции: ПО, правки реестра, системные параметры.

.DESCRIPTION
    Запускается автоматически при первом входе (FirstLogonCommands в файле ответов)
    либо вручную с правами администратора:

        powershell -ExecutionPolicy Bypass -File .\postinstall.ps1 -Profiles base,browser

    Что делает (всё описано данными в postinstall.json, а не в коде):
      1. ждёт поднятия сети;
      2. подключается к Synology NAS (SMB или HTTP) — основной источник дистрибутивов;
      3. ставит доверенные сертификаты (Минцифры и прочие) с проверкой отпечатка;
      4. ставит ПО: NAS -> winget -> прямая ссылка (порядок задаётся software.source);
      5. при office.enabled ставит Office через ODT или winget;
      6. применяет правки реестра;
      7. применяет системные настройки (часовой пояс, электропитание, RDP, имя ПК).

    Ошибка на отдельном пакете не прерывает работу: в конце печатается сводка,
    код возврата 1, если что-то не установилось. Повторный запуск безопасен.

.PARAMETER Profiles
    Какие наборы применять. В postinstall.json у каждого элемента есть profiles;
    элемент без profiles применяется всегда. По умолчанию — base.

.PARAMETER Include
    Поставить только эти пакеты, независимо от профилей. Сравнение с именем из
    postinstall.json без учёта регистра, по подстроке и по шаблонам (*, ?).
    Например: -Include 'Крипто*','7-Zip'

.PARAMETER Exclude
    Исключить эти пакеты из выбранного набора. Формат тот же, что у Include.

.PARAMETER Select
    Спросить интерактивно, что ставить: выводится нумерованный список всех
    пакетов, звёздочкой отмечены выбранные текущими профилями. Только для
    ручного запуска — при автоматическом прогоне из FirstLogonCommands не
    задавайте, иначе установка будет ждать ввода. Если консоль неинтерактивна,
    ключ игнорируется с предупреждением.

.PARAMETER NoPrompt
    Ничего не спрашивать и не ждать подтверждения. Обязателен при запуске из
    FirstLogonCommands: там сеанс интерактивный, и без этого ключа первый вход
    завис бы на вопросе.

.PARAMETER ConfigPath
    Путь к postinstall.json. По умолчанию ищется рядом со скриптом и в
    %ProgramData%\oobe, иначе скачивается с ConfigUri.

.PARAMETER NasType
    http или smb — перекрывает nas.type из конфига.

.PARAMETER NasBaseUrl
    Адрес HTTPS-раздачи дистрибутивов, перекрывает nas.baseUrl. Так адрес
    меняется без правки конфига.

.PARAMETER NasShare
    UNC-путь к SMB-папке, перекрывает nas.share.

.PARAMETER NasUser
.PARAMETER NasPassword
    Учётные данные NAS: для SMB — подключение к папке, для HTTPS — базовая
    аутентификация. Перекрывают значения из конфига. Пароль в репозиторий не
    кладём — см. nas.passwordFile в postinstall.json.

.NOTES
    Документация по файлам ответов:
    https://learn.microsoft.com/ru-ru/windows-hardware/customize/desktop/unattend/
#>
[CmdletBinding()]
param(
    [string[]]$Profiles = @('base'),
    [string[]]$Include,
    [string[]]$Exclude,
    [switch]$Select,
    [switch]$NoPrompt,
    [string]$ConfigPath,
    [string]$ConfigUri = 'https://raw.githubusercontent.com/gpas45/scripts/main/windows/oobe/postinstall.json',
    [ValidateSet('http', 'smb')]
    [string]$NasType,
    [string]$NasBaseUrl,
    [string]$NasShare,
    [string]$NasUser,
    [string]$NasPassword,
    [switch]$SkipCertificates,
    [switch]$SkipSoftware,
    [switch]$SkipOffice,
    [switch]$SkipRegistry,
    [switch]$SkipSystem,
    [string]$LogPath = (Join-Path -Path $env:ProgramData -ChildPath 'oobe\postinstall.log')
)

$ErrorActionPreference = 'Stop'

$script:Failures = New-Object 'System.Collections.Generic.List[string]'
$script:WorkDir = Join-Path -Path $env:TEMP -ChildPath 'oobe-postinstall'
$script:Winget = $null
$script:NasHttpHeaders = $null
$script:WingetVersion = $null
$script:RebootRequired = $false

New-Item -ItemType Directory -Force -Path $script:WorkDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
try { Start-Transcript -Path $LogPath -Append | Out-Null } catch { Write-Warning 'Не удалось начать запись лога.' }

try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch {
    Write-Warning "Не удалось включить TLS 1.2: $($_.Exception.Message)"
}

# --- Вспомогательные функции -------------------------------------------------

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "=== $Message" -ForegroundColor Cyan
}

function Invoke-Safely {
    param(
        [string]$Label,
        [scriptblock]$Action
    )
    try {
        & $Action
        Write-Host "  [ok] $Label" -ForegroundColor DarkGreen
    }
    catch {
        $script:Failures.Add("$Label — $($_.Exception.Message)")
        Write-Warning "  [!] $Label — $($_.Exception.Message)"
    }
}

function Test-ProfileMatch {
    param($Item)
    if (-not $Item.PSObject.Properties['profiles'] -or -not $Item.profiles) { return $true }
    foreach ($p in $Item.profiles) {
        if ($Profiles -contains $p) { return $true }
    }
    return $false
}

function Test-NameMatch {
    param(
        [string]$Name,
        [string[]]$Patterns
    )
    foreach ($pattern in $Patterns) {
        if ($Name -like $pattern -or $Name -like "*$pattern*") { return $true }
    }
    return $false
}

function Select-SoftwareInteractive {
    param(
        $Items,
        $Preselected
    )
    $preNames = @($Preselected | ForEach-Object { $_.name })

    Write-Host ''
    Write-Host 'Что установить:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $mark = if ($preNames -contains $Items[$i].name) { '*' } else { ' ' }
        Write-Host ('  [{0}] {1,2}. {2}' -f $mark, ($i + 1), $Items[$i].name)
    }
    Write-Host '  * — выбрано текущими профилями; просто Enter оставит этот набор.'
    Write-Host '  Номера через запятую (1,3,5), диапазоны (1-4), all — всё, none — ничего.'

    $answer = (Read-Host '  Выбор').Trim()
    if ([string]::IsNullOrEmpty($answer)) { return $Preselected }
    if ($answer -eq 'all') { return $Items }
    if ($answer -eq 'none') { return @() }

    $indexes = New-Object 'System.Collections.Generic.List[int]'
    foreach ($token in ($answer -split '[,;\s]+' | Where-Object { $_ })) {
        if ($token -match '^(\d+)\s*-\s*(\d+)$') {
            foreach ($n in [int]$Matches[1]..[int]$Matches[2]) { $indexes.Add($n) }
        }
        elseif ($token -match '^\d+$') {
            $indexes.Add([int]$token)
        }
        else {
            Write-Warning "  не разобрал «$token» — пропускаю."
        }
    }

    $result = foreach ($n in ($indexes | Sort-Object -Unique)) {
        if ($n -ge 1 -and $n -le $Items.Count) { $Items[$n - 1] }
        else { Write-Warning "  номера $n в списке нет — пропускаю." }
    }
    return @($result)
}

function Get-SoftwareToInstall {
    param($Items)

    if ($Include) {
        $selected = @($Items | Where-Object { Test-NameMatch -Name $_.name -Patterns $Include })
    }
    else {
        $selected = @($Items | Where-Object { Test-ProfileMatch -Item $_ })
    }
    if ($Exclude) {
        $selected = @($selected | Where-Object { -not (Test-NameMatch -Name $_.name -Patterns $Exclude) })
    }

    if (-not $Select) { return $selected }

    if (-not [Environment]::UserInteractive) {
        Write-Warning 'Консоль неинтерактивна — ключ -Select проигнорирован, беру набор по профилям.'
        return $selected
    }
    return (Select-SoftwareInteractive -Items $Items -Preselected $selected)
}

function Get-Configuration {
    $candidates = @()
    if ($ConfigPath) { $candidates += $ConfigPath }
    if ($PSScriptRoot) { $candidates += (Join-Path -Path $PSScriptRoot -ChildPath 'postinstall.json') }
    $candidates += (Join-Path -Path $env:ProgramData -ChildPath 'oobe\postinstall.json')

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            Write-Host "Конфигурация: $c"
            return (Get-Content -LiteralPath $c -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
    }

    if (-not $ConfigUri) { throw 'postinstall.json не найден и ConfigUri не задан.' }
    Write-Host "Конфигурация: $ConfigUri"
    $raw = (Invoke-WebRequest -Uri $ConfigUri -UseBasicParsing).Content
    if ($raw -is [byte[]]) { $raw = [Text.Encoding]::UTF8.GetString($raw) }
    return ($raw | ConvertFrom-Json)
}

function Get-Override {
    # postinstall.override.json пишет oobe.ps1 по итогам экрана плана: адрес
    # раздачи, учётная запись, выбранный набор ПО. Так postinstall.json не
    # приходится править под каждую машину.
    $candidates = @()
    if ($PSScriptRoot) { $candidates += (Join-Path -Path $PSScriptRoot -ChildPath 'postinstall.override.json') }
    $candidates += (Join-Path -Path $env:ProgramData -ChildPath 'oobe\postinstall.override.json')

    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        Write-Host "Переопределение: $candidate"
        try {
            return (Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
        catch {
            Write-Warning "Не удалось прочитать $candidate — $($_.Exception.Message)"
            return $null
        }
    }
    return $null
}

function Merge-NasOverride {
    param(
        $Nas,
        $Override
    )
    if (-not $Override -or -not $Override.PSObject.Properties['nas']) { return }
    foreach ($property in $Override.nas.PSObject.Properties) {
        if ($property.Name -like '_*') { continue }
        $Nas | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
        Write-Host "  nas.$($property.Name) = $($property.Value)"
    }
}

function Wait-Network {
    param([int]$TimeoutSeconds = 120)
    if ($TimeoutSeconds -le 0) { return }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $up = Get-NetConnectionProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.IPv4Connectivity -eq 'Internet' -or $_.IPv4Connectivity -eq 'LocalNetwork' }
        if ($up) {
            Write-Host "Сеть доступна: $(($up | Select-Object -First 1).Name)"
            return
        }
        Start-Sleep -Seconds 5
    }
    Write-Warning 'Сеть не поднялась за отведённое время — часть шагов может не выполниться.'
}

# --- NAS ---------------------------------------------------------------------

function Get-NasPassword {
    param($Nas)
    if ($NasPassword) { return $NasPassword }
    if (-not $Nas.PSObject.Properties['passwordFile'] -or -not $Nas.passwordFile) { return $null }

    $file = $Nas.passwordFile
    if (-not [IO.Path]::IsPathRooted($file)) {
        $roots = @()
        if ($PSScriptRoot) { $roots += $PSScriptRoot }
        $roots += (Join-Path -Path $env:ProgramData -ChildPath 'oobe')
        foreach ($r in $roots) {
            $candidate = Join-Path -Path $r -ChildPath $file
            if (Test-Path -LiteralPath $candidate) { $file = $candidate; break }
        }
    }
    if (Test-Path -LiteralPath $file) {
        return (Get-Content -LiteralPath $file -Raw).Trim()
    }
    Write-Warning "Файл с паролем NAS не найден: $($Nas.passwordFile)"
    return $null
}

function Connect-NasShare {
    param($Nas)

    if ($Nas.type -eq 'http') {
        if ($Nas.ignoreCertErrors) {
            # DSM по умолчанию отдаёт самоподписанный сертификат.
            [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            Write-Warning 'Проверка TLS-сертификата NAS отключена (nas.ignoreCertErrors).'
        }

        # Раздача в интернете обычно закрыта базовой аутентификацией. Windows
        # PowerShell по -Credential ждёт ответа 401, поэтому отправляем заголовок
        # сразу — так работает и там, где сервер challenge не присылает.
        $user = if ($NasUser) { $NasUser } else { $Nas.user }
        $password = Get-NasPassword -Nas $Nas
        if ($user -and $password) {
            $pair = '{0}:{1}' -f $user, $password
            $token = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
            $script:NasHttpHeaders = @{ Authorization = "Basic $token" }
            Write-Host "HTTPS: $($Nas.baseUrl), базовая аутентификация как $user."
        }
        else {
            Write-Host "HTTPS: $($Nas.baseUrl), без аутентификации."
        }
        return
    }

    $share = $script:NasSharePath
    $user = if ($NasUser) { $NasUser } else { $Nas.user }
    if (-not $user) {
        Write-Host "SMB: $share без учётных данных (гостевой доступ)."
        return
    }
    $password = Get-NasPassword -Nas $Nas

    try {
        New-SmbMapping -RemotePath $share -UserName $user -Password $password -ErrorAction Stop | Out-Null
        Write-Host "SMB: подключено $share как $user."
    }
    catch {
        Write-Warning "New-SmbMapping не сработал ($($_.Exception.Message)) — пробую net use."
        & net.exe use $share $password /user:$user 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Не удалось подключиться к $share (net use код $LASTEXITCODE). Проверьте учётную запись: гостевой вход в SMB в Windows 10/11 запрещён по умолчанию."
        }
    }
}

function Disconnect-NasShare {
    param($Nas)
    if ($Nas.type -ne 'smb') { return }
    try { Remove-SmbMapping -RemotePath $script:NasSharePath -Force -ErrorAction Stop }
    catch { & net.exe use $script:NasSharePath /delete /y 2>&1 | Out-Null }
}

function Test-NasAccess {
    param(
        $Nas,
        [string]$ProbePath
    )
    # Ok      — источник отвечает и аутентификация пройдена
    # Caveat  — доступ есть, но пробный файл не найден (раскладка/путь)
    $result = @{ Ok = $false; Caveat = $false; Message = '' }

    if ($Nas.type -eq 'smb') {
        $path = $script:NasSharePath
        try {
            if (-not (Test-Path -LiteralPath $path)) {
                $result.Message = "папка $path недоступна"
                return $result
            }
            $result.Ok = $true
            $result.Message = "папка $path доступна"
            if ($ProbePath) {
                $probe = Join-Path -Path $path -ChildPath ($ProbePath -replace '/', '\')
                if (-not (Test-Path -LiteralPath $probe)) {
                    $result.Caveat = $true
                    $result.Message = "папка $path доступна, но файла $ProbePath в ней нет"
                }
            }
        }
        catch {
            $result.Message = "$path — $($_.Exception.Message)"
        }
        return $result
    }

    $base = $Nas.baseUrl.TrimEnd('/')
    $url = if ($ProbePath) { '{0}/{1}' -f $base, ($ProbePath -replace '\\', '/') } else { "$base/" }

    foreach ($method in @('Head', 'Get')) {
        $request = @{ Uri = $url; Method = $method; UseBasicParsing = $true; TimeoutSec = 30 }
        if ($script:NasHttpHeaders) { $request['Headers'] = $script:NasHttpHeaders }
        try {
            $response = Invoke-WebRequest @request
            $result.Ok = $true
            $result.Message = "HTTP $([int]$response.StatusCode), $url"
            return $result
        }
        catch {
            $status = 0
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }

            if ($status -eq 405 -and $method -eq 'Head') { continue }

            if ($status -eq 0) {
                $result.Message = "$base недоступен — $($_.Exception.Message)"
            }
            elseif ($status -eq 401) {
                $result.Message = "401 от $base — аутентификация не пройдена, проверьте учётную запись и пароль"
            }
            elseif ($status -eq 403) {
                $result.Message = "403 от $base — доступ запрещён"
            }
            elseif ($status -eq 404) {
                # 404 вместо 401 означает, что аутентификацию мы прошли.
                $result.Ok = $true
                $result.Caveat = $true
                $result.Message = "источник отвечает и аутентификация пройдена, но $url отдаёт 404 — проверьте раскладку файлов"
            }
            else {
                $result.Message = "HTTP $status от $url"
            }
            return $result
        }
    }

    if (-not $result.Message) { $result.Message = "$url — проверить не удалось" }
    return $result
}

function Get-NasFile {
    param(
        $Nas,
        [string]$RelativePath
    )
    if (-not $RelativePath) { return $null }
    $dest = Join-Path -Path $script:WorkDir -ChildPath (Split-Path -Leaf ($RelativePath -replace '/', '\'))

    if ($Nas.type -eq 'http') {
        $url = '{0}/{1}' -f $Nas.baseUrl.TrimEnd('/'), ($RelativePath -replace '\\', '/')
        $request = @{ Uri = $url; OutFile = $dest; UseBasicParsing = $true }
        if ($script:NasHttpHeaders) { $request['Headers'] = $script:NasHttpHeaders }
        try {
            Invoke-WebRequest @request
            return $dest
        }
        catch {
            Write-Host "  NAS (http): $url недоступен — $($_.Exception.Message)"
            return $null
        }
    }

    $src = Join-Path -Path $script:NasSharePath -ChildPath ($RelativePath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $src)) {
        return $null
    }
    Copy-Item -LiteralPath $src -Destination $dest -Force
    return $dest
}

# --- Доверенные сертификаты --------------------------------------------------

function Import-TrustedCertificate {
    param(
        $Item,
        $Nas
    )
    $nasReady = ($Nas -and $Nas.enabled)

    $file = $null
    if ($nasReady -and $Item.nasPath) {
        $file = Get-NasFile -Nas $Nas -RelativePath $Item.nasPath
    }
    if (-not $file -and $Item.url) {
        $file = Join-Path -Path $script:WorkDir -ChildPath (Split-Path -Leaf ([uri]$Item.url).LocalPath)
        Invoke-WebRequest -Uri $Item.url -OutFile $file -UseBasicParsing
    }
    if (-not $file) { throw 'файл сертификата не найден (ни nasPath, ни url).' }

    $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $file
    $thumbprint = $cert.Thumbprint

    if ($Item.thumbprint) {
        $expected = ($Item.thumbprint -replace '[\s:]', '').ToUpperInvariant()
        if ($thumbprint -ne $expected) {
            throw "отпечаток не совпал: ожидался $expected, у файла $thumbprint."
        }
    }
    else {
        Write-Warning "  отпечаток в конфиге не задан — ставлю $thumbprint без проверки."
    }

    $store = if ($Item.store) { $Item.store } else { 'Root' }
    $location = "Cert:\LocalMachine\$store"

    $existing = Get-ChildItem -Path $location -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $thumbprint }
    if ($existing) {
        Write-Host "  уже в $location ($thumbprint)."
        return
    }

    Import-Certificate -FilePath $file -CertStoreLocation $location -ErrorAction Stop | Out-Null
    Write-Host "  установлен в $location ($thumbprint), выдан: $($cert.Subject)"
}

# --- Установка ПО ------------------------------------------------------------

function Get-WingetPath {
    param([int]$TimeoutSeconds = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $cmd = Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }

        $pkg = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue |
            Sort-Object -Property Version -Descending | Select-Object -First 1
        if ($pkg -and $pkg.InstallLocation) {
            $candidate = Join-Path -Path $pkg.InstallLocation -ChildPath 'winget.exe'
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Initialize-Winget {
    # При первом входе App Installer регистрируется асинхронно, поэтому ждём.
    $path = Get-WingetPath -TimeoutSeconds 90
    if ($path) { return $path }

    Write-Warning 'winget не найден — пробую перерегистрировать App Installer.'
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop
    }
    catch {
        Write-Warning "Перерегистрация не удалась: $($_.Exception.Message)"
    }
    $path = Get-WingetPath -TimeoutSeconds 30
    if ($path) { return $path }

    Write-Warning 'Пробую поставить App Installer с https://aka.ms/getwinget.'
    try {
        $bundle = Join-Path -Path $script:WorkDir -ChildPath 'DesktopAppInstaller.msixbundle'
        Invoke-WebRequest -Uri 'https://aka.ms/getwinget' -OutFile $bundle -UseBasicParsing
        Add-AppxPackage -Path $bundle -ErrorAction Stop
    }
    catch {
        Write-Warning "Не удалось: $($_.Exception.Message)"
    }
    return (Get-WingetPath -TimeoutSeconds 30)
}

function Get-WingetVersion {
    if ($script:WingetVersion) { return $script:WingetVersion }

    $script:WingetVersion = [version]'0.0'
    try {
        $raw = (& $script:Winget '--version' 2>&1 | Out-String).Trim()
        # Вывод вида v1.2.10691, у предварительных сборок с суффиксом (v1.6.3482-preview).
        $match = [regex]::Match($raw, '(\d+(?:\.\d+){1,3})')
        if ($match.Success) {
            $script:WingetVersion = [version]$match.Value
            Write-Host "  winget $raw"
        }
        else {
            Write-Warning "  не разобрал версию winget из «$raw» — считаю её старой."
        }
    }
    catch {
        Write-Warning "  не удалось определить версию winget: $($_.Exception.Message)"
    }
    return $script:WingetVersion
}

function Install-WithWinget {
    param([string]$Id)

    if (-not $script:Winget) { $script:Winget = Initialize-Winget }
    if (-not $script:Winget) { throw 'winget недоступен (нет App Installer и не удалось его поставить).' }

    $common = @(
        'install', '--id', $Id, '--exact', '--source', 'winget', '--silent',
        '--accept-package-agreements', '--accept-source-agreements'
    )

    # --disable-interactivity появился примерно в 1.4; в 1.2 (Server 2022, LTSC,
    # образы без обновлённого App Installer) его нет, и winget падает на разборе
    # аргументов. Тихий режим --silent интерактив и так подавляет.
    if ((Get-WingetVersion) -ge [version]'1.4') {
        $common += '--disable-interactivity'
    }

    $withScope = $common + @('--scope', 'machine')
    & $script:Winget @withScope 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  --scope machine не подошёл (код $LASTEXITCODE) — повторяю без него."
        & $script:Winget @common 2>&1 | Write-Host
    }
    if ($LASTEXITCODE -ne 0) {
        # Может быть «уже установлено» — проверяем фактическое наличие.
        & $script:Winget 'list' '--id' $Id '--exact' '--accept-source-agreements' 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "winget не смог установить $Id." }
        Write-Host "  $Id уже установлен."
    }
}

function Test-FileChecksum {
    param(
        [string]$Path,
        $Checksums
    )
    if (-not $Checksums) { return }

    $requested = 0
    $verified = @()

    foreach ($algorithm in @('SHA256', 'SHA1', 'MD5')) {
        $property = $Checksums.PSObject.Properties[$algorithm.ToLowerInvariant()]
        if (-not $property -or [string]::IsNullOrWhiteSpace($property.Value)) { continue }
        $requested++
        $expected = ($property.Value -replace '[\s:-]', '').ToUpperInvariant()
        $actual = (Get-FileHash -LiteralPath $Path -Algorithm $algorithm).Hash.ToUpperInvariant()
        if ($actual -ne $expected) {
            throw "контрольная сумма $algorithm не совпала: ожидалась $expected, у файла $actual."
        }
        $verified += $algorithm
    }

    $gost = $Checksums.PSObject.Properties['gost2012_256']
    if ($gost -and -not [string]::IsNullOrWhiteSpace($gost.Value)) {
        $requested++
        # Get-FileHash ГОСТ не умеет. Считает его только cpverify из состава
        # КриптоПро CSP, то есть на чистой машине — начиная со второго пакета:
        # для самого CSP остаются обычные суммы.
        $cpverify = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
            Where-Object { $_ } |
            ForEach-Object { Join-Path -Path $_ -ChildPath 'Crypto Pro\CSP\cpverify.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1

        if (-not $cpverify) {
            Write-Warning '  ГОСТ не проверен: cpverify.exe появляется только вместе с КриптоПро CSP.'
        }
        else {
            $expected = ($gost.Value -replace '[\s:-]', '').ToUpperInvariant()
            $output = & $cpverify -mk $Path -alg GR3411_2012_256 2>&1 | Out-String
            $match = [regex]::Match($output, '[0-9A-Fa-f]{64}')
            if (-not $match.Success) {
                Write-Warning "  cpverify не вернул хеш, ГОСТ не проверен. Вывод: $($output.Trim())"
            }
            elseif ($match.Value.ToUpperInvariant() -ne $expected) {
                throw "контрольная сумма ГОСТ не совпала: ожидалась $expected, у файла $($match.Value.ToUpperInvariant())."
            }
            else {
                $verified += 'ГОСТ Р 34.11-2012'
            }
        }
    }

    if ($requested -eq 0) { return }
    if ($verified.Count -eq 0) {
        throw 'ни одну из заданных контрольных сумм проверить не удалось — установка прервана.'
    }
    Write-Host "  контрольные суммы сходятся: $($verified -join ', ')"
}

function Install-FromFile {
    param(
        [string]$Path,
        [string]$Arguments,
        [int]$TimeoutSeconds = 1800
    )
    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()

    if ($extension -eq '.msi') {
        $msiArgs = if ($Arguments) { "/i `"$Path`" $Arguments" } else { "/i `"$Path`" /qn /norestart" }
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -PassThru
    }
    elseif ($extension -eq '.ps1') {
        $proc = Start-Process -FilePath 'powershell.exe' -PassThru `
            -ArgumentList @('-ExecutionPolicy', 'Bypass', '-NoProfile', '-File', $Path)
    }
    elseif ($Arguments) {
        $proc = Start-Process -FilePath $Path -ArgumentList $Arguments -PassThru
    }
    else {
        $proc = Start-Process -FilePath $Path -PassThru
    }

    # Ждём с ограничением: установщик, который спросил что-нибудь у пользователя,
    # иначе навсегда подвесит первый вход в систему.
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill() } catch { Write-Warning '  не удалось снять зависший процесс.' }
        throw "установщик не завершился за $TimeoutSeconds с и был прерван."
    }
    $proc.WaitForExit()

    $code = $proc.ExitCode
    if ($code -eq 3010 -or $code -eq 1641) {
        $script:RebootRequired = $true
        Write-Host '  установщик просит перезагрузку.'
        return
    }
    if ($code -ne 0) { throw "установщик вернул код $code." }
}

function Copy-ApplicationConfig {
    param(
        $Item,
        $Nas
    )
    if (-not $Item.PSObject.Properties['configFiles'] -or -not $Item.configFiles) { return }

    foreach ($entry in $Item.configFiles) {
        if (-not $entry.nasPath -or -not $entry.destination) { continue }

        $source = Get-NasFile -Nas $Nas -RelativePath $entry.nasPath
        if (-not $source) {
            Write-Warning "  конфиг $($entry.nasPath) на источнике не найден — пропускаю."
            continue
        }

        $destination = [Environment]::ExpandEnvironmentVariables($entry.destination)
        $directory = Split-Path -Parent $destination
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Force -Path $directory | Out-Null
        }
        Copy-Item -LiteralPath $source -Destination $destination -Force
        Write-Host "  конфиг положен в $destination"
    }

    if ($Item.PSObject.Properties['restartService'] -and $Item.restartService) {
        $service = Get-Service -Name $Item.restartService -ErrorAction SilentlyContinue
        if (-not $service) {
            Write-Warning "  служба $($Item.restartService) не найдена — настройки подхватятся после перезагрузки."
        }
        else {
            Restart-Service -Name $Item.restartService -Force -ErrorAction Stop
            Write-Host "  служба $($Item.restartService) перезапущена"
        }
    }
}

function Install-Application {
    param(
        $Item,
        $Nas
    )
    $source = if ($Item.PSObject.Properties['source'] -and $Item.source) { $Item.source } else { 'auto' }
    $nasReady = ($Nas -and $Nas.enabled)
    $timeout = if ($Item.PSObject.Properties['timeoutSeconds'] -and $Item.timeoutSeconds) {
        [int]$Item.timeoutSeconds
    }
    else {
        1800
    }

    if (($source -eq 'auto' -or $source -eq 'nas') -and $Item.nasPath) {
        if (-not $nasReady) {
            if ($source -eq 'nas') {
                throw "пакет ставится только с источника дистрибутивов, а он недоступен (нужен $($Item.nasPath))."
            }
            Write-Host '  источник дистрибутивов недоступен — пробую следующий.'
        }
        else {
            $file = Get-NasFile -Nas $Nas -RelativePath $Item.nasPath
            if ($file) {
                Test-FileChecksum -Path $file -Checksums $Item.checksums
                Install-FromFile -Path $file -Arguments $Item.installerArgs -TimeoutSeconds $timeout
                Copy-ApplicationConfig -Item $Item -Nas $Nas
                return
            }
            if ($source -eq 'nas') {
                throw "на источнике нет файла $($Item.nasPath), а другого источника у этого пакета быть не может — положите дистрибутив на место."
            }
            Write-Host "  на источнике нет $($Item.nasPath) — пробую следующий источник."
        }
    }

    if (($source -eq 'auto' -or $source -eq 'winget') -and $Item.wingetId) {
        Install-WithWinget -Id $Item.wingetId
        Copy-ApplicationConfig -Item $Item -Nas $Nas
        return
    }

    if (($source -eq 'auto' -or $source -eq 'url') -and $Item.installerUrl) {
        $name = Split-Path -Leaf ([uri]$Item.installerUrl).LocalPath
        $dest = Join-Path -Path $script:WorkDir -ChildPath $name
        Invoke-WebRequest -Uri $Item.installerUrl -OutFile $dest -UseBasicParsing
        Test-FileChecksum -Path $dest -Checksums $Item.checksums
        Install-FromFile -Path $dest -Arguments $Item.installerArgs -TimeoutSeconds $timeout
        Copy-ApplicationConfig -Item $Item -Nas $Nas
        return
    }

    # Сюда попадаем, когда у пакета вообще нечему сработать: расписываем, что есть.
    $have = @()
    if ($Item.nasPath) { $have += "nasPath=$($Item.nasPath)" }
    if ($Item.wingetId) { $have += "wingetId=$($Item.wingetId)" }
    if ($Item.installerUrl) { $have += 'installerUrl задан' }
    $detail = if ($have.Count -gt 0) { " Задано: $($have -join ', '); при source=$source это не используется." } else { '' }
    throw "нет подходящего источника при source=$source.$detail"
}

function Install-Office {
    param(
        $Office,
        $Nas
    )
    if ($Office.mode -eq 'winget') {
        Install-WithWinget -Id $Office.wingetId
        return
    }

    $nasReady = ($Nas -and $Nas.enabled)

    $setup = $null
    if ($Office.setupPath -and (Test-Path -LiteralPath $Office.setupPath)) {
        $setup = $Office.setupPath
    }
    if (-not $setup -and $nasReady -and $Office.setupNasPath) {
        $setup = Get-NasFile -Nas $Nas -RelativePath $Office.setupNasPath
    }
    if (-not $setup) {
        Write-Host '  setup.exe не найден — ставлю Office Deployment Tool через winget.'
        Install-WithWinget -Id 'Microsoft.OfficeDeploymentTool'
        $setup = Get-ChildItem -Filter 'setup.exe' -Recurse -ErrorAction SilentlyContinue -Path @(
            (Join-Path -Path $env:ProgramFiles -ChildPath 'OfficeDeploymentTool'),
            (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath 'OfficeDeploymentTool')
        ) | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $setup) { throw 'не найден setup.exe из Office Deployment Tool.' }

    $config = $null
    if ($Office.configPath -and (Test-Path -LiteralPath $Office.configPath)) {
        $config = $Office.configPath
    }
    if (-not $config -and $nasReady -and $Office.configNasPath) {
        $config = Get-NasFile -Nas $Nas -RelativePath $Office.configNasPath
    }
    if (-not $config -and $Office.configUri) {
        $config = Join-Path -Path $script:WorkDir -ChildPath 'office-configuration.xml'
        Invoke-WebRequest -Uri $Office.configUri -OutFile $config -UseBasicParsing
    }
    if (-not $config) { throw 'не найден configuration.xml для Office.' }

    Write-Host "  ODT: $setup /configure $config"
    $proc = Start-Process -FilePath $setup -ArgumentList @('/configure', $config) -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "setup.exe вернул код $($proc.ExitCode)." }
}

# --- Реестр и система --------------------------------------------------------

function Set-RegistryTweak {
    param($Tweak)
    if (-not (Test-Path -LiteralPath $Tweak.path)) {
        New-Item -Path $Tweak.path -Force | Out-Null
    }

    # Безымянное значение ключа (в regedit показывается как «(По умолчанию)»)
    # задаётся только через Set-Item: именно так включается классическое
    # контекстное меню Windows 11 — пустая строка в InprocServer32.
    $name = if ($Tweak.PSObject.Properties['name']) { $Tweak.name } else { $null }
    if ([string]::IsNullOrEmpty($name) -or $name -eq '(default)') {
        Set-Item -LiteralPath $Tweak.path -Value $Tweak.value
        return
    }

    $type = if ($Tweak.PSObject.Properties['type'] -and $Tweak.type) { $Tweak.type } else { 'DWord' }
    New-ItemProperty -LiteralPath $Tweak.path -Name $name -PropertyType $type -Value $Tweak.value -Force | Out-Null
}

function Set-SystemSetting {
    param($Settings)

    if ($Settings.timeZone) {
        Invoke-Safely -Label "часовой пояс $($Settings.timeZone)" -Action {
            & tzutil.exe /s $Settings.timeZone
            if ($LASTEXITCODE -ne 0) { throw "tzutil вернул код $LASTEXITCODE." }
        }
    }

    if ($Settings.defaultInputLanguage) {
        # InputLocale в файле ответов задаёт порядок раскладок, но при UserLocale
        # ru-RU Windows иногда делает русскую раскладкой по умолчанию. Закрепляем.
        Invoke-Safely -Label "раскладка по умолчанию $($Settings.defaultInputLanguage)" -Action {
            $tips = @{ 'en-US' = '0409:00000409'; 'ru-RU' = '0419:00000419' }
            $tip = if ($tips.ContainsKey($Settings.defaultInputLanguage)) {
                $tips[$Settings.defaultInputLanguage]
            }
            else {
                $Settings.defaultInputLanguage
            }
            Set-WinDefaultInputMethodOverride -InputTip $tip -ErrorAction Stop
        }
    }

    if ($Settings.disableHibernation) {
        Invoke-Safely -Label 'отключение гибернации' -Action {
            & powercfg.exe /hibernate off
            if ($LASTEXITCODE -ne 0) { throw "powercfg вернул код $LASTEXITCODE." }
        }
    }

    if ($Settings.neverSleepOnAc) {
        Invoke-Safely -Label 'питание от сети: не засыпать' -Action {
            & powercfg.exe /change standby-timeout-ac 0
            & powercfg.exe /change hibernate-timeout-ac 0
            & powercfg.exe /change disk-timeout-ac 0
            & powercfg.exe /change monitor-timeout-ac 15
        }
    }

    if ($Settings.enableRdp) {
        Invoke-Safely -Label 'включение RDP' -Action {
            Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
                -Name 'fDenyTSConnections' -Value 0 -Type DWord
            Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
        }
    }

    if ($Settings.computerName) {
        Invoke-Safely -Label "имя компьютера $($Settings.computerName)" -Action {
            if ($env:COMPUTERNAME -ne $Settings.computerName) {
                Rename-Computer -NewName $Settings.computerName -Force -ErrorAction Stop
                $script:RebootRequired = $true
            }
        }
    }

    if ($Settings.restartExplorer) {
        Invoke-Safely -Label 'перезапуск Проводника (применение настроек HKCU)' -Action {
            Stop-Process -Name 'explorer' -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Основной сценарий -------------------------------------------------------

$config = Get-Configuration
Write-Host "Профили: $($Profiles -join ', ')"

# Приоритет везде один: postinstall.json -> postinstall.override.json -> ключи.
$override = Get-Override

if ($override) {
    if (-not $PSBoundParameters.ContainsKey('Profiles') -and $override.PSObject.Properties['profiles'] -and $override.profiles) {
        $Profiles = @($override.profiles)
        Write-Host "  profiles = $($Profiles -join ', ')"
    }
    if (-not $Include -and $override.PSObject.Properties['include'] -and $override.include) {
        $Include = @($override.include)
        Write-Host "  include = $($Include -join ', ')"
    }
    if (-not $Exclude -and $override.PSObject.Properties['exclude'] -and $override.exclude) {
        $Exclude = @($override.exclude)
        Write-Host "  exclude = $($Exclude -join ', ')"
    }
}

if ($override -and $override.PSObject.Properties['office'] -and $config.PSObject.Properties['office']) {
    foreach ($property in $override.office.PSObject.Properties) {
        if ($property.Name -like '_*') { continue }
        $config.office | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
        Write-Host "  office.$($property.Name) = $($property.Value)"
    }
}

$nas = $null
if ($config.PSObject.Properties['nas']) { $nas = $config.nas }
if ($nas) {
    Merge-NasOverride -Nas $nas -Override $override
    if ($NasType) { $nas.type = $NasType }
    if ($NasBaseUrl) { $nas.baseUrl = $NasBaseUrl }
    if ($NasShare) { $nas.share = $NasShare }
}
$script:NasSharePath = if ($nas) { $nas.share } else { $null }

$nasAccess = $null
if ($nas -and $nas.enabled) {
    Write-Step 'Сеть и источник дистрибутивов'
    $timeout = if ($nas.PSObject.Properties['waitForNetworkSeconds']) { [int]$nas.waitForNetworkSeconds } else { 120 }
    Wait-Network -TimeoutSeconds $timeout
    Invoke-Safely -Label "подключение к источнику ($($nas.type))" -Action { Connect-NasShare -Nas $nas }

    # Проверяем доступ и аутентификацию заранее: иначе каждый пакет будет
    # отваливаться по таймауту поодиночке, а причина останется неясной.
    $probe = @($config.software | Where-Object { $_.nasPath } | Select-Object -First 1).nasPath
    $nasAccess = Test-NasAccess -Nas $nas -ProbePath $probe

    if ($nasAccess.Ok -and -not $nasAccess.Caveat) {
        Write-Host "  Проверка доступа: ОК — $($nasAccess.Message)" -ForegroundColor DarkGreen
    }
    elseif ($nasAccess.Ok) {
        Write-Warning "  Проверка доступа: $($nasAccess.Message)"
        $script:Failures.Add("доступ к источнику — $($nasAccess.Message)")
    }
    else {
        Write-Warning "  Проверка доступа НЕ пройдена: $($nasAccess.Message)"
        $script:Failures.Add("доступ к источнику — $($nasAccess.Message)")
        $nas.enabled = $false
        Write-Warning '  Источник отключён: ПО будет ставиться из winget и по прямым ссылкам.'
    }
}

# --- План установки ---------------------------------------------------------

$plannedSoftware = @()
if (-not $SkipSoftware -and $config.PSObject.Properties['software']) {
    $plannedSoftware = @(Get-SoftwareToInstall -Items @($config.software))
}
$plannedCerts = @()
if (-not $SkipCertificates -and $config.PSObject.Properties['certificates'] -and $config.certificates.enabled) {
    $plannedCerts = @($config.certificates.items | Where-Object { Test-ProfileMatch -Item $_ })
}
$plannedTweaks = @()
if (-not $SkipRegistry -and $config.PSObject.Properties['registry']) {
    $plannedTweaks = @($config.registry | Where-Object { Test-ProfileMatch -Item $_ })
}

Write-Step 'План установки'
if ($nas -and $nas.enabled) {
    $source = if ($nas.type -eq 'smb') { $nas.share } else { $nas.baseUrl }
    $auth = if ($script:NasHttpHeaders -or $nas.user) { "учётная запись $($nas.user)" } else { 'без аутентификации' }
    Write-Host ("  Источник дистрибутивов : {0} ({1}, {2})" -f $source, $nas.type.ToUpperInvariant(), $auth)
    $verdict = if (-not $nasAccess) { 'не проверялся' }
        elseif ($nasAccess.Caveat) { "с оговоркой — $($nasAccess.Message)" }
        else { "доступен — $($nasAccess.Message)" }
    Write-Host ("  Проверка доступа       : {0}" -f $verdict)
}
else {
    $why = if ($nasAccess -and -not $nasAccess.Ok) { "недоступен: $($nasAccess.Message)" } else { 'выключен в конфиге' }
    Write-Host ("  Источник дистрибутивов : {0}" -f $why)
    Write-Host '                           ПО — только winget и прямые ссылки'
}
Write-Host ("  Профили                : {0}" -f ($Profiles -join ', '))
Write-Host ("  Программ к установке   : {0}" -f $plannedSoftware.Count)
foreach ($item in $plannedSoftware) { Write-Host "      - $($item.name)" }

$skipped = @($config.software | Where-Object { $n = $_.name; -not ($plannedSoftware | Where-Object { $_.name -eq $n }) })
if ($skipped.Count -gt 0) {
    Write-Host ("  Дополнительные пакеты  : {0}" -f (($skipped | ForEach-Object { $_.name }) -join ', '))
    Write-Host '                           (не ставятся; добавьте профиль или -Include)'
}

Write-Host ("  Сертификатов           : {0}" -f $plannedCerts.Count)
foreach ($item in $plannedCerts) { Write-Host "      - $($item.name) -> $($item.store)" }
Write-Host ("  Правок реестра         : {0}" -f $plannedTweaks.Count)

$officeState = if ($config.PSObject.Properties['office'] -and $config.office.enabled -and -not $SkipOffice) {
    "будет установлен ($($config.office.mode))"
}
else {
    'выключен'
}
Write-Host ("  Microsoft Office       : {0}" -f $officeState)
if (-not $SkipSystem -and $config.PSObject.Properties['system']) {
    Write-Host ("  Системные настройки    : часовой пояс {0}, раскладка {1}, RDP {2}" -f
        $config.system.timeZone,
        $config.system.defaultInputLanguage,
        $(if ($config.system.enableRdp) { 'включить' } else { 'не трогать' }))
}
Write-Host ("  Лог                    : {0}" -f $LogPath)

if (-not $NoPrompt -and [Environment]::UserInteractive) {
    Write-Host ''
    Write-Host '  Enter — продолжить, n — изменить набор ПО, q — выход.'
    $answer = (Read-Host '  Продолжаем?').Trim().ToLowerInvariant()
    if ($answer -eq 'q') {
        Write-Host 'Отменено пользователем.'
        try { Stop-Transcript | Out-Null } catch { Write-Verbose 'Transcript уже остановлен.' }
        exit 0
    }
    if ($answer -eq 'n') {
        $plannedSoftware = @(Select-SoftwareInteractive -Items @($config.software) -Preselected $plannedSoftware)
    }
}

# Сертификаты ставим до ПО: без корневого ЦС может не открыться HTTPS
# внутренних серверов, откуда идут дистрибутивы.
if (-not $SkipCertificates -and $config.PSObject.Properties['certificates'] -and $config.certificates.enabled) {
    Write-Step 'Доверенные сертификаты'
    foreach ($item in $plannedCerts) {
        Write-Host "- $($item.name)"
        Invoke-Safely -Label $item.name -Action { Import-TrustedCertificate -Item $item -Nas $nas }
    }
}

if (-not $SkipSoftware -and $config.PSObject.Properties['software']) {
    Write-Step 'Установка ПО'
    if ($plannedSoftware.Count -eq 0) {
        Write-Host 'Ничего не выбрано — пропускаю установку ПО.'
    }
    foreach ($item in $plannedSoftware) {
        Write-Host "- $($item.name)"
        Invoke-Safely -Label $item.name -Action { Install-Application -Item $item -Nas $nas }
    }
}

if (-not $SkipOffice -and $config.PSObject.Properties['office'] -and $config.office.enabled) {
    Write-Step 'Установка Microsoft Office'
    Invoke-Safely -Label "Office ($($config.office.mode))" -Action { Install-Office -Office $config.office -Nas $nas }
}

if (-not $SkipRegistry -and $config.PSObject.Properties['registry']) {
    Write-Step 'Правки реестра'
    foreach ($tweak in $plannedTweaks) {
        Invoke-Safely -Label $tweak.description -Action { Set-RegistryTweak -Tweak $tweak }
    }
}

if (-not $SkipSystem -and $config.PSObject.Properties['system']) {
    Write-Step 'Системные настройки'
    Set-SystemSetting -Settings $config.system
}

if ($nas -and $nas.enabled -and $nas.type -eq 'smb') {
    Invoke-Safely -Label 'отключение от NAS' -Action { Disconnect-NasShare -Nas $nas }
}

Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Step 'Итог'
if ($script:Failures.Count -eq 0) {
    Write-Host 'Все шаги выполнены успешно.' -ForegroundColor Green
}
else {
    Write-Warning "Не выполнено шагов: $($script:Failures.Count)"
    foreach ($f in $script:Failures) { Write-Host "  - $f" -ForegroundColor Yellow }
}
Write-Host "Лог: $LogPath"

if ($script:RebootRequired -or ($config.system -and $config.system.rebootWhenDone)) {
    Write-Host 'Требуется перезагрузка — через 60 секунд. Отменить: shutdown /a'
    & shutdown.exe /r /t 60 /c 'Завершение настройки рабочей станции'
}

try { Stop-Transcript | Out-Null } catch { Write-Verbose 'Transcript уже остановлен.' }

if ($script:Failures.Count -gt 0) { exit 1 }
exit 0
