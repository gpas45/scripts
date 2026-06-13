#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from fpdf import FPDF
from fpdf.fonts import FontFace

FONT_DIR = "/usr/share/fonts/truetype/dejavu"
PRIMARY = (10, 61, 98)
DARK = (26, 26, 26)
GREY = (90, 90, 90)

CALLOUT = {
    "check": ((238, 247, 238), (46, 125, 50), (46, 125, 50)),   # bg, accent, title
    "note":  ((238, 243, 251), (21, 101, 192), (21, 101, 192)),
    "tip":   ((255, 247, 230), (230, 149, 0), (179, 107, 0)),
    "info":  ((242, 242, 242), (85, 85, 85), (51, 51, 51)),
}


class PDF(FPDF):
    def header(self):
        if self.page_no() == 1:
            return
        self.set_font("DejaVu", "", 8)
        self.set_text_color(*GREY)
        self.cell(0, 6, "Чек-лист настройки маршрутизатора MikroTik", align="L")
        self.ln(8)
        self.set_text_color(*DARK)

    def footer(self):
        self.set_y(-12)
        self.set_font("DejaVu", "", 8)
        self.set_text_color(*GREY)
        self.cell(0, 6, f"Стр. {self.page_no()} — RouterOS v7 — Скоромнов Д. А.", align="C")
        self.set_text_color(*DARK)

    def h2(self, text):
        if self.get_y() > self.h - 45:
            self.add_page()
        self.ln(2)
        self.set_font("DejaVu", "B", 13)
        self.set_text_color(*PRIMARY)
        self.cell(0, 7, text, new_x="LMARGIN", new_y="NEXT")
        y = self.get_y() + 0.5
        self.set_draw_color(*PRIMARY)
        self.set_line_width(0.6)
        self.line(self.l_margin, y, self.w - self.r_margin, y)
        self.ln(2.5)
        self.set_text_color(*DARK)

    def h3(self, text):
        self.ln(1)
        self.set_font("DejaVu", "B", 10.5)
        self.set_text_color(*(44, 62, 80))
        self.cell(0, 5.5, text, new_x="LMARGIN", new_y="NEXT")
        self.set_text_color(*DARK)

    def para(self, text, size=10, gap=1):
        self.set_font("DejaVu", "", size)
        self.multi_cell(0, 5, text, markdown=True, new_x="LMARGIN", new_y="NEXT")
        self.ln(gap)

    def chk(self, text, indent=0):
        if self.get_y() > self.h - 20:
            self.add_page()
        self.set_font("DejaVu", "", 10)
        x0 = self.l_margin + indent * 6
        self.set_x(x0)
        self.cell(6, 5, "☐", new_x="RIGHT", new_y="TOP")
        self.multi_cell(0, 5, text, markdown=True, new_x="LMARGIN", new_y="NEXT")

    def callout(self, kind, title, body):
        bg, accent, tcol = CALLOUT[kind]
        if self.get_y() > self.h - 35:
            self.add_page()
        self.ln(1.5)
        full_w = self.w - self.l_margin - self.r_margin
        y0 = self.get_y()
        # body block (filled)
        self.set_fill_color(*bg)
        self.set_x(self.l_margin)
        self.set_font("DejaVu", "B", 9.5)
        self.set_text_color(*tcol)
        self.multi_cell(full_w, 5, title, fill=True, padding=(2.5, 3, 0.5, 5),
                        new_x="LMARGIN", new_y="NEXT")
        self.set_x(self.l_margin)
        self.set_font("DejaVu", "", 9.5)
        self.set_text_color(*DARK)
        self.multi_cell(full_w, 4.6, body, markdown=True, fill=True,
                        padding=(0.5, 3, 2.5, 5), new_x="LMARGIN", new_y="NEXT")
        y1 = self.get_y()
        # accent bar
        self.set_fill_color(*accent)
        self.rect(self.l_margin, y0, 1.6, y1 - y0, style="F")
        self.ln(2)

    def data_table(self, headings, rows, col_widths, aligns):
        self.set_font("DejaVu", "", 9)
        head_style = FontFace(emphasis="BOLD", color=(255, 255, 255), fill_color=PRIMARY)
        with self.table(col_widths=col_widths, text_align=aligns,
                        headings_style=head_style, line_height=5.5,
                        borders_layout="ALL", cell_fill_color=(245, 245, 245),
                        cell_fill_mode="ROWS") as table:
            hr = table.row()
            for h in headings:
                hr.cell(h)
            for row in rows:
                r = table.row()
                for c in row:
                    r.cell(c)
        self.ln(2)


pdf = PDF(orientation="P", unit="mm", format="A4")
pdf.set_margins(16, 14, 16)
pdf.set_auto_page_break(True, margin=15)
pdf.add_font("DejaVu", "", f"{FONT_DIR}/DejaVuSans.ttf")
pdf.add_font("DejaVu", "B", f"{FONT_DIR}/DejaVuSans-Bold.ttf")
pdf.add_page()

# Title
pdf.set_font("DejaVu", "B", 19)
pdf.set_text_color(*PRIMARY)
pdf.cell(0, 9, "Чек-лист настройки маршрутизатора MikroTik", new_x="LMARGIN", new_y="NEXT")
pdf.set_font("DejaVu", "", 9.5)
pdf.set_text_color(*GREY)
pdf.multi_cell(0, 5, "Документ для проверки результата настройки роутера MikroTik (не пошаговая инструкция).",
               new_x="LMARGIN", new_y="NEXT")
pdf.set_font("DejaVu", "", 9)
pdf.set_text_color(*DARK)
pdf.multi_cell(0, 5, "**Автор:** Скоромнов Дмитрий Анатольевич     **Актуальность:** RouterOS v7     **Печатная редакция:** 2026-06-13",
               markdown=True, new_x="LMARGIN", new_y="NEXT")

pdf.callout("info", "Термины",
            "**WAN** — внешняя сеть (выход в Интернет).    **LAN** — локальная сеть сотрудников.    "
            "**Гостевая сеть** — есть Интернет, нет доступа в LAN.    "
            "**Внешний интерфейс** относится к WAN, **внутренний** — к LAN.")

pdf.h2("1. Подготовка к настройке")
pdf.chk("Подготовить всю необходимую информацию:")
pdf.chk("схемы IP-адресации для внешней, локальной и гостевой сети;", indent=1)
pdf.chk("настройки беспроводной сети: SSID и пароли к ним;", indent=1)
pdf.chk("IP-адреса вышестоящих DNS-серверов, диапазон IP-адресов для DHCP-сервера;", indent=1)
pdf.chk("другую необходимую информацию.", indent=1)
pdf.chk("Установить последнюю версию RouterOS из каналов **Stable** или **Long term**.")
pdf.chk("Установить последнюю версию загрузчика **RouterBOOT**.")
pdf.chk("Удалить всю конфигурацию: сброс настроек **без применения** заводских настроек.")

pdf.h2("2. Базовая настройка")
pdf.chk("Задать пароль для учётной записи администратора.")
pdf.chk("Изменить имя учётной записи администратора (при необходимости).")
pdf.chk("Задать имя устройства (identity).")
pdf.chk("Переименовать внешний интерфейс.")
pdf.chk("Объединить внутренние проводные и беспроводные интерфейсы через **bridge**-интерфейс.")
pdf.chk("Настроить внешний интерфейс (PPPoE / DHCP-клиент / статический IP — по топологии).")
pdf.chk("Назначить IP-адрес bridge-интерфейсу LAN.")
pdf.chk("Добавить маршрут по умолчанию.")
pdf.callout("check", "Контрольная точка №1 — связность по IP",
            "С роутера должен успешно проходить **ping по IP-адресу** до узлов в Интернете: 1.1.1.1, 8.8.8.8, 77.88.8.1, 77.88.8.8.")
pdf.chk("Настроить **DNS-клиента**: прописать вышестоящие DNS-серверы. При необходимости отключить получение адресов DNS по PPPoE/DHCP на внешнем интерфейсе.")
pdf.callout("check", "Контрольная точка №2 — связность по доменам",
            "С роутера должен успешно проходить **ping по доменному имени**: ya.ru, rbc.ru, rg.ru.")
pdf.chk("Настроить **DNS-сервер**: разрешить отвечать на DNS-запросы от других устройств.")
pdf.chk("Настроить **DHCP-сервер** для локальной сети.")
pdf.callout("check", "Контрольная точка №3 — LAN получает настройки",
            "Устройства LAN получают IP по DHCP; проходит ping до внутреннего (192.168.100.1) и внешнего интерфейса роутера. Ping до Интернета **ещё не должен** проходить.")
pdf.chk("Настроить **NAT**: action=src-nat при постоянном IP, иначе action=masquerade.")
pdf.callout("check", "Контрольная точка №4 — выход LAN в Интернет",
            "С устройств LAN проходит ping до Интернета по доменным именам. Если по IP проходит, а по именам — нет, проблема в службе **DNS**.")

pdf.h2("3. Настройка беспроводной сети Wi-Fi")
pdf.para("Шаги одинаковы для каждого используемого диапазона. Отметьте выполнение по столбцам (по наличию радиомодулей):", size=9.5)
wifi_steps = [
    "Переименовать беспроводной интерфейс",
    "Задать SSID",
    "Задать макс. мощность передатчика по регуляторике страны",
    "Активировать использование кадров RTS/CTS",
    "Разрешить самую последнюю поправку к стандарту IEEE 802.11",
    "Задать ширину канала",
    "Задать диапазон(ы) частот по регуляторике страны",
    "Задать способы аутентификации",
    "Задать пароль",
    "Отключить использование WPS",
    "Включить беспроводной интерфейс",
]
pdf.data_table(
    ["Шаг", "2,4 ГГц", "5 ГГц", "6 ГГц"],
    [[s, "☐", "☐", "☐"] for s in wifi_steps],
    col_widths=(64, 12, 12, 12),
    aligns=("LEFT", "CENTER", "CENTER", "CENTER"),
)

pdf.h2("4. Брандмауэр (/ip/firewall/filter)")
pdf.callout("note", "Принцип",
            "Снаружи (трафик из WAN) брандмауэр **нормально закрытый**; изнутри (трафик из LAN) — **нормально открытый**.")
pdf.h3("Цепочка Input")
pdf.chk("правило, разрешающее established- и related-соединения;")
pdf.chk("правило, запрещающее invalid-соединения;")
pdf.chk("правила-исключения: ICMP, VPN-протоколы, списки доверенных IP, port-knocking и др.;")
pdf.chk("правило, отбрасывающее любые соединения, начатые **не из LAN**.")
pdf.h3("Цепочка Forward")
pdf.chk("правило, разрешающее established- и related-соединения;")
pdf.chk("правило, запрещающее invalid-соединения;")
pdf.chk("правило, отбрасывающее соединения, начатые не из LAN и не относящиеся к пробросам портов.")

pdf.h2("5. Дополнительные параметры безопасности")
pdf.chk("Создать список **доверенных интерфейсов** и поместить в него bridge LAN.")
pdf.chk("Разрешить обнаружение «соседей» (neighbor discovery) только для доверенных интерфейсов.")
pdf.chk("Разрешить **MAC-telnet** только для доверенных интерфейсов.")
pdf.chk("Разрешить **WinBox по MAC** только для доверенных интерфейсов.")
pdf.chk("Запретить **MAC-ping**.")
pdf.chk("Отключить **IPv6**, если он не используется.")
pdf.chk("Отключить службы, которые не будут использоваться.")

pdf.h2("6. Прочие обязательные шаги")
pdf.chk("Настроить **NTP-клиента** (служба времени).")
pdf.chk("Сделать резервное копирование (backup + export) и **вынести копии за пределы роутера**. Выполнять **после** шагов из раздела 7.")
pdf.callout("tip", "Автоматизация бэкапа",
            "Пункт «backup + export наружу» автоматизирует скрипт **BackupAndUpdate.rsc** (routeros/): ежедневный бэкап системы и конфигурации на e-mail плюс автообновление RouterOS/RouterBOARD.")

pdf.h2("7. Прочие шаги (по необходимости)")
pdf.chk("Настроить пробросы портов.")
pdf.chk("Настроить гостевые Wi-Fi: отдельный bridge, при необходимости DHCP-сервер, VLAN и др.")
pdf.chk("Настроить приоритизацию трафика (**QoS**) — в базовом виде равномерное распределение канала при нехватке ресурсов.")
pdf.chk("Учесть в QoS использование гостевых беспроводных сетей.")

pdf.h2("Связанные скрипты в репозитории")
pdf.data_table(
    ["Раздел чек-листа", "Скрипт"],
    [
        ["Базовая настройка, отключение небезопасных сервисов, NTP, identity", "autorun.rsc"],
        ["Bridge, interface-lists, firewall (port-knocking, ICMP), NAT, DNS, харднинг, OSPF", "initial-setup.rsc"],
        ["Свежий RouterOS из Stable/Long-term, backup + export наружу", "BackupAndUpdate.rsc"],
        ["Автообновление прошивки RouterBOARD", "routerboard_fwupgrade"],
        ["Резервирование двух провайдеров (dual-WAN)", "check-isp.rsc"],
    ],
    col_widths=(120, 58),
    aligns=("LEFT", "LEFT"),
)

pdf.ln(2)
pdf.set_font("DejaVu", "", 8)
pdf.set_text_color(*GREY)
pdf.multi_cell(0, 4, "Источник: «Чек-лист по настройке маршрутизатора MikroTik», Скоромнов Д. А.  •  "
                     "Печатная редакция собрана из заметки routeros/docs/check-list-router-obsidian.md",
               new_x="LMARGIN", new_y="NEXT")

out = "/home/user/scripts/routeros/docs/check-list-router-print.pdf"
pdf.output(out)
print("WROTE", out)
