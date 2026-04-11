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

# Параметры
$certNames = 'rds.vash-profbuh.ru'
$email     = 'gpas@dioservice.ru'
$env:POSHACME_HOME = 'C:\poshacme'

# Регистрация источника в журнале событий (требует прав администратора)
if (![System.Diagnostics.EventLog]::SourceExists("ACME Cert Management")) {
    New-EventLog -LogName "Application" -Source "ACME Cert Management"
}

# Создание рабочей директории
if (!(Test-Path 'C:\poshacme')) {
    New-Item -ItemType Directory -Path 'C:\poshacme' | Out-Null
}

# Загрузка учётных данных Beget
$credentialFile = 'C:\poshacme\BegetCred.xml'
if (!(Test-Path $credentialFile)) {
    $errorMsg = "Файл с учётными данными не найден. Сохраните их с помощью: `$cred = Get-Credential; `$cred | Export-Clixml -Path '$credentialFile'"
    Write-Host $errorMsg
    Write-ToEventLog $errorMsg "Error"
    throw $errorMsg
}

try {
    $begetCred = Import-Clixml -Path $credentialFile
} catch {
    $errorMsg = "Ошибка загрузки учётных данных Beget: $_"
    Write-ToEventLog $errorMsg "Error"
    throw $errorMsg
}

# Аргументы для плагина Beget
$pArgs = @{
    BegetCredential = $begetCred
}

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

# Настройка ACME-сервера
Set-PAServer LE_PROD
#Set-PAServer LE_STAGE

# Выпуск или обновление сертификата
try {
    $order = New-PACertificate $certNames -AcceptTOS -Contact $email -Plugin Beget -PluginArgs $pArgs
} catch {
    $errorMsg = "Ошибка выпуска сертификата: $_"
    Write-ToEventLog $errorMsg "Error"
    throw
}

# Установка сертификата на RD Gateway
if ($order) {
    try {
        $order | Set-RDGWCertificate -RemoveOldCert
        $successMsg = "Сертификат успешно обновлён и установлен на RD Gateway."
        Write-Host $successMsg
        Write-ToEventLog $successMsg
    } catch {
        $errorMsg = "Ошибка установки сертификата на RD Gateway: $_"
        Write-ToEventLog $errorMsg "Error"
        throw
    }
} else {
    $infoMsg = "Сертификат актуален, обновление не требуется."
    Write-Host $infoMsg
    Write-ToEventLog $infoMsg
}
