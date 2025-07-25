# Оптимизированный скрипт для добавления исключений 1С в Windows Defender

# Функция для безопасного добавления исключения (проверяет путь)
function Add-ExclusionIfExists {
    param([string]$Path)
    if (Test-Path -Path $Path) {
        Add-MpPreference -ExclusionPath $Path -ErrorAction SilentlyContinue
    }
}

# 1. Исключения для файловых баз из ibases.v8i
$ibasesPath = Join-Path -Path $env:APPDATA -ChildPath '1C\1CEStart\ibases.v8i'
if (Test-Path -Path $ibasesPath) {
    Select-String -Path $ibasesPath -Pattern '^Connect=File="([^"]+)"' | ForEach-Object {
        Add-ExclusionIfExists -Path $_.Matches.Groups[1].Value
    }
}

# 2. Стандартные пути 1С
@(
    Join-Path -Path $env:APPDATA -ChildPath '1C'
    Join-Path -Path $env:LOCALAPPDATA -ChildPath '1C'
    Join-Path -Path $env:PROGRAMFILES -ChildPath '1cv8'
    Join-Path -Path ${env:PROGRAMFILES(x86)} -ChildPath '1cv8'
) | ForEach-Object { Add-ExclusionIfExists -Path $_ }

# 3. Расширения файлов
Add-MpPreference -ExclusionExtension '1CD', 'DT', 'CF' -ErrorAction SilentlyContinue

# 4. Исключения процессов (bin и ExtCompT)
$1cPaths = @(
    Join-Path -Path $env:PROGRAMFILES -ChildPath '1cv8'
    Join-Path -Path ${env:PROGRAMFILES(x86)} -ChildPath '1cv8'
)

$1cPaths | Where-Object { Test-Path -Path $_ } | ForEach-Object {
    Get-ChildItem -Path $_ -Directory | Where-Object { $_.Name -match '^8\.3\.\d{2}\.\d{4}$' } | ForEach-Object {
        $binPath = Join-Path -Path $_.FullName -ChildPath "bin\*"
        Add-MpPreference -ExclusionProcess $binPath -ErrorAction SilentlyContinue
    }
}

# Исключение для ExtCompT
$extCompPath = Join-Path -Path $env:APPDATA -ChildPath '1C\1cv8\ExtCompT\*'
Add-ExclusionIfExists -Path $extCompPath
