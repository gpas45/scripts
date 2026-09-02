#!/bin/sh
# meta-routes.sh — маршруты на сети Meta (Instagram, Facebook, WhatsApp)
# через выбранный шлюз или интерфейс.
#
# Основной формат вывода (route add):
#   sh meta-routes.sh route                  # шлюз 0.0.0.0
#   sh meta-routes.sh route 192.168.1.2      # свой шлюз
#   sh meta-routes.sh route-del 0.0.0.0      # снятие маршрутов
#
# Формат Keenetic CLI (ip route ... auto) — для веб-CLI роутера
# (Управление -> Диагностика -> Командная строка):
#   sh meta-routes.sh cli Wireguard0
#   sh meta-routes.sh cli-del Wireguard0
#
# Применение прямо на роутере Keenetic (нужен Entware, работает через ndmc):
#   sh /opt/scripts/meta-routes.sh add Wireguard0
#   sh /opt/scripts/meta-routes.sh del Wireguard0
#   sh /opt/scripts/meta-routes.sh show Wireguard0
#
# Имя интерфейса смотрите командой `show interface` в CLI роутера:
# Wireguard0, OpenVPN0, L2TP0, PPTP0, Proxy0, ISP и т.п.
#
# Переменные окружения:
#   META_SCOPE=core  — только диапазоны, достоверно принадлежащие Meta
#   META_SCOPE=all   — весь исходный список (по умолчанию)
#   NDMC=/opt/bin/ndmc — путь к ndmc, если он не в PATH

set -eu

IFACE_DEFAULT="Wireguard0"
GATEWAY_DEFAULT="0.0.0.0"
SCOPE="${META_SCOPE:-all}"

usage() {
    cat <<'USAGE'
Использование: meta-routes.sh <команда> [шлюз|интерфейс]

  route     [шлюз]    route add <сеть> mask <маска> <шлюз>      (по умолчанию 0.0.0.0)
  route-del [шлюз]    route delete <сеть> mask <маска> <шлюз>
  cli       [iface]   ip route <сеть> <маска> <iface> auto      (Keenetic CLI)
  cli-del   [iface]   no ip route <сеть> <маска> <iface>
  add       [iface]   применить маршруты на роутере через ndmc и сохранить
  del       [iface]   снять маршруты на роутере через ndmc и сохранить
  show      [iface]   показать маршруты роутера на этом интерфейсе
  list                список сетей (сеть, маска, область, комментарий)

Область (META_SCOPE): core — только сети Meta, all — весь исходный список.
USAGE
}

# Список Meta: <сеть> <маска> <область> <комментарий>
# Порядок и состав — как в исходном списке, без объединения подсетей:
# перекрытия допустимы, более специфичный маршрут выигрывает у более общего.
#
# core  — диапазоны Meta (AS32934 / AS63293 и их анонсы);
# extra — записи, которые Meta не принадлежат либо шире её реальных
#         выделений: в туннель их заворачивать не обязательно, а для
#         Google-сетей — вредно (уедут и другие сервисы).
nets() {
    cat <<'NETS'
157.240.253.174 255.255.255.255 core узел Meta
157.240.253.172 255.255.255.255 core узел Meta
157.240.253.167 255.255.255.255 core узел Meta
157.240.253.63 255.255.255.255 core узел Meta
157.240.253.32 255.255.255.255 core узел Meta
157.240.252.174 255.255.255.255 core узел Meta
157.240.252.172 255.255.255.255 core узел Meta
157.240.252.167 255.255.255.255 core узел Meta
157.240.252.63 255.255.255.255 core узел Meta
157.240.252.38 255.255.255.255 core узел Meta
57.144.112.34 255.255.255.255 core узел Meta
57.144.110.1 255.255.255.255 core узел Meta
157.240.205.174 255.255.255.255 core узел Meta
87.245.223.97 255.255.255.255 extra узел, проверьте принадлежность
213.102.128.0 255.255.255.0 extra Telia, не только Meta
204.15.20.0 255.255.252.0 core Meta
199.201.0.0 255.255.0.0 core Meta (реально выделено 199.201.64.0/22)
185.89.0.0 255.255.0.0 core Meta
185.60.0.0 255.255.0.0 core Meta
179.60.0.0 255.255.0.0 core Meta
173.252.0.0 255.255.0.0 core Meta
164.163.191.64 255.255.255.192 core Meta
163.114.0.0 255.255.0.0 core Meta
163.77.128.0 255.255.128.0 core Meta
163.70.0.0 255.255.0.0 core Meta
157.240.0.0 255.255.0.0 core Meta
147.75.0.0 255.255.0.0 extra Equinix Metal, не только Meta
142.250.0.0 255.254.0.0 extra Google, НЕ Meta
129.134.0.0 255.255.0.0 core Meta
103.4.0.0 255.255.0.0 core Meta
102.221.0.0 255.255.0.0 core Meta
102.132.0.0 255.255.0.0 core Meta
99.84.0.0 255.255.0.0 extra AWS CloudFront, не только Meta
87.245.208.0 255.255.255.0 extra проверьте принадлежность
74.119.0.0 255.255.0.0 core Meta
69.171.0.0 255.255.0.0 core Meta
69.63.0.0 255.255.0.0 core Meta
66.220.0.0 255.255.0.0 core Meta
45.64.0.0 255.255.0.0 core Meta
31.13.0.0 255.255.0.0 core Meta
157.240.0.0 255.255.255.0 core Meta
157.240.251.0 255.255.255.0 core Meta
157.240.205.0 255.255.255.0 core Meta
173.194.10.0 255.255.255.0 extra Google, НЕ Meta
77.240.43.0 255.255.255.0 extra проверьте принадлежность
57.144.222.0 255.255.255.0 core Meta
45.130.4.0 255.255.255.0 extra проверьте принадлежность
57.144.96.0 255.255.224.0 core Meta
57.144.244.0 255.255.255.0 core Meta
157.240.201.0 255.255.255.0 core Meta
31.13.72.0 255.255.255.0 core Meta
57.144.248.0 255.255.255.0 core Meta
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

# Печатает команды route: gen_route <add|delete> <шлюз>
gen_route() {
    route_action="$1"
    route_gw="$2"
    selected_nets | while read -r net mask; do
        printf 'route %s %s mask %s %s\n' "$route_action" "$net" "$mask" "$route_gw"
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

# Выполняет команды Keenetic CLI на роутере: apply <add|del> <интерфейс>
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
target="${2:-}"

case "$action" in
    route)
        gen_route add "${target:-$GATEWAY_DEFAULT}"
        ;;
    route-del)
        gen_route delete "${target:-$GATEWAY_DEFAULT}"
        ;;
    cli)
        gen_cmds add "${target:-$IFACE_DEFAULT}"
        ;;
    cli-del)
        gen_cmds del "${target:-$IFACE_DEFAULT}"
        ;;
    add|del)
        apply "$action" "${target:-$IFACE_DEFAULT}"
        ;;
    show)
        show_iface="${target:-$IFACE_DEFAULT}"
        if ndmc_bin="$(find_ndmc)"; then
            "$ndmc_bin" -c "show ip route" | grep -i "$show_iface" \
                || echo "Маршрутов через $show_iface нет."
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
