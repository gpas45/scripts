# Скрипт для установки сертификата LetsEncrypt для шлюза Remote Desktop Gateway
# В данном случае домен припаркован у хостера Beget

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

if (!(Test-Path c:\poshacme)) {
    new-item -ItemType Directory -path c:\poshacme
}

$credentialFile = "C:\poshacme\BegetCred.xml"
if (!(Test-Path $credentialFile)) {
    $errorMsg = "Файл с учётными данными не найден. Сохраните их с помощью: `$cred = Get-Credential; `$cred | Export-Clixml -Path '$credentialFile'"
    Write-Host $errorMsg
    Write-ToEventLog $errorMsg "Error"
    throw $errorMsg
}
try {
    $begetCred = Import-Clixml -Path $credentialFile
} catch {
    $errorMsg = "ќшибка загрузки учЄтных данных Beget: $_"
    Write-ToEventLog $errorMsg "Error"
    throw $errorMsg
}

# Аргументы дл¤ плагина Beget
$pArgs = @{
    BegetCredential = $begetCred
}

# Установка модулей (если не установлены)
if (!(Get-Module -Name Posh-ACME -ListAvailable)) {
    Write-Host "”станавливаем Posh-ACME..."
    Install-Module -Name Posh-ACME -Scope CurrentUser -Force
}
if (!(Get-Module -Name Posh-ACME.Deploy -ListAvailable)) {
    Write-Host "”станавливаем Posh-ACME.Deploy..."
    Install-Module -Name Posh-ACME.Deploy -Scope CurrentUser -Force
}

# Импорт модулей
Import-Module Posh-ACME
Import-Module Posh-ACME.Deploy

# Настройка ACME-сервера (используйте LE_PROD для продакшена)
Set-PAServer LE_PROD
#Set-PAServer LE_STAGE

New-PACertificate $certNames -AcceptTOS -Contact $email -Plugin Beget -PluginArgs $pArgs | Set-RDGWCertificate
