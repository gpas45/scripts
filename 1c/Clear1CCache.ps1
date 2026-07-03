<#
.SYNOPSIS
    Очистка кэша клиента 1С:Предприятие 8 (тонкий/толстый клиент).

.DESCRIPTION
    Закрывает запущенные процессы 1С и удаляет кэш из
    %APPDATA%\1C\1cv8 и %LOCALAPPDATA%\1C\1cv8.
    Список информационных баз (ibases.v8i в каталоге 1CEStart) НЕ затрагивается.

.PARAMETER Base
    Часть имени/GUID папки конкретной базы. Если не задан — чистится весь кэш.

.PARAMETER Force
    Не спрашивать подтверждение перед закрытием процессов 1С.

.EXAMPLE
    .\Clear-1CCache.ps1
    Чистит весь кэш с подтверждением закрытия процессов.

.EXAMPLE
    .\Clear-1CCache.ps1 -Force
    Чистит весь кэш без вопросов (для автозапуска).

.EXAMPLE
    .\Clear-1CCache.ps1 -Base "a1b2c3"
    Чистит только папки, в имени которых встречается "a1b2c3".
#>

[CmdletBinding()]
param(
    [string]$Base,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Процессы клиента/сервера 1С
$procNames = @('1cv8', '1cv8c', '1cv8s')

$running = Get-Process -Name $procNames -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "Запущены процессы 1С:" -ForegroundColor Yellow
    $running | Format-Table Id, ProcessName, StartTime -AutoSize | Out-String | Write-Host
    if (-not $Force) {
        $ans = Read-Host "Закрыть их и продолжить? (y/N)"
        if ($ans -notmatch '^[YyДд]') { Write-Host "Отменено."; exit 1 }
    }
    $running | Stop-Process -Force
    Start-Sleep -Seconds 1
    Write-Host "Процессы 1С закрыты." -ForegroundColor Green
}

# Каталоги кэша
$roots = @(
    (Join-Path $env:APPDATA      '1C\1cv8'),
    (Join-Path $env:LOCALAPPDATA '1C\1cv8')
)

$freed   = 0
$removed = 0

foreach ($root in $roots) {
    if (-not (Test-Path $root)) { continue }
    Write-Host "`nОбработка: $root" -ForegroundColor Cyan

    $items = Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue
    if ($Base) {
        $items = $items | Where-Object { $_.Name -like "*$Base*" }
    }

    foreach ($item in $items) {
        try {
            $size = 0
            if ($item.PSIsContainer) {
                $size = (Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue |
                         Measure-Object -Property Length -Sum).Sum
            } else {
                $size = $item.Length
            }
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            if ($size) { $freed += $size }
            $removed++
            Write-Host "  удалено: $($item.Name)" -ForegroundColor DarkGray
        }
        catch {
            Write-Warning "  не удалось удалить $($item.Name): $($_.Exception.Message)"
        }
    }
}

$mb = [math]::Round($freed / 1MB, 1)
Write-Host "`nГотово. Удалено объектов: $removed, освобождено ~$mb МБ." -ForegroundColor Green
Write-Host "Кэш пересоздастся при следующем запуске 1С." -ForegroundColor Gray
