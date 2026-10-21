# windows/oobe/

Автоматическая установка и настройка рабочей станции Windows 10/11: от файла
ответов до установленного ПО и правок реестра — без вопросов на экране.

Документация Microsoft по файлам ответов:
<https://learn.microsoft.com/ru-ru/windows-hardware/customize/desktop/unattend/>
Идея запуска OOBE одной командой: <https://www.outsidethebox.ms/22491/>

## Файлы

| Файл | Назначение |
|---|---|
| `AutoUnattend.xml` | Файл ответов для **чистой установки** с нуля (проходы `windowsPE` + `oobeSystem`): локали, обход требований Win11, локальный администратор `Admin`. |
| `UnattendOOBE.xml` | Файл ответов **только для прохода `oobeSystem`** — для повторного прогона OOBE на уже установленной системе через `sysprep /oobe`. |
| `oobe.ps1` | Скачивает `UnattendOOBE.xml`, проверяет его, раскладывает пост-установочные файлы и запускает `sysprep /oobe /reboot /unattend:…`. |
| `postinstall.ps1` | Пост-установка при первом входе: ПО, правки реестра, системные настройки. Логику не правят — правят `postinstall.json`. |
| `postinstall.json` | **Единственный файл, который нужно настроить под себя**: адрес NAS, список ПО, правки реестра, системные параметры. |
| `office/configuration-ProPlus2021Volume.xml` | Конфигурация Office Deployment Tool для Office LTSC Professional Plus 2021 (томовая лицензия). |
| `office/configuration-M365Apps.xml` | Конфигурация ODT для Microsoft 365 Apps (подписка). |

## Сценарий 1: повторный прогон OOBE на уже установленной Windows

Применяется, когда система уже стоит (предустановленная ОС от вендора, образ
Hyper-V, машина после возврата от пользователя). Драйверы, активация и SID
сохраняются — `sysprep` запускается **без** `/generalize`.

На первом экране OOBE (выбор региона) нажмите <kbd>Shift</kbd>+<kbd>F10</kbd> и выполните:

```powershell
irm https://raw.githubusercontent.com/gpas45/scripts/main/windows/oobe/oobe.ps1 -OutFile $env:TEMP\oobe.ps1
powershell -ExecutionPolicy Bypass -File $env:TEMP\oobe.ps1
```

С паролем к SMB-папке NAS (сохраняется в `C:\ProgramData\oobe\nas.cred`
с правами только для SYSTEM и администраторов) — добавьте `-NasPassword 'пароль'`.

Короткий вариант «в одну команду» из статьи-источника тоже работает, но
скрипты здесь сохранены в UTF-8 **с BOM** (иначе Windows PowerShell 5.1
портит кириллицу), а `iex` на строке с ведущим BOM падает — его надо срезать:

```powershell
powershell -c "iex ((irm https://raw.githubusercontent.com/gpas45/scripts/main/windows/oobe/oobe.ps1) -replace '^\uFEFF')"
```

Дальше всё само: перезагрузка, OOBE без вопросов, автовход под `Admin`,
пост-установка, итоговый лог в `C:\ProgramData\oobe\postinstall.log`.

> ⚠️ Запуск скрипта из интернета небезопасен: содержимое по ссылке может быть
> подменено, а выполняется оно с правами SYSTEM. Для серийного развёртывания
> указывайте ссылку на конкретный коммит и сверяйте хеш:
> `oobe.ps1 -AnswerFileUri '…/<sha>/windows/oobe/UnattendOOBE.xml' -Sha256 '<хеш>'`.

## Сценарий 2: чистая установка с флешки

1. Положите `AutoUnattend.xml` в корень установочной флешки под именем
   `autounattend.xml`.
2. Скопируйте туда же папку `oobe` с `postinstall.ps1` и `postinstall.json`
   (и, при необходимости, `nas.cred`) — `FirstLogonCommands` ищет
   `<диск>:\oobe\postinstall.ps1` на всех томах, а если не находит, берёт
   скрипт из репозитория.
3. Загрузитесь с флешки.

## Дистрибутивы на Synology NAS

`postinstall.ps1` берёт установщики в порядке **NAS → winget → прямая ссылка**
(поле `source` у каждого пакета: `auto`, `nas`, `winget`, `url`).

Ожидаемая раскладка раздачи (пути задаются в `software[].nasPath`):

```
\\nas.local\install\
├─ 7-Zip\7z-x64.msi
├─ AdobeReader\AcroRdrDCx64.exe
├─ NotepadPlusPlus\npp-x64.exe
├─ Chrome\GoogleChromeStandaloneEnterprise64.msi
├─ Firefox\FirefoxSetup-x64.msi
├─ VLC\vlc-win64.exe
├─ YandexBrowser\Yandex.msi
├─ Far\Far-x64.msi
├─ Aspia\aspia-host-x86_64.msi
├─ CryptoPro\
│  ├─ cprocsp-pki-cades-x64.msi
│  └─ CSP\csp-x64-kc1.msi
├─ Kontur\Certificates_Kontur_Admin.exe
├─ Certificates\
│  ├─ russian_trusted_root_ca.cer
│  └─ russian_trusted_sub_ca.cer
└─ Office\ODT\
   ├─ setup.exe
   └─ configuration-ProPlus2021Volume.xml
```

Имена файлов без номеров версий — при обновлении дистрибутива переименуйте его,
и конфиг править не придётся.

### Вариант А: SMB (`"type": "smb"`)

На NAS: **Панель управления → Общая папка** → папка `install`, и
**Пользователь и группа** → учётная запись `deploy` с правом **только на чтение**.

Пароль в репозиторий не кладём. Два способа передать его:

- `oobe.ps1 -NasPassword '…'` — пишет `C:\ProgramData\oobe\nas.cred` с правами
  только для SYSTEM и администраторов (так работает сценарий 1);
- `postinstall.ps1 -NasPassword '…'` при ручном запуске.

> Гостевой доступ не подойдёт: Windows 10/11 по умолчанию запрещает
> небезопасный гостевой вход в SMB. Включать `AllowInsecureGuestAuth` не стоит —
> это открывает машину для атак на подмену SMB-сервера.

### Вариант Б: HTTP (`"type": "http"`)

Раздайте `install` через **Web Station** или File Station и укажите
`nas.baseUrl`. Аутентификация не нужна — ограничьте доступ по подсети
в брандмауэре DSM. Если на DSM самоподписанный сертификат, поставьте
`"ignoreCertErrors": true` (или, лучше, выпустите сертификат Let's Encrypt
средствами DSM).

## Настройка `postinstall.json`

Профили: у каждого пакета и каждой правки реестра есть `profiles`. Применяется
только то, чей профиль передан в `-Profiles` (элемент без `profiles` — всегда).

```powershell
# базовый набор
powershell -ExecutionPolicy Bypass -File .\postinstall.ps1
# базовый + браузеры + прочее
powershell -ExecutionPolicy Bypass -File .\postinstall.ps1 -Profiles base,browser,extra
```

| Профиль | Что входит |
|---|---|
| `base` | 7-Zip, Adobe Reader, Notepad++, сертификаты Минцифры, все правки реестра, системные настройки |
| `browser` | Chrome, Firefox, Яндекс Браузер для организаций |
| `extra` | VLC, Far Manager — опционально, в базовый набор не входят |
| `crypto` | КриптоПро CSP, КриптоПро ЭЦП Browser plug-in, сертификаты УЦ СКБ Контур |
| `remote` | Aspia Host |

### Выбор того, что ставить

Профили — не единственный способ. Есть три ключа, они складываются:

```powershell
# спросить интерактивно: нумерованный список, звёздочкой отмечено выбранное профилями
.\postinstall.ps1 -Select

# только определённые пакеты, профили при этом игнорируются
.\postinstall.ps1 -Include 'Крипто*','Контур','Aspia'

# набор профилей минус лишнее
.\postinstall.ps1 -Profiles base,browser -Exclude Chrome,Firefox
```

`-Include` и `-Exclude` сравниваются с полем `name` без учёта регистра, по
подстроке и по шаблонам (`*`, `?`). В интерактивном режиме принимаются номера
через запятую (`1,3,5`), диапазоны (`1-4`), `all`, `none`; пустой ввод оставляет
набор по профилям.

> `-Select` — только для ручного запуска. В `FirstLogonCommands` его задавать
> нельзя: установка будет ждать ввода. Если консоль неинтерактивна, ключ
> игнорируется с предупреждением, но полагаться на это не стоит.

#### Пакеты, которых нет в winget

Их дистрибутивы кладутся на NAS, `wingetId` у них пустой.

| Пакет | Где взять | Замечания |
|---|---|---|
| Яндекс Браузер для организаций | [личный кабинет корпоративного браузера](https://browser.yandex.ru/corp) | Ключи тихой установки у разных сборок отличаются |
| КриптоПро CSP | cryptopro.ru по вашей лицензии | Имя MSI зависит от версии и варианта KC1/KC2 — сверьте `nasPath`. Лицензия вводится отдельно: `cpconfig.exe -license -set <серийный номер>` |
| Сертификаты УЦ СКБ Контур | личный кабинет Контура | `SKBKontur.InstallCertificates`, консольная утилита, сертификаты зашиты внутрь, требует прав администратора. Свои команды смотрите через `/?` |
| Aspia Host | [github.com/dchapyshev/aspia/releases](https://github.com/dchapyshev/aspia/releases) | После установки хост нужно настроить (пароль/ID), иначе подключиться не получится |

У каждого пакета можно задать `timeoutSeconds`: если установщик не завершился
за это время (например, что-то спросил), процесс снимается, шаг помечается
ошибкой, а остальная настройка продолжается. По умолчанию 1800 с. Это важно
именно для автоматического прогона: зависший установщик иначе навсегда
подвесит первый вход в систему.

Яндекс Браузер для организаций в winget не публикуется — только MSI. Скачайте
его в [личном кабинете корпоративного браузера](https://browser.yandex.ru/corp),
при необходимости соберите с нужной конфигурацией и положите на NAS как
`YandexBrowser\Yandex.msi`. Ключи тихой установки у разных сборок отличаются —
проверьте на тестовой машине ([документация по развёртыванию](https://browser.yandex.ru/support/browser-corporate/ru/deployment/windows/deployment)).

Добавить свой пакет — одна запись в `software`:

```json
{
  "name": "Моя программа",
  "source": "auto",
  "wingetId": "",
  "nasPath": "MyApp\\setup.msi",
  "installerArgs": "/qn /norestart",
  "installerUrl": "",
  "profiles": ["base"]
}
```

`.msi` ставится через `msiexec /i … /qn /norestart`, `.ps1` — через
PowerShell, всё остальное запускается напрямую с `installerArgs`.
Коды возврата `3010`/`1641` трактуются как «нужна перезагрузка», а не как ошибка.

### Доверенные сертификаты

Секция `certificates` ставит корневые и промежуточные сертификаты — прежде всего
Минцифры (Russian Trusted Root CA / Sub CA), без которых не открываются сайты
госуслуг, Сбербанка и части госорганов.

| Поле | Назначение |
|---|---|
| `nasPath` | Файл на NAS — основной источник |
| `url` | Резервная прямая ссылка, если на NAS файла нет |
| `store` | `Root` — доверенные корневые ЦС, `CA` — промежуточные |
| `thumbprint` | Ожидаемый отпечаток SHA1; при несовпадении сертификат не ставится |

Файлы скачайте **один раз** с официальной страницы <https://www.gosuslugi.ru/crt>,
сверьте отпечаток и положите на NAS. Тянуть корневой сертификат на каждой машине
с внешнего адреса не нужно: установленный корневой ЦС позволяет выпускать
сертификаты, которым машина будет доверять для любого сайта, поэтому источник
должен быть проверенным, а `thumbprint` — заполненным. Если `thumbprint` пустой,
скрипт установит сертификат, но напишет предупреждение с фактическим отпечатком.

Узнать отпечаток файла:

```powershell
(Get-PfxCertificate .\russian_trusted_root_ca.cer).Thumbprint
```

Сертификаты ставятся до установки ПО — иначе HTTPS внутренних серверов, откуда
идут дистрибутивы, может не открыться. Уже установленный сертификат
пропускается, так что повторный запуск безопасен.

### Правки реестра

Тоже данные:

```json
{
  "description": "Показывать расширения файлов",
  "path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
  "name": "HideFileExt",
  "type": "DWord",
  "value": 0,
  "profiles": ["base"]
}
```

Безымянное значение ключа (в regedit — «(По умолчанию)») задаётся через
`"name": "(default)"` либо пустым `name`. Так включается классическое
контекстное меню Windows 11: пустая строка в `InprocServer32` под CLSID
`{86CA1AA0-34AA-4E8B-A509-50C905BAE2A2}`. Эффект появляется после перезапуска
Проводника — за это отвечает `system.restartExplorer`.

Политики Windows Update занимают два разных раздела, и перепутать их легко:

| Раздел | Что лежит |
|---|---|
| `…\Policies\Microsoft\Windows\WindowsUpdate` | Активные часы (`SetActiveHours`, `ActiveHoursStart/End`) и дедлайны (`SetComplianceDeadline`, `ConfigureDeadline*`) |
| `…\Policies\Microsoft\Windows\WindowsUpdate\AU` | Расписание установки (`NoAutoUpdate`, `AUOptions`, `ScheduledInstall*`) и перезагрузки (`NoAutoRebootWithLoggedOnUsers`, `AlwaysAutoRebootAtScheduledTime`) |

`SetComplianceDeadline = 1` обязателен: без него все `ConfigureDeadline*`
игнорируются. Политики `AU` не действуют на Windows 10/11 Home — нужна
редакция Pro или выше.

Текущий набор: обновления ставятся по расписанию в 03:00 каждый день, активные
часы 09:00–23:00, принудительных перезагрузок при вошедшем пользователе нет,
дедлайны — 7 дней на крупные обновления, 5 на безопасность, 2 дня льготного
периода.

### Системные настройки

Секция `system`: часовой пояс, раскладка по умолчанию, имя компьютера,
отключение гибернации и засыпания от сети, RDP, перезапуск Проводника,
перезагрузка в конце.

### Локали

| Параметр | Значение | Что задаёт |
|---|---|---|
| `InputLocale` | `en-US; ru-RU` | Раскладки клавиатуры; первая в списке — по умолчанию, то есть ввод стартует английским |
| `SystemLocale` | `ru-RU` | Язык для не-Unicode программ (кодовая страница 1251) — нужен 1С |
| `UILanguage` | `ru-RU` | Язык интерфейса системы |
| `UILanguageFallback` | `en-US` | Запасной язык интерфейса, если русского пакета нет в образе |
| `UserLocale` | `ru-RU` | Региональные форматы: дата ДД.ММ.ГГГГ, запятая как десятичный разделитель, рубль |

> `UILanguage ru-RU` работает только если русский языковой пакет есть в образе.
> Берите русский дистрибутив Windows; на англоязычном образе интерфейс
> останется английским (сработает `UILanguageFallback`), пока не доставите
> языковой пакет.

Раскладка по умолчанию английская закрепляется дважды: порядком в `InputLocale`
и параметром `system.defaultInputLanguage` в `postinstall.json` — при русских
`UILanguage`/`UserLocale` Windows иначе может переставить раскладку сама.

## Microsoft Office

По умолчанию `"office": { "enabled": false }` — редакцию и способ активации
за вас не выберешь. Включается одним флагом:

| `mode` | Что делает |
|---|---|
| `odt` | Берёт `setup.exe` из `Office\ODT\` на NAS (или ставит ODT через winget) и выполняет `setup.exe /configure <configuration.xml>`. Для Office LTSC / томовых лицензий. |
| `winget` | `winget install Microsoft.Office` — Microsoft 365 Apps, лицензия активируется входом пользователя. |

Конфигурации ODT лежат в `office/`. Параметры: [справочник ODT](https://learn.microsoft.com/ru-ru/microsoft-365-apps/deploy/office-deployment-tool-configuration-options),
ключи KMS: [GVLK](https://learn.microsoft.com/ru-ru/deployoffice/vlactivation/gvlks).

## Учётная запись и пароль

Файлы ответов создают локального администратора **`Admin`** с паролем **`Admin`**
и однократным автовходом. Пароль хранится в штатной обфускации unattend —
это base64, а не шифрование. Сменить:

```powershell
[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('НовыйПароль' + 'Password'))
```

и подставить результат в `<Value>` обоих блоков (`LocalAccount` и `AutoLogon`).
Чтобы потребовать смену пароля при первом входе, раскомментируйте второй
`SynchronousCommand` в `UnattendOOBE.xml`.

## Диагностика

| Что | Где |
|---|---|
| Лог пост-установки | `C:\ProgramData\oobe\postinstall.log` |
| Лог ODT (Office) | `C:\ProgramData\oobe\*.log` |
| Применённый файл ответов | `C:\Windows\Panther\unattend.xml` |
| Ошибки применения файла ответов | `C:\Windows\Panther\setupact.log`, `setuperr.log` |
| Логи sysprep | `C:\Windows\System32\Sysprep\Panther\` |

`postinstall.ps1` не падает на одном сбойном пакете: в конце печатается список
невыполненных шагов, код возврата `1`. Повторный запуск безопасен.

## Правки .ps1 в этой папке

Скрипты содержат русский текст и запускаются Windows PowerShell 5.1, поэтому
сохраняйте их в **UTF-8 с BOM** — без BOM 5.1 читает файл как ANSI и
кириллица превращается в мусор. Файлы ответов, наоборот, — UTF-8 **без** BOM.
