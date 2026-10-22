# synology/

Скрипты для Synology DSM.

| Скрипт | Назначение |
|---|---|
| `php2shell-check.sh` | Проверка NAS на уязвимость PHP2Shell (CVE-2026-109618, CVE-2026-109619): версии установленных пакетов PHP, настройка `session.upload_progress.enabled`, оценка экспозиции Web Station. Только чтение, ничего не меняет. |

## php2shell-check.sh

**PHP2Shell** — пара уязвимостей удалённого выполнения кода в PHP
(CVE-2026-109618, CVE-2026-109619; CVSS v4.0 9.2), раскрытых 21.10.2026.
Эксплуатируются через обработчик upload-progress в сессиях PHP и срабатывают
**до** кода приложения, поэтому авторизация на уровне сайта от них не защищает.

Исправлено в PHP 8.2.35, 8.3.36, 8.4.27, 8.5.12. Ветки 8.1 и старше официального
исправления не получили.

### Запуск

```sh
sudo ./php2shell-check.sh
```

Без `root` часть конфигов PHP недоступна для чтения — проверка
`session.upload_progress.enabled` будет неполной.

### Коды возврата

| Код | Значение |
|---|---|
| `0` | Уязвимых пакетов PHP не найдено. |
| `1` | Найден уязвимый пакет PHP. |
| `2` | Ошибка запуска (не Synology DSM). |

Коды возврата позволяют использовать скрипт в планировщике задач DSM или как
внешнюю проверку Zabbix.

### Что делать при вердикте «УЯЗВИМ»

1. Package Center → обновить пакет PHP до сборки с исправленной версией.
2. Пока обновления нет — убрать Web Station из интернета: закрыть проброс
   портов на роутере, поставить перед ним WAF или reverse proxy.
3. Временная мера: `session.upload_progress.enabled = Off` в профиле PHP.
   Закрывает подтверждённый путь CVE-2026-109619, но не CVE-2026-109618.
4. Если PHP ничем не используется — удалить пакет.

### Источники

- [PHP2Shell — Sansec](https://sansec.io/research/php2shell)
- [PHP2Shell FAQ — Tenable](https://www.tenable.com/blog/php2shell-cve-2026-109618-cve-2026-109619-frequently-asked-questions-about-critical-php-remote)
- [PHP2Shell — JFrog Security Research](https://research.jfrog.com/post/php2shell-all-you-need-to-know-about-cve-2026-109618-and-cve-2026-109619/)
- [PHP2Shell — Datadog Security Labs](https://securitylabs.datadoghq.com/articles/php2shell-critical-vulnerabilities-in-php/)
- [Synology PHP 8.2 release notes](https://www.synology.com/en-global/releaseNote/PHP8.2)
