# Функция для записи в журнал событий
function Write-ToEventLog {
    param (
        [string]$Message,
        [string]$Type = "Information"
    )
    Write-EventLog -LogName "Application" -Source "ACME Cert Management" -EventID 1001 -EntryType $Type -Message $Message
}

# Параметры
$certName = 'example.com'
$env:POSHACME_HOME = 'C:\poshacme'

# Регистрация источника в журнале событий (требует прав администратора)
if (![System.Diagnostics.EventLog]::SourceExists("ACME Cert Management")) {
    New-EventLog -LogName "Application" -Source "ACME Cert Management"
}


if (!(Test-Path c:\poshacme)) {
    new-item -ItemType Directory -path c:\poshacme
}

$credentialFile = "C:\poshacme\BegetCred.xml"
if (!(Test-Path $credentialFile)) {
    $errorMsg = "файл с учётными данными не найден. сохраните их с помощью: `$cred = Get-Credential; `$cred | Export-Clixml -Path '$credentialFile'"
#    Write-Host $errorMsg
    Write-ToEventLog $errorMsg "Error"
    throw $errorMsg
}

$begetCred = Import-Clixml -Path $credentialFile

# Аргументы дл¤ плагина Beget
$pArgs = @{
    BegetCredential = $begetCred
}

# Импорт модулей
Import-Module Posh-ACME -ErrorAction Stop
Import-Module Posh-ACME.Deploy -ErrorAction Stop

# Настройка ACME-сервера (используйте LE_PROD для продакшена)
Set-PAServer LE_PROD
#Set-PAServer LE_STAGE

# Получаем существующий заказ/сертификат в Posh-ACME
$order = Submit-Renewal -MainDomain $certName -ErrorAction SilentlyContinue
if ($order) {
    try {
        $order | Set-RDGWCertificate -RemoveOldCert -ErrorAction Stop
        Write-ToEventLog "Процесс обновления сертификата завершён."
    } catch {
        Write-ToEventLog "Ошибка установки сертификата: $_" "Error"
        throw
    }
} else {
    Write-ToEventLog "Обновление сертификата не требуется."
}
