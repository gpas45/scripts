<#
.SYNOPSIS
    Проверяет, пройдёт ли sysprep /generalize, и называет причину отказа.

.DESCRIPTION
    «Sysprep не удалось проверить установку Windows» — это одно сообщение на
    десяток разных причин, настоящая лежит в
    %WINDIR%\System32\Sysprep\Panther\setupact.log. Скрипт достаёт её оттуда
    и дополнительно проверяет то, на чём generalize спотыкается чаще всего.

        .\Test-SysprepReady.ps1
        .\Test-SysprepReady.ps1 -Fix

    Самая частая причина — пакет приложения, установленный одному
    пользователю, но не внесённый в образ (или наоборот). Так получается,
    когда Магазин успел обновить встроенное приложение для текущего
    пользователя, либо когда что-то поставили через Add-AppxPackage без
    Add-AppxProvisionedPackage. С -Fix такие пакеты снимаются у всех
    пользователей — после этого generalize проходит.

    Запускать от администратора. Ничего не меняет без -Fix.

.PARAMETER Fix
    Снять найденные несовпадающие пакеты приложений у всех пользователей.
    Каждый пакет показывается перед удалением; -Force убирает подтверждение.

.PARAMETER Force
    Не спрашивать подтверждения при -Fix.

.PARAMETER LogPath
    Путь к setupact.log прошлого прогона sysprep. По умолчанию
    %WINDIR%\System32\Sysprep\Panther\setupact.log.

.NOTES
    Для обычного переразвёртывания рабочей станции generalize не нужен:
    oobe.ps1 запускает sysprep /oobe без него, сохраняя SID, драйверы и
    активацию. Generalize нужен для эталонного образа.
#>
[CmdletBinding()]
param(
    [switch]$Fix,
    [switch]$Force,
    [string]$LogPath = (Join-Path -Path $env:SystemRoot -ChildPath 'System32\Sysprep\Panther\setupact.log')
)

$ErrorActionPreference = 'Stop'
$script:Problems = New-Object System.Collections.Generic.List[string]

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "=== $Text" -ForegroundColor Cyan
}

function Add-Problem {
    param([string]$Text)
    $script:Problems.Add($Text)
    Write-Warning "  [!] $Text"
}

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- 1. Причина из журнала прошлого прогона ----------------------------------

function Show-SysprepLog {
    Write-Step 'Журнал прошлого прогона sysprep'
    if (-not (Test-Path -LiteralPath $LogPath)) {
        Write-Host "  $LogPath не найден — sysprep здесь ещё не запускался."
        return
    }

    $lines = @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)
    # SYSPRP — префикс самого sysprep; остальное пишут соседние компоненты.
    $errors = @($lines | Where-Object {
        $_ -match 'SYSPRP' -and $_ -match 'Error|Failed|was installed for a user|not provisioned|is not supported'
    })
    if (-not $errors) {
        Write-Host '  строк с ошибками нет — либо прогон был успешным, либо журнал от другого запуска.'
        return
    }

    Write-Host "  $LogPath, последние строки с ошибками:"
    foreach ($line in ($errors | Select-Object -Last 20)) {
        Write-Host "    $line"
    }

    # Имя пакета из строки «Package X_1.0.0.0_neutral__abc was installed for
    # a user, but not provisioned for all users» — это и есть то, что чинить.
    $packages = New-Object System.Collections.Generic.List[string]
    foreach ($line in $errors) {
        $match = [regex]::Match($line, 'Package (\S+) was installed for a user')
        if ($match.Success -and -not $packages.Contains($match.Groups[1].Value)) {
            $packages.Add($match.Groups[1].Value)
        }
    }
    if ($packages.Count -gt 0) {
        Add-Problem "журнал называет $($packages.Count) пакет(ов), установленных пользователю, но не внесённых в образ."
    }
}

# --- 2. Пакеты приложений: установлено у пользователя, но не в образе --------

function Get-AppxMismatch {
    Write-Step 'Пакеты приложений'

    $provisioned = @{}
    foreach ($item in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)) {
        # DisplayName у provisioned-пакета — это Name у установленного.
        $provisioned[$item.DisplayName] = $item.Version
    }
    Write-Host "  внесено в образ: $($provisioned.Count)"

    $installed = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
    Write-Host "  установлено у пользователей: $($installed.Count)"

    $mismatch = New-Object System.Collections.Generic.List[object]
    foreach ($package in $installed) {
        # Framework-пакеты и системные компоненты generalize не трогает.
        if ($package.IsFramework) { continue }
        if ($package.SignatureKind -eq 'System') { continue }
        if ($package.NonRemovable) { continue }
        if ($provisioned.ContainsKey($package.Name)) { continue }

        $users = @($package.PackageUserInformation |
            Where-Object { $_.InstallState -eq 'Installed' } |
            ForEach-Object { $_.UserSecurityId.Username })
        $mismatch.Add([pscustomobject]@{
            Name        = $package.Name
            FullName    = $package.PackageFullName
            Version     = $package.Version
            Users       = $users
        })
    }

    if ($mismatch.Count -eq 0) {
        Write-Host '  несовпадений нет.' -ForegroundColor DarkGreen
        return @()
    }

    Add-Problem "$($mismatch.Count) пакет(ов) установлено у пользователя, но не внесено в образ — generalize на этом и останавливается."
    foreach ($item in $mismatch) {
        $who = if ($item.Users) { $item.Users -join ', ' } else { 'пользователь не определён' }
        Write-Host "    - $($item.Name) $($item.Version) ($who)"
    }
    return $mismatch.ToArray()
}

function Repair-AppxMismatch {
    param(
        $Packages,
        [switch]$NoConfirm
    )
    if (-not $Packages -or $Packages.Count -eq 0) { return }

    Write-Step 'Снятие несовпадающих пакетов'
    if (-not $NoConfirm) {
        Write-Host '  Будут сняты у всех пользователей:'
        foreach ($item in $Packages) { Write-Host "    - $($item.FullName)" }
        $answer = (Read-Host '  Продолжить? [y/N]').Trim().ToLowerInvariant()
        if ($answer -ne 'y') {
            Write-Host '  отменено.'
            return
        }
    }

    foreach ($item in $Packages) {
        try {
            Remove-AppxPackage -Package $item.FullName -AllUsers -ErrorAction Stop
            Write-Host "  [ok] снят $($item.Name)" -ForegroundColor DarkGreen
        }
        catch {
            Write-Warning "  [!] $($item.Name) — $($_.Exception.Message)"
        }
    }
}

# --- 3. Остальные известные стопоры ------------------------------------------

function Test-RearmCount {
    Write-Step 'Счётчик rearm активации'
    try {
        $service = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
        $left = $service.RemainingWindowsReArmCount
        Write-Host "  осталось прогонов generalize: $left"
        if ($left -le 0) {
            Add-Problem 'счётчик rearm исчерпан — generalize на этой установке больше не выполнится, нужен новый образ.'
        }
    }
    catch {
        Write-Host "  не удалось прочитать: $($_.Exception.Message)"
    }
}

function Test-SysprepState {
    Write-Step 'Состояние прошлых прогонов'
    $key = 'HKLM:\SYSTEM\Setup\Status\SysprepStatus'
    if (-not (Test-Path -LiteralPath $key)) {
        Write-Host '  раздел состояния отсутствует — sysprep здесь не запускался.'
        return
    }
    $state = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    Write-Host "  CleanupState = $($state.CleanupState), GeneralizationState = $($state.GeneralizationState)"
    if ($null -ne $state.CleanupState -and $state.CleanupState -ne 2) {
        Add-Problem "прошлый прогон не завершился (CleanupState = $($state.CleanupState)); обычно помогает перезагрузка."
    }
}

function Test-PendingReboot {
    Write-Step 'Отложенная перезагрузка'
    $pending = @()
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($key in $keys) {
        if (Test-Path -LiteralPath $key) { $pending += $key }
    }
    $session = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
    if ($session -and $session.PendingFileRenameOperations) { $pending += 'PendingFileRenameOperations' }

    if ($pending) {
        Add-Problem "система ждёт перезагрузки ($($pending -join '; ')) — сначала перезагрузитесь."
    }
    else {
        Write-Host '  не требуется.' -ForegroundColor DarkGreen
    }
}

function Test-Upgraded {
    Write-Step 'Обновление поверх предыдущей версии'
    # На системе, обновлённой поверх (не чистая установка), sysprep не
    # поддерживается — и сообщает об этом тем же самым окном.
    $source = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup' -Name 'SystemSetupInProgress' -ErrorAction SilentlyContinue
    $upgrade = Test-Path -LiteralPath 'HKLM:\SYSTEM\Setup\Upgrade'
    if ($upgrade) {
        Add-Problem 'система обновлена поверх предыдущей версии Windows — sysprep на такой установке не поддерживается.'
    }
    else {
        Write-Host '  следов обновления поверх нет.' -ForegroundColor DarkGreen
    }
    if ($source -and $source.SystemSetupInProgress -ne 0) {
        Add-Problem 'установка Windows ещё не завершена (SystemSetupInProgress <> 0).'
    }
}

# --- Выполнение ---------------------------------------------------------------

if (-not (Test-Elevated)) {
    throw 'Нужны права администратора: запустите PowerShell от имени администратора.'
}

Write-Host 'Проверка готовности к sysprep /generalize' -ForegroundColor Cyan

Show-SysprepLog
$mismatch = Get-AppxMismatch
Test-RearmCount
Test-SysprepState
Test-PendingReboot
Test-Upgraded

if ($Fix) { Repair-AppxMismatch -Packages $mismatch -NoConfirm:$Force }

Write-Step 'Итог'
if ($script:Problems.Count -eq 0) {
    Write-Host '  Препятствий не найдено.' -ForegroundColor Green
    Write-Host '  Если sysprep всё равно отказывается, пришлите строки SYSPRP из'
    Write-Host "  $LogPath"
    exit 0
}

Write-Warning "  Найдено препятствий: $($script:Problems.Count)"
foreach ($problem in $script:Problems) { Write-Host "    - $problem" }
if (-not $Fix -and $mismatch.Count -gt 0) {
    Write-Host ''
    Write-Host '  Снять мешающие пакеты: .\Test-SysprepReady.ps1 -Fix'
}
exit 1
