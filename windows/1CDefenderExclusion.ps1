#Requires -RunAsAdministrator
# Добавление исключений 1С в Windows Defender
# Запускать от имени администратора. Обходит все профили пользователей,
# поэтому корректно работает и при запуске elevated под другой учёткой.

$added = [System.Collections.Generic.List[string]]::new()

function Add-PathExclusion {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Add-MpPreference -ExclusionPath $Path -ErrorAction SilentlyContinue
        $added.Add("PATH : $Path")
    }
}

function Add-ProcessExclusion {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Add-MpPreference -ExclusionProcess $Path -ErrorAction SilentlyContinue
        $added.Add("PROC : $Path")
    }
}

# --- 1. Профили пользователей: каталоги 1С + файловые базы из ibases.v8i ---
Get-ChildItem -Path "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue |
    ForEach-Object {
        # %APPDATA%\1C и %LOCALAPPDATA%\1C каждого профиля
        Add-PathExclusion (Join-Path $_.FullName 'AppData\Roaming\1C')
        Add-PathExclusion (Join-Path $_.FullName 'AppData\Local\1C')

        # Каталоги файловых баз из списка ИБ
        $v8i = Join-Path $_.FullName 'AppData\Roaming\1C\1CEStart\ibases.v8i'
        if (Test-Path -LiteralPath $v8i) {
            Select-String -Path $v8i -Pattern 'Connect=File="([^"]+)"' | ForEach-Object {
                Add-PathExclusion $_.Matches.Groups[1].Value
            }
        }
    }

# --- 2. Платформа в Program Files (x64 и x86) ---
$pfRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }

foreach ($pf in $pfRoots) {
    Add-PathExclusion (Join-Path $pf '1cv8')
}

# --- 3. Расширения файлов 1С ---
Add-MpPreference -ExclusionExtension '1CD','DT','CF','CFU','LGF','LGP' -ErrorAction SilentlyContinue
$added.Add('EXT  : 1CD, DT, CF, CFU, LGF, LGP')

# --- 4. Процессы платформы (конкретные exe по версиям) ---
$exeNames = '1cv8.exe','1cv8c.exe','1cv8s.exe','ragent.exe','rmngr.exe','rphost.exe'

foreach ($pf in $pfRoots) {
    $root = Join-Path $pf '1cv8'
    if (-not (Test-Path -LiteralPath $root)) { continue }

    Get-ChildItem -Path $root -Directory |
        Where-Object { $_.Name -match '^8\.\d+\.\d+\.\d+$' } |
        ForEach-Object {
            $bin = Join-Path $_.FullName 'bin'
            foreach ($exe in $exeNames) {
                Add-ProcessExclusion (Join-Path $bin $exe)
            }
        }

    # Лаунчер
    Add-ProcessExclusion (Join-Path $root 'common\1cestart.exe')
}

# --- Отчёт ---
if ($added.Count) {
    Write-Host "Добавлены исключения:" -ForegroundColor Green
    $added | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "Ничего не добавлено (пути не найдены)." -ForegroundColor Yellow
}

Write-Host "`nФактическое состояние Defender:" -ForegroundColor Cyan
$mp = Get-MpPreference
[PSCustomObject]@{
    ExclusionPath      = $mp.ExclusionPath -join "; "
    ExclusionExtension = $mp.ExclusionExtension -join "; "
    ExclusionProcess   = $mp.ExclusionProcess -join "; "
} | Format-List
