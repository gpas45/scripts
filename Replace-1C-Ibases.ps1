# Скрипт для автоматизации замены файла со списком баз 1С для всех пользователей группы 1c_all

#requires -Version 5.1
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Настройки ---
$adminUser = 'Администратор'
$srcFile   = "C:\Users\$adminUser\AppData\Roaming\1C\1CEStart\ibases.v8i"
$storeDir  = 'C:\_DSL\базы'
$stamp     = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$groupName = '1C_all'

# --- Проверка исходного файла ---
if (-not (Test-Path -LiteralPath $srcFile)) {
    throw "Не найден исходный файл: $srcFile"
}

# --- Создание папки хранения бэкапов ---
if (-not (Test-Path -LiteralPath $storeDir)) {
    New-Item -ItemType Directory -Path $storeDir -Force | Out-Null
}

# --- Бэкап файла Администратора ---
$storeFile = Join-Path $storeDir "${stamp}_ibases.v8i"
Copy-Item -LiteralPath $srcFile -Destination $storeFile -Force
Write-Host "Сохранён бэкап Администратора: $storeFile`n"

# --- Получение членов группы 1C_all ---
try {
    $groupMembers = @(
        Get-LocalGroupMember -Group $groupName |
        Where-Object { $_.ObjectClass -eq 'Пользователь' -or $_.ObjectClass -eq 'User' } |
        ForEach-Object {
            ($_.Name -split '\\')[-1].Trim().ToLower()
        }
    )
} catch {
    throw "Не удалось получить членов группы '$groupName': $($_.Exception.Message)"
}

# --- Исключения ---
$exclude = @('All Users','Default','Default User','DefaultAppPool','Public',$adminUser)

# --- Список локальных пользователей (по Get-LocalUser) ---
$allUsers = @(
    Get-LocalUser |
    Where-Object {
        $_.Enabled -eq $true -and
        $exclude -notcontains $_.Name
    } |
    Select-Object -ExpandProperty Name |
    Sort-Object
)

if ($allUsers.Count -eq 0) {
    Write-Host "Нет пользователей для обработки."
    exit 0
}

# --- Вывод списка с отметкой членства в группе ---
Write-Host ("=" * 55)
Write-Host ("{0,-4} {1,-25} {2}" -f "№", "Пользователь", "Группа $groupName")
Write-Host ("=" * 55)

for ($i = 0; $i -lt $allUsers.Count; $i++) {
    $u      = $allUsers[$i]
    $inGrp  = $groupMembers -contains $u.ToLower()
    $marker = if ($inGrp) { '[+]' } else { '[ ]' }
    "{0,-4} {1,-25} {2}" -f ($i + 1), $u, $marker | Write-Host
}

Write-Host ("=" * 55)
Write-Host "[+] = входит в группу $groupName (будет скопирован файл)`n"

# --- Выбор пользователей ---
Write-Host "Кому выполнить замену ibases.v8i?"
Write-Host "  A - всем, кто входит в группу $groupName"
Write-Host "  N - выбрать вручную по номерам (например: 1,3,5 или 2-6)"
Write-Host "  Q - выход"
$mode = (Read-Host "Ваш выбор (A/N/Q)").Trim().ToUpper()

if ($mode -eq 'Q') {
    Write-Host "Отменено."
    exit 0
}

# --- Функция разбора номеров ---
function Resolve-Selection {
    param(
        [string]  $Raw,
        [string[]]$Items
    )
    $numbers = @()
    $parts   = $Raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

    foreach ($p in $parts) {
        if ($p -match '^\d+\s*-\s*\d+$') {
            $a = [int]($p -split '\s*-\s*')[0]
            $b = [int]($p -split '\s*-\s*')[1]
            if ($a -gt $b) { $a, $b = $b, $a }
            $numbers += $a..$b
        } elseif ($p -match '^\d+$') {
            $numbers += [int]$p
        }
    }

    @($numbers | Sort-Object -Unique | ForEach-Object {
        if ($_ -ge 1 -and $_ -le $Items.Count) { $Items[$_ - 1] }
    })
}

# --- Формирование списка целей ---
$targets = @()

switch ($mode) {
    'A' {
        $targets = @($allUsers | Where-Object { $groupMembers -contains $_.ToLower() })
        if ($targets.Count -eq 0) {
            Write-Host "Нет пользователей в группе $groupName."
            exit 0
        }
    }
    'N' {
        $raw = (Read-Host "Введите номера").Trim()
        if (-not $raw) { throw "Ввод пустой." }
        $targets = @(Resolve-Selection -Raw $raw -Items $allUsers)
        if ($targets.Count -eq 0) {
            Write-Host "Никто не выбран — выходим."
            exit 0
        }
    }
    default { throw "Неверный выбор. Нужно A, N или Q." }
}

# --- Предпросмотр ---
Write-Host "`nЗамена будет выполнена для:"
foreach ($u in $targets) {
    $inGrp  = $groupMembers -contains $u.ToLower()
    $marker = if ($inGrp) { '[+]' } else { '[!] НЕ в группе' }
    Write-Host "  $marker $u"
}

$confirm = (Read-Host "`nПродолжить? (Y/N)").Trim().ToUpper()
if ($confirm -ne 'Y') {
    Write-Host "Отменено."
    exit 0
}

# --- Копирование ---
$ok = 0; $fail = 0

foreach ($u in $targets) {
    try {
        $destDir  = "C:\Users\$u\AppData\Roaming\1C\1CEStart"
        $destFile = Join-Path $destDir 'ibases.v8i'

        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        # Бэкап старого файла пользователя
        if (Test-Path -LiteralPath $destFile) {
            $userBackup = Join-Path $destDir "${stamp}_ibases.v8i"
            Copy-Item -LiteralPath $destFile -Destination $userBackup -Force
            Write-Host "  Бэкап: $userBackup"
        }

        # Копирование нового файла
        Copy-Item -LiteralPath $srcFile -Destination $destFile -Force
        Write-Host "  OK: $u"
        $ok++
    } catch {
        Write-Host "  FAIL: $u -> $($_.Exception.Message)"
        $fail++
    }
}

Write-Host "`n$('=' * 55)"
Write-Host "Готово. Успешно: $ok | Ошибок: $fail"
Write-Host "Бэкап Администратора: $storeFile"
