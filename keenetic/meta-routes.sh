#!/bin/sh
# meta-routes.sh — статические маршруты на сети Meta (Instagram, Facebook,
# WhatsApp) через выбранный интерфейс Keenetic (VPN, прокси, второй провайдер).
#
# Роутер с Entware (запуск по SSH):
#   sh /opt/scripts/meta-routes.sh add Wireguard0    # добавить маршруты
#   sh /opt/scripts/meta-routes.sh del Wireguard0    # снять маршруты
#   sh /opt/scripts/meta-routes.sh show Wireguard0   # показать текущие маршруты
#
# Роутер без Entware (нет USB): выполните на любой машине
#   sh meta-routes.sh cli Wireguard0
# и вставьте вывод в веб-CLI роутера: Управление -> Диагностика ->
# Командная строка (или по telnet/ssh на сам роутер).
#
# Имя интерфейса смотрите командой `show interface` в CLI роутера:
# Wireguard0, OpenVPN0, L2TP0, PPTP0, Proxy0, ISP и т.п.
#
# Переменные окружения:
#   META_SCOPE=core  — только диапазоны, достоверно принадлежащие Meta
#   META_SCOPE=all   — плюс спорные сети из исходного списка (по умолчанию)
#   NDMC=/opt/bin/ndmc — путь к ndmc, если он не в PATH

set -eu

IFACE_DEFAULT="Wireguard0"
SCOPE="${META_SCOPE:-all}"

usage() {
    cat <<'USAGE'
Использование: meta-routes.sh <add|del|cli|show|list> [интерфейс]

  add  <iface>  добавить маршруты через ndmc и сохранить конфигурацию
  del  <iface>  удалить маршруты через ndmc и сохранить конфигурацию
  cli  <iface>  напечатать команды для вставки в веб-CLI (ничего не меняет)
  show <iface>  показать статические маршруты роутера на этом интерфейсе
  list          напечатать список сетей (сеть, маска, область, комментарий)

Область (META_SCOPE): core — только сети Meta, all — весь исходный список.
USAGE
}

# Сети Meta: <сеть> <маска> <область> <комментарий>
# core  — диапазоны Meta (AS32934 / AS63293 и их анонсы);
# extra — сети из исходного списка, которые Meta не принадлежат или шире её
#         реальных выделений: заворачивать их в VPN не обязательно, а иногда
#         вредно (Google, AWS CloudFront и т.д.).
nets() {
    cat <<'NETS'
31.13.0.0 255.255.0.0 core Meta
45.64.0.0 255.255.0.0 core Meta
57.144.96.0 255.255.224.0 core Meta (включает 57.144.110.1, 57.144.112.34)
57.144.222.0 255.255.255.0 core Meta
57.144.244.0 255.255.255.0 core Meta
57.144.248.0 255.255.255.0 core Meta
66.220.0.0 255.255.0.0 core Meta
69.63.0.0 255.255.0.0 core Meta
69.171.0.0 255.255.0.0 core Meta
74.119.0.0 255.255.0.0 core Meta
102.132.0.0 255.255.0.0 core Meta
102.221.0.0 255.255.0.0 core Meta
103.4.0.0 255.255.0.0 core Meta
129.134.0.0 255.255.0.0 core Meta
157.240.0.0 255.255.0.0 core Meta (включает все узлы 157.240.x.x из списка)
163.70.0.0 255.255.0.0 core Meta
163.77.128.0 255.255.128.0 core Meta
163.114.0.0 255.255.0.0 core Meta
164.163.191.64 255.255.255.192 core Meta
173.252.0.0 255.255.0.0 core Meta
179.60.0.0 255.255.0.0 core Meta
185.60.0.0 255.255.0.0 core Meta
185.89.0.0 255.255.0.0 core Meta
199.201.0.0 255.255.0.0 core Meta (у Meta реально 199.201.64.0/22)
204.15.20.0 255.255.252.0 core Meta
45.130.4.0 255.255.255.0 extra из исходного списка, проверьте
77.240.43.0 255.255.255.0 extra из исходного списка, проверьте
87.245.208.0 255.255.255.0 extra из исходного списка, проверьте
87.245.223.97 255.255.255.255 extra отдельный узел, вне 87.245.208.0/24
99.84.0.0 255.255.0.0 extra AWS CloudFront, не только Meta
142.250.0.0 255.254.0.0 extra Google, НЕ Meta
147.75.0.0 255.255.0.0 extra Equinix Metal, не только Meta
173.194.10.0 255.255.255.0 extra Google, НЕ Meta
213.102.128.0 255.255.255.0 extra Telia, не только Meta
NETS
}

# Печатает "сеть маска" с учётом META_SCOPE.
selected_nets() {
    nets | while read -r net mask scope _rest; do
        [ -n "$net" ] || continue
        if [ "$SCOPE" = "core" ] && [ "$scope" != "core" ]; then
            continue
        fi
        printf '%s %s\n' "$net" "$mask"
    done
}

# Печатает команды Keenetic CLI: gen_cmds <add|del> <интерфейс>
gen_cmds() {
    gen_action="$1"
    gen_iface="$2"
    selected_nets | while read -r net mask; do
        if [ "$gen_action" = "add" ]; then
            printf 'ip route %s %s %s auto\n' "$net" "$mask" "$gen_iface"
        else
            printf 'no ip route %s %s %s\n' "$net" "$mask" "$gen_iface"
        fi
    done
    printf 'system configuration save\n'
}

find_ndmc() {
    if [ -n "${NDMC:-}" ]; then
        printf '%s\n' "$NDMC"
        return 0
    fi
    for candidate in ndmc /opt/bin/ndmc /opt/sbin/ndmc /bin/ndmc /usr/bin/ndmc; do
        if command -v "$candidate" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# Выполняет сгенерированные команды на роутере: apply <add|del> <интерфейс>
apply() {
    apply_action="$1"
    apply_iface="$2"
    if ! ndmc_bin="$(find_ndmc)"; then
        echo "Ошибка: не найден ndmc — скрипт запущен не на роутере Keenetic." >&2
        echo "Используйте: sh $0 cli $apply_iface  и вставьте вывод в веб-CLI." >&2
        exit 1
    fi
    if ! "$ndmc_bin" -c "show interface $apply_iface" >/dev/null 2>&1; then
        echo "Ошибка: интерфейс '$apply_iface' на роутере не найден." >&2
        echo "Список интерфейсов: $ndmc_bin -c 'show interface'" >&2
        exit 1
    fi

    tmp="${TMPDIR:-/tmp}/meta-routes.$$"
    gen_cmds "$apply_action" "$apply_iface" > "$tmp"
    count=0
    while read -r cmd; do
        [ -n "$cmd" ] || continue
        count=$((count + 1))
        printf '[%02d] %s\n' "$count" "$cmd"
        if ! "$ndmc_bin" -c "$cmd" >/dev/null; then
            echo "Ошибка при выполнении: $cmd" >&2
            rm -f "$tmp"
            exit 1
        fi
    done < "$tmp"
    rm -f "$tmp"
    echo "Готово: обработано команд — $count, конфигурация сохранена."
}

action="${1:-}"
iface="${2:-$IFACE_DEFAULT}"

case "$action" in
    add|del)
        apply "$action" "$iface"
        ;;
    cli)
        gen_cmds add "$iface"
        ;;
    show)
        if ndmc_bin="$(find_ndmc)"; then
            "$ndmc_bin" -c "show ip route" | grep -i "$iface" || echo "Маршрутов через $iface нет."
        else
            echo "Ошибка: не найден ndmc — команда доступна только на роутере." >&2
            exit 1
        fi
        ;;
    list)
        nets
        ;;
    ""|-h|--help|help)
        usage
        ;;
    *)
        echo "Неизвестная команда: $action" >&2
        usage >&2
        exit 1
        ;;
esac
