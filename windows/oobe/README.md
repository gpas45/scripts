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
├─ Far\Far-x64.msi
├─ AnyDesk\AnyDesk.exe
├─ CryptoPro\cprocsp-pki-cades-x64.msi
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

Готовые профили: `base` (7-Zip, Adobe Reader, Notepad++ и все правки реестра),
`browser` (Chrome, Firefox), `extra` (VLC, Far), `remote` (AnyDesk),
`crypto` (КриптоПро — заполните `nasPath`/`installerUrl` своим дистрибутивом).

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

Правки реестра — тоже данные:

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

Секция `system`: часовой пояс, имя компьютера, отключение гибернации и
засыпания от сети, RDP, перезапуск Проводника, перезагрузка в конце.

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
