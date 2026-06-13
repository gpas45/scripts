---
title: RouterBOARD Star Wars — имперский марш на старте MikroTik
tags:
  - mikrotik
  - routeros
  - scheduler
  - fun
  - script
created: 2026-06-13
aliases:
  - routerboard_starwars
  - imperial march
---

# RouterBOARD Star Wars — имперский марш на старте MikroTik

Конфиг [[routerboard_starwars]] (`routeros/routerboard_starwars`) создаёт scheduler, который при загрузке роутера проигрывает на встроенном динамике мелодию имперского марша из «Звёздных войн».

> [!info] Назначение
> Чисто развлекательный «звуковой индикатор» завершения загрузки — приятно слышать, что роутер поднялся. Никакой функциональной нагрузки.

> [!warning] Требования
> - Устройство со встроенным **beeper'ом** (динамиком). На моделях без него `:beep` ничего не сделает.
> - Права scheduler: `reboot,read,write`.

---

## Что делает конфиг

Создаёт scheduler `starwars` с `start-time=startup`. На старте:
1. `:delay 15` — пауза, чтобы дождаться завершения загрузки.
2. Серия `:beep` с разными частотами/длительностями — узнаваемая тема имперского марша.

```routeros
/system scheduler print where name=starwars
```

---

## Установка

> [!tip] Импорт файла
> 1. Залить `routerboard_starwars` в **Files** или скачать на роутер:
>    ```routeros
>    /tool fetch url="https://raw.githubusercontent.com/gpas45/scripts/main/routeros/routerboard_starwars"
>    ```
> 2. Импортировать (создаст scheduler):
>    ```routeros
>    /import file-name=routerboard_starwars
>    ```

---

## Проверить звук, не перезагружая роутер

Можно проиграть мелодию вручную, скопировав тело `on-event` в терминал, либо коротко проверить, что динамик вообще работает:

```routeros
:beep frequency=500 length=500ms
```

> [!success] Что услышишь
> Через ~15 секунд после загрузки роутер сыграет узнаваемую тему. Если тихо — у модели, скорее всего, нет встроенного динамика.

---

## Удаление

```routeros
/system scheduler remove [find name=starwars]
```

---

## Связанные заметки

- [[routerboard-fwupgrade-obsidian|RouterBOARD Firmware Auto-Upgrade]] — другой scheduler на `start-time=startup`
- [[autorun-obsidian|autorun]] · [[initial-setup-obsidian|initial-setup]]
