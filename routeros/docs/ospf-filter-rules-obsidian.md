---
title: OSPF Filter Rules — фильтры маршрутов на MikroTik
tags:
  - mikrotik
  - routeros
  - ospf
  - routing
  - script
created: 2026-06-13
aliases:
  - ospf_filter_rules
  - OSPF filter rules
---

# OSPF Filter Rules — фильтры маршрутов на MikroTik

Конфиг [[ospf_filter_rules]] (`routeros/ospf_filter_rules`) создаёт цепочки `/routing filter rule`, которые пропускают в OSPF и из OSPF **только частные сети RFC1918**, а всё остальное отбрасывают. Для RouterOS **7.x**.

> [!info] Назначение
> Не дать «протечь» в домен маршрутизации публичным префиксам, default-route и чужим сетям. Полезно, когда OSPF поднимается между доверенными площадками, но рядом есть аплинки в интернет.

> [!warning] Сами по себе правила ничего не делают
> Цепочки `ospf-in`/`ospf-out` работают только после привязки к OSPF-инстансу через `in-filter-chain`/`out-filter-chain`. Без привязки фильтрация не применяется.

---

## Что делает конфиг

| Цепочка | Действие |
|---|---|
| `ospf-in` | Принимать из OSPF только `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`; остальное — явный `reject`. |
| `ospf-out` | Отдавать (redistribute) в OSPF только те же RFC1918-сети; остальное — явный `reject`. |

Диапазоны `dst-len` подобраны под классы:
- `10.0.0.0/8` → `dst-len 8-32`
- `172.16.0.0/12` → `dst-len 12-32`
- `192.168.0.0/16` → `dst-len 16-32`

> [!note] Явный reject — для самодокументируемости
> У `/routing filter` поведение по умолчанию и так «reject». Финальное правило `reject;` добавлено явно, чтобы намерение читалось из конфига.

---

## Установка

> [!tip] Импорт файла
> 1. Залить `ospf_filter_rules` в **Files** или скачать на роутер:
>    ```routeros
>    /tool fetch url="https://raw.githubusercontent.com/gpas45/scripts/main/routeros/ospf_filter_rules"
>    ```
> 2. Импортировать (создаст правила фильтра):
>    ```routeros
>    /import file-name=ospf_filter_rules
>    ```

### Привязать цепочки к инстансу

Имя инстанса смотрите в выводе `print`:

```routeros
/routing ospf instance print
/routing ospf instance set [find name="default"] \
    in-filter-chain=ospf-in out-filter-chain=ospf-out
```

---

## Проверка результата

```routeros
/routing filter rule print
/routing ospf instance print
/ip route print where ospf
```

> [!success] Ожидаемый результат
> В таблице OSPF-маршрутов остаются только RFC1918-сети; публичные префиксы и default-route не проникают и не анонсируются.

---

## Подсказки и тонкая настройка

> [!tip] Резать слишком специфичные маршруты
> Чтобы не принимать, например, хостовые `/32`, ужесточите верхнюю границу `dst-len`:
> ```routeros
> rule="if (dst in 10.0.0.0/8 && dst-len in 8-24) {accept;}"
> ```

> [!bug]- Маршруты не фильтруются
> Скорее всего цепочки не привязаны к инстансу. Проверьте `in-filter-chain`/`out-filter-chain` в `/routing ospf instance print`.

> [!bug]- Пропал нужный маршрут
> Если легитимная сеть не входит в RFC1918 (например, публичный префикс между площадками), добавьте под неё отдельное `accept`-правило **выше** финального `reject`.

---

## Связанные заметки

- [[initial-setup-obsidian|initial-setup]] — содержит встроенный вариант OSPF-фильтров
- [[autorun-obsidian|autorun]] — первичная настройка роутера
