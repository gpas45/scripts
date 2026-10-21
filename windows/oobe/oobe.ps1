<#
.SYNOPSIS
    Автоматизация этапа OOBE: скачивает файл ответов и перезапускает OOBE через sysprep.

.DESCRIPTION
    На первом экране OOBE (выбор региона) нажмите Shift+F10 и выполните:

        irm https://raw.githubusercontent.com/gpas45/scripts/main/windows/oobe/oobe.ps1 -OutFile $env:TEMP\oobe.ps1
        powershell -ExecutionPolicy Bypass -File $env:TEMP\oobe.ps1

    или, если файл уже лежит на диске/флешке:

        powershell -ExecutionPolicy Bypass -File .\oobe.ps1

    Вариант «в одну команду»: файл сохранён в UTF-8 с BOM (иначе Windows
    PowerShell 5.1 портит кириллицу), а iex на строке с ведущим BOM падает,
    поэтому BOM надо срезать:

        powershell -c "iex ((irm https://raw.githubusercontent.com/gpas45/scripts/main/windows/oobe/oobe.ps1) -replace '^\uFEFF')"

    Скрипт проверяет, что система действительно находится в OOBE, скачивает файл
    ответов (проход oobeSystem) и пост-установочные файлы, показывает план
    установки и даёт его поправить (адрес раздачи, учётная запись и пароль,
    набор программ, HTTPS/SMB), после чего передаёт файл ответов sysprep с
    ключами /oobe /reboot.

    Человек присутствует только на этом шаге, поэтому все вопросы задаются
    здесь. Дальше всё идёт само: перезагрузка, OOBE без вопросов, автовход,
    пост-установка.

    sysprep запускается БЕЗ /generalize: это намеренно — машина остаётся той же
    (драйверы, активация, SID сохраняются), меняются только настройки OOBE.
    Для захвата эталонного образа нужен отдельный запуск с /generalize.

.PARAMETER AnswerFileUri
    URL файла ответов. По умолчанию — UnattendOOBE.xml из этого репозитория.
    Для серийного развёртывания укажите ссылку на конкретный коммит и сверяйте
    хеш ключом -Sha256 (см. README).

.PARAMETER Sha256
    Ожидаемый SHA256 файла ответов. Если задан, расхождение прерывает работу.
    Посчитать: Get-FileHash .\UnattendOOBE.xml -Algorithm SHA256

.PARAMETER Path
    Куда сохранить скачанный файл ответов.

.PARAMETER PostInstallBaseUri
    Каталог, откуда забираются postinstall.ps1 и postinstall.json. Они кладутся
    в <системный диск>\ProgramData\oobe, чтобы при первом входе файл ответов
    запустил их локально, без обращения в интернет.

.PARAMETER NasType
    http или smb. По умолчанию берётся из postinstall.json (там http, так как
    установка идёт за пределами локальной сети).

.PARAMETER NasBaseUrl
    Адрес HTTPS-раздачи дистрибутивов. Если не задан и скрипт запущен в
    интерактивной консоли, адрес спрашивается с подстановкой значения из
    конфига — так его можно сменить прямо в OOBE.

.PARAMETER NasShare
    UNC-путь к SMB-папке, если выбран -NasType smb.

.PARAMETER NasUser
.PARAMETER NasPassword
    Учётные данные NAS: для SMB — подключение к папке, для HTTPS — базовая
    аутентификация. Пароль сохраняется в
    <системный диск>\ProgramData\oobe\nas.cred с правами только для SYSTEM и
    администраторов, чтобы postinstall.ps1 смог им воспользоваться при первом
    входе.

.PARAMETER NoPrompt
    Не показывать экран плана и ничего не спрашивать: взять всё из конфига и
    ключей командной строки как есть.

.PARAMETER SkipPostInstall
    Не скачивать postinstall.*: файл ответов тогда возьмёт скрипт из интернета.

.PARAMETER Force
    Продолжать, даже если проверка «мы в OOBE» не дала однозначного ответа.

.NOTES
    Источник: https://www.outsidethebox.ms/22491/
    Детектирование OOBE: https://oofhours.com/2023/09/15/detecting-when-you-are-in-oobe/
    Запуск скриптов из интернета небезопасен: содержимое по ссылке может быть
    изменено кем угодно, а выполняется оно в OOBE с правами SYSTEM.
#>
[CmdletBinding()]
param(
    [string]$AnswerFileUri = 'https://raw.githubusercontent.com/gpas45/scripts/main/windows/oobe/UnattendOOBE.xml',
    [string]$Sha256,
    [string]$Path = (Join-Path -Path $env:TEMP -ChildPath 'UnattendOOBE.xml'),
    [string]$PostInstallBaseUri = 'https://raw.githubusercontent.com/gpas45/scripts/main/windows/oobe',
    [ValidateSet('http', 'smb')]
    [string]$NasType,
    [string]$NasBaseUrl,
    [string]$NasShare,
    [string]$NasUser,
    [string]$NasPassword,
    [switch]$NoPrompt,
    [switch]$SkipPostInstall,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --- Экран плана установки ---------------------------------------------------

function Read-Secret {
    param([string]$Prompt)
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    if (-not $secure -or $secure.Length -eq 0) { return $null }
    return $secure
}

function ConvertTo-Secret {
    param([string]$Plain)
    if ([string]::IsNullOrEmpty($Plain)) { return $null }
    # Посимвольно, а не ConvertTo-SecureString -AsPlainText: пароль приходит
    # из ключа командной строки, и нам нужен SecureString без запрещённого
    # правилами преобразования открытого текста.
    $secure = New-Object Security.SecureString
    foreach ($char in $Plain.ToCharArray()) { $secure.AppendChar($char) }
    $secure.MakeReadOnly()
    return $secure
}

function ConvertTo-PlainText {
    param([Security.SecureString]$Secure)
    if (-not $Secure) { return $null }
    # Разворачиваем только там, где открытый текст неизбежен: аргумент net use,
    # заголовок Basic и файл nas.cred, который читает postinstall.ps1.
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Test-SourceAccess {
    param(
        [string]$Type,
        [string]$BaseUrl,
        [string]$Share,
        [PSCredential]$Credential,
        [string]$ProbePath
    )
    $result = @{ Ok = $false; Caveat = $false; Message = '' }

    $account = $null
    $secret = $null
    if ($Credential) {
        $account = $Credential.UserName
        $secret = $Credential.GetNetworkCredential().Password
    }

    if ($Type -eq 'smb') {
        $mapped = $false
        try {
            if ($account) {
                & net.exe use $Share $secret /user:$account 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    $result.Message = "подключиться к $Share не удалось (net use код $LASTEXITCODE)"
                    return $result
                }
                $mapped = $true
            }
            if (-not (Test-Path -LiteralPath $Share)) {
                $result.Message = "папка $Share недоступна"
                return $result
            }
            $result.Ok = $true
            $result.Message = "папка $Share доступна"
            if ($ProbePath) {
                $probe = Join-Path -Path $Share -ChildPath ($ProbePath -replace '/', '\')
                if (-not (Test-Path -LiteralPath $probe)) {
                    $result.Caveat = $true
                    $result.Message = "папка доступна, но файла $ProbePath в ней нет"
                }
            }
        }
        catch {
            $result.Message = "$Share — $($_.Exception.Message)"
        }
        finally {
            if ($mapped) { & net.exe use $Share /delete /y 2>&1 | Out-Null }
        }
        return $result
    }

    $base = $BaseUrl.TrimEnd('/')
    $url = if ($ProbePath) { '{0}/{1}' -f $base, ($ProbePath -replace '\\', '/') } else { "$base/" }

    $headers = $null
    if ($account -and $secret) {
        $token = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(('{0}:{1}' -f $account, $secret)))
        $headers = @{ Authorization = "Basic $token" }
    }

    foreach ($method in @('Head', 'Get')) {
        $request = @{ Uri = $url; Method = $method; UseBasicParsing = $true; TimeoutSec = 30 }
        if ($headers) { $request['Headers'] = $headers }
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
                $result.Message = "401 — аутентификация не пройдена, проверьте учётную запись и пароль"
            }
            elseif ($status -eq 403) {
                $result.Message = "403 — доступ запрещён"
            }
            elseif ($status -eq 404) {
                $result.Ok = $true
                $result.Caveat = $true
                $result.Message = "доступ есть, аутентификация пройдена, но $url отдаёт 404 — проверьте раскладку файлов"
            }
            else {
                $result.Message = "HTTP $status от $url"
            }
            return $result
        }
    }

    if (-not $result.Message) { $result.Message = 'проверить не удалось' }
    return $result
}

function Select-PlanSoftware {
    param(
        $Software,
        [string[]]$Chosen
    )
    Write-Host ''
    for ($i = 0; $i -lt $Software.Count; $i++) {
        $mark = if ($Chosen -contains $Software[$i].name) { '*' } else { ' ' }
        Write-Host ('    [{0}] {1,2}. {2}' -f $mark, ($i + 1), $Software[$i].name)
    }
    Write-Host '    * — входит в набор по умолчанию. Enter — оставить как есть.'
    Write-Host '    Номера через запятую (1,3,5), диапазоны (1-4), all — всё, none — ничего.'

    $answer = (Read-Host '    Выбор').Trim()
    if ([string]::IsNullOrEmpty($answer)) { return $Chosen }
    if ($answer -eq 'all') { return @($Software | ForEach-Object { $_.name }) }
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
            Write-Warning "    не разобрал «$token» — пропускаю."
        }
    }
    $result = foreach ($n in ($indexes | Sort-Object -Unique)) {
        if ($n -ge 1 -and $n -le $Software.Count) { $Software[$n - 1].name }
        else { Write-Warning "    номера $n в списке нет — пропускаю." }
    }
    return @($result)
}

function Show-InstallPlan {
    param([string]$ConfigPath)

    $plan = @{
        Nas       = @{}
        Office    = $null
        Include   = $null
        Password  = (ConvertTo-Secret -Plain $NasPassword)
        Cancelled = $false
    }

    $config = $null
    if (Test-Path -LiteralPath $ConfigPath) {
        try { $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { Write-Warning "Не удалось прочитать $ConfigPath — $($_.Exception.Message)" }
    }
    if (-not $config) {
        Write-Warning 'Конфигурация недоступна — показать план нельзя, применяю только ключи командной строки.'
        if ($NasType) { $plan.Nas['type'] = $NasType }
        if ($NasBaseUrl) { $plan.Nas['baseUrl'] = $NasBaseUrl }
        if ($NasShare) { $plan.Nas['share'] = $NasShare }
        if ($NasUser) { $plan.Nas['user'] = $NasUser }
        return $plan
    }

    # Исходные значения: конфиг, поверх — ключи командной строки.
    $type = if ($NasType) { $NasType } else { $config.nas.type }
    $baseUrl = if ($NasBaseUrl) { $NasBaseUrl } else { $config.nas.baseUrl }
    $share = if ($NasShare) { $NasShare } else { $config.nas.share }
    $user = if ($NasUser) { $NasUser } else { $config.nas.user }

    if ($NoPrompt -or -not [Environment]::UserInteractive) {
        if ($NasType) { $plan.Nas['type'] = $NasType }
        if ($NasBaseUrl) { $plan.Nas['baseUrl'] = $NasBaseUrl }
        if ($NasShare) { $plan.Nas['share'] = $NasShare }
        if ($NasUser) { $plan.Nas['user'] = $NasUser }
        return $plan
    }

    $software = @($config.software)
    $chosen = @($software | Where-Object { -not $_.profiles -or ($_.profiles -contains 'base') } |
        ForEach-Object { $_.name })
    $probe = @($software | Where-Object { $_.nasPath } | Select-Object -First 1).nasPath

    # --- Опрос: вид подключения, адрес, учётные данные, проверка -------------
    while ($true) {
        Write-Host ''
        Write-Host 'Откуда брать дистрибутивы:' -ForegroundColor Cyan
        Write-Host '  1 — HTTPS, из интернета через обратный прокси'
        Write-Host '  2 — SMB, внутри локальной сети напрямую с NAS'
        $suggested = if ($type -eq 'smb') { '2' } else { '1' }
        $answer = (Read-Host "  Подключение [$suggested]").Trim()
        if (-not $answer) { $answer = $suggested }
        $type = if ($answer -eq '2') { 'smb' } else { 'http' }

        if ($type -eq 'smb') {
            $value = (Read-Host "  UNC-путь [$share]").Trim()
            if ($value) { $share = $value }
        }
        else {
            $value = (Read-Host "  Адрес раздачи [$baseUrl]").Trim()
            if ($value) { $baseUrl = $value }
        }

        $value = (Read-Host "  Учётная запись [$user]").Trim()
        if ($value) { $user = $value }
        $secret = Read-Secret -Prompt '  Пароль'
        if ($secret) { $plan.Password = $secret }

        Write-Host '  Проверяю доступ…'
        $credential = $null
        if ($user -and $plan.Password) {
            $credential = New-Object System.Management.Automation.PSCredential -ArgumentList $user, $plan.Password
        }
        $access = Test-SourceAccess -Type $type -BaseUrl $baseUrl -Share $share `
            -Credential $credential -ProbePath $probe

        if ($access.Ok -and -not $access.Caveat) {
            Write-Host "  Доступ есть: $($access.Message)" -ForegroundColor DarkGreen
            break
        }
        if ($access.Ok) {
            Write-Host "  Доступ есть, но с оговоркой: $($access.Message)" -ForegroundColor DarkYellow
        }
        else {
            Write-Host "  Доступа нет: $($access.Message)" -ForegroundColor Red
            Write-Host '  Без него после перезагрузки дистрибутивы брать будет неоткуда:'
            Write-Host '  встанут только winget-пакеты, правки реестра и системные настройки.'
        }
        $again = (Read-Host '  Ввести заново? [Y/n]').Trim().ToLowerInvariant()
        if ($again -eq 'n') { break }
    }

    # --- Microsoft Office ------------------------------------------------------
    $officeEnabled = [bool]$config.office.enabled
    $officeMode = $config.office.mode
    $suggested = if ($officeEnabled) { 'Y/n' } else { 'y/N' }
    Write-Host ''
    $answer = (Read-Host "  Ставить Microsoft Office, режим ${officeMode}? [$suggested]").Trim().ToLowerInvariant()
    if ($answer -eq 'y') { $officeEnabled = $true }
    elseif ($answer -eq 'n') { $officeEnabled = $false }

    # --- План -----------------------------------------------------------------
    $source = if ($type -eq 'smb') { $share } else { $baseUrl }
    $extra = @($software | Where-Object { $chosen -notcontains $_.name } | ForEach-Object { $_.name })
    $certs = @()
    if ($config.PSObject.Properties['certificates'] -and $config.certificates.enabled) {
        $certs = @($config.certificates.items | ForEach-Object { $_.name })
    }

    Write-Host ''
    Write-Host '================ План установки ================' -ForegroundColor Cyan
    Write-Host ("  Источник ПО      : {0} ({1})" -f $source, $type.ToUpperInvariant())
    Write-Host ("  Учётная запись   : {0}" -f $(if ($user) { $user } else { '— (без аутентификации)' }))
    Write-Host ("  Программы        : {0}" -f $chosen.Count)
    foreach ($name in $chosen) { Write-Host "      - $name" }
    if ($extra.Count -gt 0) {
        Write-Host ("  Дополнительно    : {0}" -f ($extra -join ', '))
    }
    if ($certs.Count -gt 0) {
        Write-Host ("  Сертификаты      : {0}" -f ($certs -join ', '))
    }
    Write-Host ("  Правки реестра   : {0}" -f @($config.registry).Count)
    Write-Host ("  Office           : {0}" -f $(if ($officeEnabled) { "будет установлен ($officeMode)" } else { 'не ставим' }))
    Write-Host ("  Часовой пояс     : {0}" -f $config.system.timeZone)
    Write-Host '  Администратор    : Admin (пароль из файла ответов — смените после установки)'
    Write-Host '==============================================='

    $answer = (Read-Host '  Enter — начать, n — изменить набор программ, q — отмена').Trim().ToLowerInvariant()
    if ($answer -eq 'q') {
        $plan.Cancelled = $true
        return $plan
    }
    if ($answer -eq 'n') {
        $chosen = @(Select-PlanSoftware -Software $software -Chosen $chosen)
    }

    if ($officeEnabled -ne [bool]$config.office.enabled) {
        $plan.Office = @{ enabled = $officeEnabled }
    }
    if ($type -ne $config.nas.type) { $plan.Nas['type'] = $type }
    if ($baseUrl -ne $config.nas.baseUrl) { $plan.Nas['baseUrl'] = $baseUrl }
    if ($share -ne $config.nas.share) { $plan.Nas['share'] = $share }
    if ($user -ne $config.nas.user) { $plan.Nas['user'] = $user }

    $default = @($software | Where-Object { -not $_.profiles -or ($_.profiles -contains 'base') } |
        ForEach-Object { $_.name })
    if (@(Compare-Object -ReferenceObject $default -DifferenceObject $chosen -SyncWindow 0).Count -gt 0) {
        $plan.Include = $chosen
    }
    return $plan
}

# --- 1. Проверка: находимся ли мы на этапе OOBE ------------------------------
if (-not ('Api.Kernel32' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Api
{
    public class Kernel32
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern int OOBEComplete(ref int bIsOOBEComplete);
    }
}
'@
}

# OOBEComplete — это Win32 BOOL, а не HRESULT: ненулевой возврат означает, что
# вызов УДАЛСЯ, а ответ лежит в параметре. Ноль — вызов не удался.
$isOOBEComplete = 0
$callSucceeded = [Api.Kernel32]::OOBEComplete([ref] $isOOBEComplete)

# Независимые от API признаки: пока идёт установка, эти значения в реестре
# равны 1, а учётная запись defaultuser0 существует только на этапе OOBE.
# Нужны, чтобы не запустить sysprep на рабочей машине и, наоборот, не встать
# посреди OOBE, если API ответит не то.
$looksLikeOobe = ($env:USERNAME -eq 'defaultuser0')
foreach ($name in @('OOBEInProgress', 'SystemSetupInProgress')) {
    $value = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup' -Name $name -ErrorAction SilentlyContinue).$name
    if ($value) { $looksLikeOobe = $true }
}

if ($callSucceeded -ne 0 -and $isOOBEComplete -ne 0 -and -not $looksLikeOobe) {
    Write-Host 'OOBE уже завершён — делать нечего.'
    exit 0
}
if ($callSucceeded -ne 0 -and $isOOBEComplete -ne 0) {
    Write-Warning 'OOBEComplete считает OOBE завершённым, но система говорит обратное — продолжаю.'
}
if ($callSucceeded -eq 0) {
    if ($looksLikeOobe) {
        Write-Warning 'OOBEComplete не отработала, но по состоянию системы установка ещё идёт — продолжаю.'
    }
    else {
        $message = 'Определить этап установки не удалось: OOBEComplete не отработала, признаков OOBE в системе нет.'
        if (-not $Force) {
            throw "$message Повторите с -Force, если уверены, что это OOBE."
        }
        Write-Warning "$message Продолжаем, так как задан -Force."
    }
}

# --- 2. Скачивание и проверка файла ответов ----------------------------------
# В OOBE по умолчанию может быть выключен TLS 1.2 — включаем явно.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch {
    Write-Warning "Не удалось включить TLS 1.2: $($_.Exception.Message)"
}

Write-Host "Скачиваю файл ответов: $AnswerFileUri"
# Invoke-WebRequest + .Content, а не (Invoke-RestMethod).OuterXml: последний
# отдаёт XmlDocument только при «правильном» Content-Type, а raw-раздачи
# присылают text/plain (и могут вместо файла вернуть страницу с ошибкой).
$answerXml = (Invoke-WebRequest -Uri $AnswerFileUri -UseBasicParsing).Content
if ($answerXml -is [byte[]]) {
    $answerXml = [Text.Encoding]::UTF8.GetString($answerXml)
}

if ([string]::IsNullOrWhiteSpace($answerXml)) {
    throw "По адресу $AnswerFileUri получен пустой ответ."
}

try {
    $parsed = [xml]$answerXml
}
catch {
    throw "Скачанные данные не являются корректным XML: $($_.Exception.Message)"
}

if ($parsed.DocumentElement.LocalName -ne 'unattend') {
    throw "Это не файл ответов: корневой элемент <$($parsed.DocumentElement.LocalName)>, ожидался <unattend>."
}
if (-not ($parsed.unattend.settings | Where-Object { $_.pass -eq 'oobeSystem' })) {
    throw 'В файле ответов нет прохода oobeSystem — sysprep /oobe ничего не применит.'
}

# UTF-8 без BOM: объявленная в XML кодировка совпадает с фактической.
[IO.File]::WriteAllText($Path, $answerXml, (New-Object Text.UTF8Encoding $false))

if ($Sha256) {
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -ne $Sha256.Replace('-', '').Trim()) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        throw "SHA256 файла ответов не совпал. Ожидался $Sha256, получен $actual."
    }
    Write-Host 'SHA256 файла ответов совпал.'
}

# --- 3. Поиск sysprep -------------------------------------------------------
$sysprep = Join-Path -Path $env:SystemRoot -ChildPath 'System32\Sysprep\sysprep.exe'
if (-not (Test-Path -LiteralPath $sysprep)) {
    # Запуск из WinPE: ищем установленную Windows по буквам дисков C..Z.
    # (Get-Volume здесь не используется: в WinPE модуля Storage может не быть,
    # а у части томов DriveLetter пустой.)
    $sysprep = 67..90 |
        ForEach-Object { '{0}:\Windows\System32\Sysprep\sysprep.exe' -f [char]$_ } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
}
if (-not $sysprep) {
    throw 'sysprep.exe не найден ни на одном томе.'
}

# --- 4. Подготовка пост-установочных файлов ---------------------------------
# Кладём их на системный диск заранее: FirstLogonCommands в файле ответов
# запустит локальную копию, и первый вход не будет зависеть от интернета.
if (-not $SkipPostInstall) {
    $windowsDrive = [IO.Path]::GetPathRoot($sysprep)
    $oobeDir = Join-Path -Path $windowsDrive -ChildPath 'ProgramData\oobe'
    try {
        New-Item -ItemType Directory -Force -Path $oobeDir | Out-Null
        foreach ($name in @('postinstall.ps1', 'postinstall.json')) {
            $target = Join-Path -Path $oobeDir -ChildPath $name
            Invoke-WebRequest -Uri ('{0}/{1}' -f $PostInstallBaseUri.TrimEnd('/'), $name) `
                -OutFile $target -UseBasicParsing
            Write-Host "  положил $target"
        }

        # Экран плана: человек присутствует только здесь, поэтому все вопросы
        # задаются на этом шаге. Результат пишется в postinstall.override.json
        # рядом с конфигом — postinstall.ps1 подхватит его при первом входе,
        # а сам postinstall.json править не нужно.
        $staged = Join-Path -Path $oobeDir -ChildPath 'postinstall.json'
        $plan = Show-InstallPlan -ConfigPath $staged

        if ($plan.Cancelled) {
            Write-Host 'Отменено — sysprep не запускался, система осталась в OOBE.'
            exit 0
        }

        $override = @{}
        if ($plan.Nas.Count -gt 0) { $override['nas'] = $plan.Nas }
        if ($plan.Office) { $override['office'] = $plan.Office }
        if ($plan.Include) { $override['include'] = $plan.Include }

        if ($override.Count -gt 0) {
            $overrideFile = Join-Path -Path $oobeDir -ChildPath 'postinstall.override.json'
            $override | ConvertTo-Json -Depth 4 |
                Set-Content -LiteralPath $overrideFile -Encoding UTF8
            Write-Host "  положил $overrideFile"
        }

        if ($plan.Password) {
            $credFile = Join-Path -Path $oobeDir -ChildPath 'nas.cred'
            [IO.File]::WriteAllText($credFile, (ConvertTo-PlainText -Secure $plan.Password), (New-Object Text.UTF8Encoding $false))
            & icacls.exe $credFile /inheritance:r /grant:r 'SYSTEM:(R)' '*S-1-5-32-544:(R)' | Out-Null
            Write-Host "  положил $credFile (доступ: SYSTEM и администраторы)"
        }
    }
    catch {
        Write-Warning "Не удалось подготовить postinstall.*: $($_.Exception.Message)"
        Write-Warning 'При первом входе скрипт будет скачан из интернета (см. FirstLogonCommands).'
    }
}

# --- 5. Запуск sysprep -------------------------------------------------------
$account = ($parsed.unattend.settings |
    Where-Object { $_.pass -eq 'oobeSystem' }).component.UserAccounts.LocalAccounts.LocalAccount.Name
if ($account) {
    Write-Host "Будет создана локальная учётная запись администратора: $account" -ForegroundColor DarkGreen
    Write-Host 'Смените пароль сразу после первого входа.' -ForegroundColor DarkYellow
}

Write-Host "Запускаю $sysprep /oobe /reboot /unattend:$Path"
& $sysprep '/oobe' '/reboot' "/unattend:$Path"
exit $LASTEXITCODE
