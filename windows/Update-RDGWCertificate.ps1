#Requires -RunAsAdministrator
# =====================================================================
# Получение / продление сертификата Let's Encrypt через Posh-ACME
# (DNS-плагин Beget) и установка на RD Gateway.
# ВАЖНО: сохраняйте файл в кодировке UTF-8 with BOM,
# иначе русские строки превратятся в кракозябры.
# =====================================================================
# Для планировщика достаточно одного задания раз в сутки: powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\poshacme\Update-RDGWCertificate.ps1 с галкой «Выполнять с наивысшими правами».
# Для внепланового продления (например, при тестировании): -File C:\poshacme\Update-RDGWCertificate.ps1 -Force

param(
    # Продлить сертификат немедленно, даже если он ещё не вошёл в окно продления (~30 дней до истечения).
    [switch]$Force
)

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

function Get-BegetCredential {
    # Без -ForcePrompt: берём сохранённые данные, а если файла нет —
    # запрашиваем интерактивно (актуально при ручном запуске; при выполнении
    # из планировщика без интерактивной сессии Get-Credential не сработает,
    # поэтому для автоматических запусков файл должен быть создан заранее).
    param([switch]$ForcePrompt)

    if (-not $ForcePrompt -and (Test-Path $credentialFile)) {
        return Import-Clixml -Path $credentialFile
    }

    if (-not [Environment]::UserInteractive) {
        # Планировщик/SYSTEM без интерактивной сессии: Get-Credential тут либо
        # зависнет, либо упадёт. Даём понятную инструкцию вместо этого.
        throw "Нет действительных учётных данных Beget, а сессия неинтерактивная (планировщик). Обновите '$credentialFile' вручную от имени того пользователя, под которым выполняется задание."
    }

    Write-ToEventLog "Запрашиваем учётные данные Beget интерактивно." 'Warning'
    $cred = Get-Credential -Message 'Логин и пароль от аккаунта Beget (для DNS API)'
    if (-not $cred) {
        throw "Учётные данные Beget не были введены."
    }
    $cred | Export-Clixml -Path $credentialFile
    return $cred
}

function Test-BegetCredential {
    # Проверяет учётные данные Beget напрямую через DNS API (dns/getData) —
    # ДО обращения к Let's Encrypt. Плагин Beget не распознаёт отказ авторизации
    # (проверяет только $response.answer.status), поэтому при неверном/устаревшем
    # пароле он молча "успешно" отрабатывает, TXT-запись не создаётся, и LE
    # позднее падает с NXDOMAIN. Отказ авторизации Beget возвращает на верхнем
    # уровне ответа (status: error) — именно его мы здесь и ловим.
    param([Parameter(Mandatory)][pscredential]$Credential)

    $body = @{
        login        = $Credential.UserName
        passwd       = $Credential.GetNetworkCredential().Password
        input_format = 'json'
        input_data   = @{ fqdn = $certNames } | ConvertTo-Json -Compress
    }
    try {
        $resp = Invoke-RestMethod -Uri 'https://api.beget.com/api/dns/getData' -Method Post -Body $body -TimeoutSec 30
    }
    catch {
        # Сетевая ошибка — проверить не смогли; не блокируем, пусть решает ACME.
        Write-ToEventLog "Не удалось проверить учётные данные Beget (сетевая ошибка): $($_.Exception.Message)" 'Warning'
        return $true
    }
    # Верхнеуровневый status: error означает отказ авторизации/доступа к API.
    if ($resp.status -eq 'error') {
        return $false
    }
    return $true
}

function Grant-RDGWKeyAccess {
    # Import-PfxCertificate (его вызывает Set-RDGWCertificate) не выдаёт
    # NETWORK SERVICE доступ к закрытому ключу — из-за этого служба TSGateway
    # не может прочитать ключ нового сертификата и молча (или с "Отказано
    # в доступе" при ручной привязке) не применяет его.
    param(
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [string]$Account = 'NT AUTHORITY\NETWORK SERVICE'
    )

    $rsaKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $rsaKey) {
        throw "У сертификата $($Certificate.Thumbprint) не найден закрытый ключ в LocalMachine\My."
    }

    if ($rsaKey -is [System.Security.Cryptography.RSACng]) {
        $keyPath = Join-Path $env:ProgramData "Microsoft\Crypto\Keys\$($rsaKey.Key.UniqueName)"
    }
    else {
        $keyPath = Join-Path $env:ProgramData "Microsoft\Crypto\RSA\MachineKeys\$($rsaKey.CspKeyContainerInfo.UniqueKeyContainerName)"
    }
    if (-not (Test-Path $keyPath)) {
        throw "Файл закрытого ключа не найден: $keyPath"
    }

    $acl = Get-Acl -Path $keyPath
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($Account, 'Read', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -Path $keyPath -AclObject $acl
}

try {
    # --- Рабочий каталог ---
    if (-not (Test-Path $poshAcmeHome)) {
        New-Item -ItemType Directory -Path $poshAcmeHome | Out-Null
    }

    # TLS 1.2 обязателен и для PSGallery, и для Beget API на старых системах.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # --- Учётные данные Beget ---
    # Внимание: Export-Clixml шифрует пароль через DPAPI — расшифровать его
    # может ТОЛЬКО тот же пользователь на той же машине. Если скрипт будет
    # выполняться планировщиком от SYSTEM, файл нужно создавать тоже от SYSTEM
    # (например, через psexec -s -i powershell).
    # Проверяем учётные данные до Let's Encrypt: если пароль сменился, повторно
    # запрашиваем и сохраняем новый (при интерактивном запуске).
    $begetCred = Get-BegetCredential
    if (-not (Test-BegetCredential -Credential $begetCred)) {
        Write-ToEventLog "Учётные данные Beget недействительны (возможно, сменился пароль) — запрашиваем новые." 'Warning'
        $begetCred = Get-BegetCredential -ForcePrompt
        if (-not (Test-BegetCredential -Credential $begetCred)) {
            throw "Учётные данные Beget по-прежнему недействительны. Проверьте логин и пароль от аккаунта Beget и доступ к API (https://cp.beget.com, раздел «Управление аккаунтом» → «API»)."
        }
    }
    $pArgs = @{ BegetCredential = $begetCred }

    # --- Модули ---
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

    if ($order -and $order.status -eq 'valid') {
        # Уже есть выпущенный сертификат — продлеваем. Submit-Renewal возвращает
        # объект только если продление реально выполнено (по умолчанию — за
        # ~30 дней до истечения, если не указан -Force).
        $renewParams = @{ MainDomain = $certNames }
        if ($Force) { $renewParams.Force = $true }
        $cert = Submit-Renewal @renewParams
        if (-not $cert) {
            Write-ToEventLog "Сертификат для $certNames ещё действителен — продление не требуется."
            return
        }
        Write-ToEventLog "Сертификат успешно продлён."
    }
    else {
        # Заказа нет либо прошлый не завершён (pending/invalid) — выпускаем заново.
        Write-ToEventLog "Запрашиваем новый сертификат для $certNames"
        $newParams = @{ AcceptTOS = $true; Contact = $email; Plugin = 'Beget'; PluginArgs = $pArgs }
        if ($order -and $order.status -eq 'invalid') {
            # Прошлый заказ ушёл в invalid (например, из-за неудачной DNS-проверки) —
            # принудительно создаём новый, иначе Let's Encrypt переиспользует
            # уже «мёртвую» авторизацию и проверка снова провалится.
            $newParams.Force = $true
        }
        $cert = New-PACertificate $certNames @newParams
        if (-not $cert) { throw "Не удалось получить сертификат для $certNames" }
        Write-ToEventLog "Новый сертификат получен."
    }

    # --- Импорт сертификата и права на закрытый ключ ---
    $x509 = Get-Item "Cert:\LocalMachine\My\$($cert.Thumbprint)" -ErrorAction SilentlyContinue
    if (-not $x509) {
        Write-ToEventLog "Импортируем сертификат в LocalMachine\My"
        $x509 = Import-PfxCertificate -FilePath $cert.PfxFile -CertStoreLocation Cert:\LocalMachine\My -Password $cert.PfxPass
    }
    Grant-RDGWKeyAccess -Certificate $x509

    # --- Установка на RD Gateway ---
    # Set-RDGWCertificate идемпотентен: если отпечаток не изменился — ничего не делает.
    # -ErrorAction Stop обязателен: функция сама перехватывает свои ошибки через
    # trap {...; return} и превращает их в non-terminating Write-Error, которая
    # без явного -ErrorAction Stop проходит мимо try/catch этого скрипта.
    $cert | Set-RDGWCertificate -RemoveOldCert -ErrorAction Stop

    $appliedThumb = (Get-Item RDS:\GatewayServer\SSLCertificate\Thumbprint).CurrentValue
    if ($appliedThumb -ne $cert.Thumbprint) {
        throw "Set-RDGWCertificate завершился без ошибки, но на шлюзе установлен отпечаток $appliedThumb вместо ожидаемого $($cert.Thumbprint)."
    }
    Write-ToEventLog "Сертификат установлен на RD Gateway. Отпечаток: $($cert.Thumbprint). Действителен до: $($cert.NotAfter)."
}
catch {
    Write-ToEventLog "Ошибка: $($_.Exception.Message)" 'Error'
    throw
}
