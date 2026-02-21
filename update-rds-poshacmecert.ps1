# Скрипт для автоматического обновления сертификатов шлюза Remote Desktop Gateway на Windows Server

# Функция для записи в журнал событий
function Write-ToEventLog {
    param (
        [string]$Message,
        [string]$Type = "Information"
    )
    Write-EventLog -LogName "Application" -Source "ACME Cert Management" -EventID 1001 -EntryType $Type -Message $Message
}

$certNames = 'example.com'
$email = 'admin@example.com'
$env:POSHACME_HOME = 'C:\poshacme'

# Установка модулей (если не установлены)
if (!(Get-Module -Name Posh-ACME -ListAvailable)) {
    Write-Host "Устанавливаем Posh-ACME..."
    Install-Module -Name Posh-ACME -Scope CurrentUser -Force
}
if (!(Get-Module -Name Posh-ACME.Deploy -ListAvailable)) {
    Write-Host "Устанавливаем Posh-ACME.Deploy..."
    Install-Module -Name Posh-ACME.Deploy -Scope CurrentUser -Force
}

# Импорт модулей
Import-Module Posh-ACME
Import-Module Posh-ACME.Deploy

Set-PAOrder $certNames
if ($cert = Submit-Renewal) {
	Set-RDGWCertificate -RemoveOldCert
	Write-ToEventLog "Процесс обновления сертификата завершён."
}
