# Скрипт для автоматического обновления сертификатов шлюза Remote Desktop Gateway на Windows Server

# Функция для записи в журнал событий
function Write-ToEventLog {
    param (
        [string]$Message,
        [string]$Type = "Information"
    )
    Write-EventLog -LogName "Application" -Source "ACME Cert Management" -EventID 1001 -EntryType $Type -Message $Message
}

$certName = 'rds.vash-profbuh.ru'
$email = 'gpas@dioservice.ru'
$env:POSHACME_HOME = 'C:\poshacme'
$trace = 'C:\poshacme\renew.trace.log'

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



# Установка модулей (если не установлены)
# if (!(Get-Module -Name Posh-ACME -ListAvailable)) {
    # Write-Host "Устанавливаем Posh-ACME..."
    # Install-Module -Name Posh-ACME -Scope CurrentUser -Force
# }
# if (!(Get-Module -Name Posh-ACME.Deploy -ListAvailable)) {
    # Write-Host "Устанавливаем Posh-ACME.Deploy..."
    # Install-Module -Name Posh-ACME.Deploy -Scope CurrentUser -Force
# }

# Импорт модулей
Import-Module Posh-ACME -ErrorAction Stop
Import-Module Posh-ACME.Deploy -ErrorAction Stop

# Настройка ACME-сервера (используйте LE_PROD для продакшена)
Set-PAServer LE_PROD
#Set-PAServer LE_STAGE

# Получаем существующий заказ/сертификат в Posh-ACME
$order = Get-PACertificate -MainDomain $certName -ErrorAction SilentlyContinue
if (-not $order) {
    throw "Не найден существующий сертификат/заказ в Posh-ACME дл¤ $certName. —начала выполните первичное получение (New-PACertificate)."
}

if ($order = Submit-Renewal) {
	Set-RDGWCertificate -RemoveOldCert -ErrorAction Stop
	Write-ToEventLog "Процесс обновления сертификата завершён."
}

else {
    Write-ToEventLog "Обновление сертификата не требуется."
}
