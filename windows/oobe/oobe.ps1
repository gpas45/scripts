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
    ответов (проход oobeSystem), сохраняет его в UTF-8 без BOM и передаёт sysprep
    с ключами /oobe /reboot. После перезагрузки OOBE проходит без участия человека.

    sysprep запускается БЕЗ /generalize: это намеренно — машина остаётся той же
    (драйверы, активация, SID сохраняются), меняются только настройки OOBE.
    Для захвата эталонного образа нужен отдельный запуск с /generalize.

.PARAMETER AnswerFileUri
    URL файла ответов. По умолчанию — паста, на которую ссылается статья-источник.
    Надёжнее указать raw-ссылку на коммит этого репозитория (см. README).

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
    Ничего не спрашивать: взять адрес раздачи из конфига и ключей как есть.

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
    [string]$AnswerFileUri = 'https://pastebin.com/raw/aiLyKTXQ',
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

$isOOBEComplete = 0
$hr = [Api.Kernel32]::OOBEComplete([ref] $isOOBEComplete)

if ($hr -ne 0) {
    # HRESULT проигнорировать нельзя: иначе при сбое API мы запустим sysprep
    # на рабочей машине и выбросим её в OOBE.
    $message = "OOBEComplete вернула HRESULT 0x{0:X8} — определить этап установки не удалось." -f $hr
    if (-not $Force) {
        throw "$message Повторите с -Force, если уверены, что это OOBE."
    }
    Write-Warning "$message Продолжаем, так как задан -Force."
}
elseif ($isOOBEComplete -ne 0) {
    Write-Host 'OOBE уже завершён — делать нечего.'
    exit 0
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
# отдаёт XmlDocument только при «правильном» Content-Type, а pastebin присылает
# text/plain (и может вместо файла вернуть страницу с ошибкой или капчей).
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

        # Адрес раздачи дистрибутивов. Запись в nas.override.json рядом с
        # конфигом: postinstall.ps1 подхватит её при первом входе, а сам
        # postinstall.json править не нужно.
        $staged = Join-Path -Path $oobeDir -ChildPath 'postinstall.json'
        $nasType = $NasType
        $nasBaseUrl = $NasBaseUrl
        $nasShare = $NasShare

        if (-not $NoPrompt -and -not $nasBaseUrl -and [Environment]::UserInteractive) {
            $current = $null
            if (Test-Path -LiteralPath $staged) {
                try {
                    $current = (Get-Content -LiteralPath $staged -Raw -Encoding UTF8 | ConvertFrom-Json).nas.baseUrl
                }
                catch {
                    Write-Warning "Не удалось прочитать адрес из конфига: $($_.Exception.Message)"
                }
            }
            Write-Host ''
            Write-Host 'Откуда брать дистрибутивы ПО (Enter — оставить как есть):'
            $answer = (Read-Host "  Адрес раздачи [$current]").Trim()
            if ($answer) { $nasBaseUrl = $answer }
        }

        $override = @{}
        if ($nasType) { $override['type'] = $nasType }
        if ($nasBaseUrl) { $override['baseUrl'] = $nasBaseUrl }
        if ($nasShare) { $override['share'] = $nasShare }
        if ($NasUser) { $override['user'] = $NasUser }

        if ($override.Count -gt 0) {
            $overrideFile = Join-Path -Path $oobeDir -ChildPath 'nas.override.json'
            $override | ConvertTo-Json -Depth 3 |
                Set-Content -LiteralPath $overrideFile -Encoding UTF8
            Write-Host "  положил $overrideFile"
            foreach ($key in $override.Keys) { Write-Host "    $key = $($override[$key])" }
        }

        if ($NasPassword) {
            $credFile = Join-Path -Path $oobeDir -ChildPath 'nas.cred'
            [IO.File]::WriteAllText($credFile, $NasPassword, (New-Object Text.UTF8Encoding $false))
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
