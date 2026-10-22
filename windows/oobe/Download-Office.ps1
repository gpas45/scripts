<#
.SYNOPSIS
    Выкачивает дистрибутив Microsoft Office через ODT для установки без интернета.

.DESCRIPTION
    Первый из двух шагов. Выполняется ОДИН раз на машине с доступом к серверам
    Microsoft, результат выкладывается на раздачу, а дальше postinstall.ps1
    ставит Office на рабочие станции уже из этой папки, никуда не обращаясь.

        .\Download-Office.ps1
        .\Download-Office.ps1 -Branch O365ProPlusRetail -Channel Current -Components Word,Excel,Outlook,Teams

    Что делает:
      1. сверяет допустимость пары ветка/канал;
      2. обходит региональную блокировку загрузки Office (см. ниже);
      3. скачивает setup.exe из состава Office Deployment Tool;
      4. собирает configuration.xml по заданным параметрам;
      5. запускает setup.exe /download.

    Microsoft не отдаёт дистрибутив Office в российский и белорусский регионы.
    Скрипт временно подменяет регион на польский и удаляет ключи реестра
    Experiment, которые хранят это ограничение; исходный регион возвращается
    по завершении, в том числе при ошибке или Ctrl+C. Отключается -KeepRegion.

    Приём и ссылки взяты из https://github.com/farag2/Install-Office

.PARAMETER Branch
    Редакция. Канал должен ей соответствовать, иначе загрузка не начнётся.

.PARAMETER Components
    Компоненты Office. Всё остальное попадёт в ExcludeApp.

.PARAMETER AdditionalProducts
    Project и Visio — отдельные продукты, а не компоненты. Ставятся с языком
    MatchOS, то есть по языку системы.

.PARAMETER Path
    Куда складывать. Внутри появится каталог Office\Data со сборкой.

.PARAMETER KeepRegion
    Не трогать регион. Для машин вне российского и белорусского регионов.

.NOTES
    Требует прав администратора и PowerShell 5.1 или новее.
    Сообщений во время загрузки нет — ориентируйтесь по размеру папки.
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('ProPlus2024Volume', 'ProPlus2021Volume', 'O365ProPlusRetail')]
    [string]$Branch = 'ProPlus2024Volume',

    [ValidateSet('PerpetualVL2024', 'PerpetualVL2021', 'Current', 'SemiAnnual', 'MonthlyEnterprise')]
    [string]$Channel = 'PerpetualVL2024',

    [ValidateSet('Access', 'Bing', 'Excel', 'Groove', 'Lync', 'OneDrive', 'OneNote',
        'Outlook', 'PowerPoint', 'Publisher', 'Teams', 'Word')]
    [string[]]$Components = @('Outlook', 'Word', 'Excel', 'PowerPoint'),

    [ValidateSet('ProjectPro2024Volume', 'VisioPro2024Volume',
        'ProjectPro2021Volume', 'VisioPro2021Volume')]
    [string[]]$AdditionalProducts,

    [string[]]$Languages = @('ru-ru', 'en-us'),

    [ValidateSet('32', '64')]
    [string]$Edition = '64',

    [string]$Path = (Join-Path -Path $PSScriptRoot -ChildPath 'OfficeSource'),

    [switch]$KeepRegion
)

$ErrorActionPreference = 'Stop'

# Прогресс-бар Invoke-WebRequest в Windows PowerShell 5.1 замедляет загрузку
# в разы: https://github.com/PowerShell/PowerShell/issues/2138
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch {
    Write-Warning "Не удалось включить TLS 1.2: $($_.Exception.Message)"
}

# --- 1. Проверка пары ветка/канал --------------------------------------------
# Каналы не взаимозаменяемы: томовым редакциям соответствует только
# Perpetual-канал своего года, подписочной — обычные каналы обновлений.
$validChannels = @{
    ProPlus2024Volume = @('PerpetualVL2024')
    ProPlus2021Volume = @('PerpetualVL2021')
    O365ProPlusRetail = @('Current', 'SemiAnnual', 'MonthlyEnterprise')
}
if ($validChannels[$Branch] -notcontains $Channel) {
    throw "Канал $Channel не подходит к редакции $Branch. Допустимые: $($validChannels[$Branch] -join ', ')."
}

$known = @('Access', 'Bing', 'Excel', 'Groove', 'Lync', 'OneDrive', 'OneNote',
    'Outlook', 'PowerPoint', 'Publisher', 'Teams', 'Word')
$exclude = @($known | Where-Object { $Components -notcontains $_ })

New-Item -ItemType Directory -Force -Path $Path | Out-Null

# --- 2. Обход региональной блокировки ----------------------------------------
$originalGeoId = $null
if (-not $KeepRegion) {
    try {
        $currentGeoId = (Get-WinHomeLocation).GeoId
        # 203 — Россия, 29 — Беларусь, 191 — Польша.
        if ($currentGeoId -in @(203, 29)) {
            $originalGeoId = $currentGeoId
            Set-WinHomeLocation -GeoId 191
            Write-Warning "Регион временно изменён на польский (был $originalGeoId) — иначе Microsoft не отдаёт дистрибутив."
        }
    }
    catch {
        Write-Warning "Не удалось прочитать или сменить регион: $($_.Exception.Message)"
    }

    # В этих ключах оседает то же ограничение, снятия региона мало.
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -Path @(
        'HKCU:\SOFTWARE\Microsoft\Office\16.0\Common\Experiment',
        'HKCU:\SOFTWARE\Microsoft\Office\16.0\Common\ExperimentConfigs',
        'HKCU:\SOFTWARE\Microsoft\Office\16.0\Common\ExperimentEcs'
    )
}

try {
    # --- 3. Office Deployment Tool -------------------------------------------
    $setup = Join-Path -Path $Path -ChildPath 'setup.exe'
    if (Test-Path -LiteralPath $setup) {
        Write-Host "ODT уже на месте: $setup"
    }
    else {
        Write-Host 'Скачиваю Office Deployment Tool…'
        Invoke-WebRequest -Uri 'https://officecdn.microsoft.com/pr/wsus/setup.exe' `
            -OutFile $setup -UseBasicParsing
        Write-Host "  получен $setup"
    }

    # --- 4. configuration.xml -------------------------------------------------
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<Configuration>')
    [void]$sb.AppendLine(('  <Add OfficeClientEdition="{0}" Channel="{1}">' -f $Edition, $Channel))
    [void]$sb.AppendLine(('    <Product ID="{0}">' -f $Branch))
    foreach ($language in $Languages) {
        [void]$sb.AppendLine(('      <Language ID="{0}" />' -f $language))
    }
    foreach ($app in $exclude) {
        [void]$sb.AppendLine(('      <ExcludeApp ID="{0}" />' -f $app))
    }
    [void]$sb.AppendLine('    </Product>')
    foreach ($product in $AdditionalProducts) {
        # Project и Visio идут отдельными продуктами, язык по системе.
        [void]$sb.AppendLine(('    <Product ID="{0}">' -f $product))
        [void]$sb.AppendLine('      <Language ID="MatchOS" />')
        [void]$sb.AppendLine('    </Product>')
    }
    [void]$sb.AppendLine('  </Add>')
    [void]$sb.AppendLine('</Configuration>')

    $config = Join-Path -Path $Path -ChildPath 'configuration-download.xml'
    [IO.File]::WriteAllText($config, $sb.ToString(), (New-Object Text.UTF8Encoding $false))

    Write-Host ''
    Write-Host "Редакция  : $Branch, канал $Channel, $Edition-бит"
    Write-Host "Языки     : $($Languages -join ', ')"
    Write-Host "Компоненты: $($Components -join ', ')"
    if ($AdditionalProducts) { Write-Host "Продукты  : $($AdditionalProducts -join ', ')" }
    Write-Host ''

    # --- 5. Загрузка ----------------------------------------------------------
    Write-Host 'Качаю Office. Сообщений не будет, это нормально — смотрите на размер папки.'
    $proc = Start-Process -FilePath $setup -ArgumentList @('/download', "`"$config`"") -PassThru
    $null = $proc.Handle
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) {
        throw "setup.exe /download вернул код $($proc.ExitCode)."
    }
}
finally {
    # Регион возвращаем в любом случае, иначе машина останется польской.
    if ($originalGeoId) {
        try {
            Set-WinHomeLocation -GeoId $originalGeoId
            Write-Warning "Регион возвращён ($originalGeoId)."
        }
        catch {
            Write-Warning "ВЕРНИТЕ РЕГИОН ВРУЧНУЮ ($originalGeoId): $($_.Exception.Message)"
        }
    }
}

$data = Join-Path -Path $Path -ChildPath 'Office\Data'
$version = (Get-ChildItem -Path $data -Directory -ErrorAction SilentlyContinue |
    Sort-Object -Property Name -Descending | Select-Object -First 1).Name

Write-Host ''
Write-Host 'Готово.' -ForegroundColor Green
Write-Host "  Дистрибутив : $Path"
if ($version) { Write-Host "  Сборка      : $version" }
Write-Host ''
Write-Host 'Дальше: выложите содержимое на раздачу как Office\Source, а setup.exe'
Write-Host 'как Office\ODT\setup.exe, и заполните в postinstall.json:'
Write-Host "  \"sourceNasPath\": \"Office/Source\""
if ($version) { Write-Host "  \"version\": \"$version\"" }
