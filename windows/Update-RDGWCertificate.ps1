#Requires -RunAsAdministrator
# =====================================================================
# Получение / продление сертификата Let's Encrypt через Posh-ACME
# (DNS-плагин Beget) и установка на RD Gateway.
# ВАЖНО: сохраняйте файл в кодировке UTF-8 with BOM,
# иначе русские строки превратятся в кракозябры.
# =====================================================================
# Для планировщика достаточно одного задания раз в сутки: powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\poshacme\Update-RDGWCertificate.ps1 с галкой «Выполнять с наивысшими правами».

$ErrorActionPreference = 'Stop'

# --- Параметры ---
$certNames      = 'rds.vash-profbuh.ru'
$email          = 'gpas@dioservice.ru'
$poshAcmeHome   = 'C:\poshacme'
$credentialFile = Join-Path $poshAcmeHome 'BegetCred.xml'
$eventSource    = 'ACME Cert Management'

$env:POSHACME_HOME = $poshAcmeHome

# --- Журнал событий: регистрируем источник при первом запуске ---
if (-not [System.Diagnostics.EventLog]::SourceExists($eventSource)) {
    New-EventLog -LogName Application -Source $eventSource
}

function Write-ToEventLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Type = 'Information'
    )
    Write-EventLog -LogName Application -Source $eventSource -EventId 1001 -EntryType $Type -Message $Message
    Write-Host "[$Type] $Message"
}

try {
    # --- Рабочий каталог ---
    if (-not (Test-Path $poshAcmeHome)) {
        New-Item -ItemType Directory -Path $poshAcmeHome | Out-Null
    }

    # --- Учётные данные Beget ---
    # Внимание: Export-Clixml шифрует пароль через DPAPI — расшифровать его
    # может ТОЛЬКО тот же пользователь на той же машине. Если скрипт будет
    # выполняться планировщиком от SYSTEM, файл нужно создавать тоже от SYSTEM
    # (например, через psexec -s -i powershell).
    if (-not (Test-Path $credentialFile)) {
        throw "Файл с учётными данными не найден. Сохраните их от имени того же пользователя, под которым выполняется скрипт: `$cred = Get-Credential; `$cred | Export-Clixml -Path '$credentialFile'"
    }
    $begetCred = Import-Clixml -Path $credentialFile
    $pArgs = @{ BegetCredential = $begetCred }

    # --- Модули (TLS 1.2 обязателен для PSGallery на старых системах) ---
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Force | Out-Null
    }
    foreach ($mod in 'Posh-ACME', 'Posh-ACME.Deploy') {
        if (-not (Get-Module -Name $mod -ListAvailable)) {
            Write-ToEventLog "Устанавливаем модуль $mod..."
            Install-Module -Name $mod -Scope AllUsers -Force -Repository PSGallery
        }
        Import-Module $mod
    }

    # --- ACME-сервер ---
    Set-PAServer LE_PROD      # для тестов: Set-PAServer LE_STAGE

    # --- ACME-аккаунт ---
    # Get-PAOrder бросает terminating-ошибку через throw (а не Write-Error),
    # поэтому -ErrorAction SilentlyContinue её не гасит — аккаунт нужно
    # создать/выбрать заранее, иначе на первом запуске скрипт падает здесь.
    $account = Get-PAAccount -List | Where-Object { $_.status -eq 'valid' } | Select-Object -First 1
    if (-not $account) {
        Write-ToEventLog "ACME-аккаунт не найден — создаём новый для $email"
        $account = New-PAAccount -Contact $email -AcceptTOS
    }
    elseif ($account.contact -notcontains "mailto:$email") {
        Set-PAAccount -ID $account.id -Contact $email | Out-Null
    }
    else {
        Set-PAAccount -ID $account.id | Out-Null
    }

    # --- Получение или продление ---
    $order = Get-PAOrder -MainDomain $certNames -ErrorAction SilentlyContinue
    if (-not $order) {
        Write-ToEventLog "Заказ не найден — запрашиваем новый сертификат для $certNames"
        $cert = New-PACertificate $certNames -AcceptTOS -Contact $email -Plugin Beget -PluginArgs $pArgs
        if (-not $cert) { throw "Не удалось получить сертификат для $certNames" }
        Write-ToEventLog "Новый сертификат получен."
    }
    else {
        # Submit-Renewal возвращает объект сертификата только если продление
        # реально выполнено (по умолчанию — за ~30 дней до истечения).
        $cert = Submit-Renewal -MainDomain $certNames
        if (-not $cert) {
            Write-ToEventLog "Сертификат для $certNames ещё действителен — продление не требуется."
            return
        }
        Write-ToEventLog "Сертификат успешно продлён."
    }

    # --- Установка на RD Gateway ---
    # Set-RDGWCertificate идемпотентен: если отпечаток не изменился — ничего не делает.
    $cert | Set-RDGWCertificate -RemoveOldCert
    Write-ToEventLog "Сертификат установлен на RD Gateway. Отпечаток: $($cert.Thumbprint). Действителен до: $($cert.NotAfter)."
}
catch {
    Write-ToEventLog "Ошибка: $($_.Exception.Message)" 'Error'
    throw
}
