// pg-status — состояние экземпляров PostgreSQL / Postgres Pro на хосте.
//
// Read-only утилита: ничего не меняет, только показывает.
//   - обнаруживает экземпляры (кластеры) на машине:
//     Postgres Pro 1C: postgrespro-<ver> (default), -<имя> (legacy), @<порт> (шаблон);
//     обычный PostgreSQL: postgresql@<ver>-<cluster> (схема Debian/Ubuntu);
//   - для каждого: запущен/остановлен, порт, каталог данных и его размер на диске;
//   - если запущен — подключается через psql (peer-auth от postgres) и собирает:
//     версию, аптайм, число соединений, суммарный вес БД, cache hit ratio,
//     commit/rollback и список баз с размерами (по убыванию).
//
// Статистика собирается только от root или пользователя postgres (peer-аутентификация).
// Информацию из systemd и размер каталога данных видно и без этого.
//
// Сборка:  go build -o pg-status .
// Запуск:  ./pg-status                 # все найденные экземпляры
//
//	./pg-status 5433            # фильтр по подстроке (имя/порт)
//	./pg-status -p 5432         # напрямую опросить порт (без обхода systemd)
//	./pg-status -p 5433 -bin /opt/pgpro/1c-18/bin
package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	pgproBase  = "/opt/pgpro"
	systemdDir = "/etc/systemd/system"
)

// ── Цвета (отключаются вне терминала, при NO_COLOR и по флагу) ──
type palette struct {
	bold, dim, red, green, yellow, blue, nc string
}

var c palette

func setupColors(enabled bool) {
	if enabled {
		c = palette{"\033[1m", "\033[2m", "\033[0;31m", "\033[0;32m",
			"\033[0;33m", "\033[0;34m", "\033[0m"}
	}
}

// ── Как запускать psql от postgres ──
var (
	runAsPG  []string // префикс argv (runuser/sudo) или nil
	canQuery bool
)

func setupPrivileges() {
	if u, err := user.Current(); err == nil && u.Username == "postgres" {
		canQuery = true
		return
	}
	if os.Geteuid() == 0 {
		if p, err := exec.LookPath("runuser"); err == nil {
			runAsPG = []string{p, "-u", "postgres", "--"}
			canQuery = true
		} else if p, err := exec.LookPath("sudo"); err == nil {
			runAsPG = []string{p, "-u", "postgres", "--"}
			canQuery = true
		}
	}
}

// ── Мелкие утилиты ──

// human — человекочитаемый размер из байтов
func human(b int64) string {
	if b < 0 {
		return "—"
	}
	units := []string{"B", "KiB", "MiB", "GiB", "TiB", "PiB"}
	f := float64(b)
	i := 0
	for f >= 1024 && i < len(units)-1 {
		f /= 1024
		i++
	}
	if i == 0 {
		return fmt.Sprintf("%d%s", b, units[0])
	}
	return fmt.Sprintf("%.1f%s", f, units[i])
}

// duration — «Nд Nч Nм» из секунд
func duration(sec int64) string {
	if sec < 0 {
		return "—"
	}
	d := sec / 86400
	h := (sec % 86400) / 3600
	m := (sec % 3600) / 60
	var b strings.Builder
	if d > 0 {
		fmt.Fprintf(&b, "%dд ", d)
	}
	if d > 0 || h > 0 {
		fmt.Fprintf(&b, "%dч ", h)
	}
	fmt.Fprintf(&b, "%dм", m)
	return b.String()
}

// output — stdout команды без stderr; пустая строка при ошибке
func output(name string, args ...string) string {
	out, err := exec.Command(name, args...).Output()
	if err != nil {
		return ""
	}
	return string(out)
}

// outputAny — stdout команды даже при ненулевом коде возврата.
// Нужно для systemctl is-active: у остановленного юнита он печатает
// «inactive»/«failed», но завершается с ненулевым статусом.
func outputAny(name string, args ...string) string {
	out, _ := exec.Command(name, args...).Output()
	return string(out)
}

// dirBytes — размер каталога на диске (du -sb); -1 при недоступности
func dirBytes(path string) int64 {
	if path == "" {
		return -1
	}
	if fi, err := os.Stat(path); err != nil || !fi.IsDir() {
		return -1
	}
	out := output("du", "-sb", path)
	fields := strings.Fields(out)
	if len(fields) == 0 {
		return -1
	}
	v, err := strconv.ParseInt(fields[0], 10, 64)
	if err != nil {
		return -1
	}
	return v
}

// ── Обнаружение экземпляров ──

var (
	reProUnit = regexp.MustCompile(`^postgrespro-(1c-[0-9]+)`)
	rePgUnit  = regexp.MustCompile(`^postgresql@([0-9]+)-(.+)$`)
)

// collectUnits — имена юнитов всех экземпляров (без .service), объединённые и dedup
func collectUnits() []string {
	set := map[string]bool{}

	add := func(name string) {
		name = strings.TrimSuffix(name, ".service")
		if name == "" || !strings.Contains(name, "postgres") {
			return
		}
		if strings.HasSuffix(name, "@") { // шаблонный юнит, не экземпляр
			return
		}
		set[name] = true
	}

	// 1. загруженные/активные юниты обеих линеек
	out := output("systemctl", "list-units", "--all", "--type=service",
		"--no-legend", "--no-pager", "postgres*")
	sc := bufio.NewScanner(strings.NewReader(out))
	for sc.Scan() {
		// строка может начинаться с маркера ● (failed) — берём поле, оканчивающееся .service
		for _, f := range strings.Fields(sc.Text()) {
			if strings.HasSuffix(f, ".service") {
				add(f)
				break
			}
		}
	}

	// 2. включённые шаблонные @-экземпляры (могут быть остановлены)
	if m, _ := filepath.Glob(filepath.Join(systemdDir, "*.wants", "postgrespro-*@*.service")); m != nil {
		for _, f := range m {
			add(filepath.Base(f))
		}
	}
	// 3. per-instance drop-in каталоги шаблонных экземпляров
	if m, _ := filepath.Glob(filepath.Join(systemdDir, "postgrespro-*@*.service.d")); m != nil {
		for _, d := range m {
			add(strings.TrimSuffix(filepath.Base(d), ".d"))
		}
	}

	names := make([]string, 0, len(set))
	for n := range set {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// engineLabel — человекочитаемая метка «движка» по имени юнита
func engineLabel(unit string) string {
	if m := reProUnit.FindStringSubmatch(unit); m != nil {
		return "Postgres Pro " + m[1]
	}
	if m := rePgUnit.FindStringSubmatch(unit); m != nil {
		return fmt.Sprintf("PostgreSQL %s (%s)", m[1], m[2])
	}
	return unit
}

// unitBin — каталог bin для psql нужной сборки (пусто -> psql из PATH)
func unitBin(unit string) string {
	if m := reProUnit.FindStringSubmatch(unit); m != nil {
		return filepath.Join(pgproBase, m[1], "bin")
	}
	return ""
}

// unitPID — MainPID работающего юнита (0, если не запущен)
func unitPID(unit string) int {
	v := strings.TrimSpace(output("systemctl", "show", unit, "-p", "MainPID", "--value"))
	pid, _ := strconv.Atoi(v)
	return pid
}

// showProp — значение systemctl show -p <prop> (строка «prop=value» без префикса)
func showProp(unit, prop string) string {
	out := strings.TrimSpace(output("systemctl", "show", unit, "-p", prop, "--no-pager"))
	return strings.TrimPrefix(out, prop+"=")
}

// unitPGDATA — каталог данных: -D процесса -> Environment=PGDATA -> EnvironmentFile
func unitPGDATA(unit string, pid int) string {
	if pid > 0 {
		if raw, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid)); err == nil {
			args := strings.Split(string(raw), "\x00")
			for i, a := range args {
				if a == "-D" && i+1 < len(args) {
					return args[i+1]
				}
			}
		}
	}
	for _, tok := range strings.Fields(showProp(unit, "Environment")) {
		if v, ok := strings.CutPrefix(tok, "PGDATA="); ok {
			return v
		}
	}
	// EnvironmentFiles: "path (ignore_errors=no) path2 (...)" — per-instance идёт последним
	efLine := showProp(unit, "EnvironmentFiles")
	efLine = regexp.MustCompile(`\s*\(ignore_errors=[^)]*\)`).ReplaceAllString(efLine, "")
	last := ""
	for _, ef := range strings.Fields(efLine) {
		f, err := os.Open(ef)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if v, ok := strings.CutPrefix(line, "PGDATA="); ok {
				last = v
			}
		}
		f.Close()
	}
	return last
}

// portFromPID — порт, на котором слушает postmaster (по MainPID через ss)
func portFromPID(pid int) string {
	if pid <= 0 {
		return ""
	}
	out := output("ss", "-ltnp")
	needle := fmt.Sprintf("pid=%d,", pid)
	sc := bufio.NewScanner(strings.NewReader(out))
	ports := map[string]bool{}
	for sc.Scan() {
		line := sc.Text()
		if !strings.Contains(line, needle) {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		local := fields[3] // Local Address:Port
		if i := strings.LastIndex(local, ":"); i >= 0 {
			p := local[i+1:]
			if _, err := strconv.Atoi(p); err == nil {
				ports[p] = true
			}
		}
	}
	// наименьший (postmaster обычно слушает один порт)
	best := ""
	for p := range ports {
		if best == "" || len(p) < len(best) || (len(p) == len(best) && p < best) {
			best = p
		}
	}
	return best
}

var rePortConf = regexp.MustCompile(`^\s*port\s*=\s*([0-9]+)`)

// unitPort — слушающий сокет -> postgresql.conf -> systemd PGPORT -> «5432?»
func unitPort(unit string, pid int, datadir string) string {
	if p := portFromPID(pid); p != "" {
		return p
	}
	if datadir != "" {
		if f, err := os.Open(filepath.Join(datadir, "postgresql.conf")); err == nil {
			var found string
			sc := bufio.NewScanner(f)
			for sc.Scan() {
				if m := rePortConf.FindStringSubmatch(sc.Text()); m != nil {
					found = m[1] // последнее вхождение имеет приоритет
				}
			}
			f.Close()
			if found != "" {
				return found
			}
		}
	}
	for _, tok := range strings.Fields(showProp(unit, "Environment")) {
		if v, ok := strings.CutPrefix(tok, "PGPORT="); ok {
			return v
		}
	}
	return "5432?"
}

// ── Запрос к серверу через psql ──

// psqlQuery — строки результата (поля разделены табуляцией); nil при ошибке
func psqlQuery(bin, port, sql string) [][]string {
	cmd := "psql"
	if bin != "" {
		if p := filepath.Join(bin, "psql"); fileExecutable(p) {
			cmd = p
		}
	}
	argv := append([]string{}, runAsPG...)
	argv = append(argv, cmd, "-X", "-A", "-F", "\t", "-t", "-q",
		"-p", port, "-d", "postgres", "-c", sql)

	out, err := exec.Command(argv[0], argv[1:]...).Output()
	if err != nil {
		return nil
	}
	var rows [][]string
	sc := bufio.NewScanner(strings.NewReader(string(out)))
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for sc.Scan() {
		line := sc.Text()
		if strings.TrimSpace(line) == "" {
			continue
		}
		rows = append(rows, strings.Split(line, "\t"))
	}
	return rows
}

func fileExecutable(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && !fi.IsDir() && fi.Mode()&0111 != 0
}

const scalarsSQL = `SELECT current_setting('server_version'),
        extract(epoch from pg_postmaster_start_time())::bigint,
        (SELECT count(*) FROM pg_stat_activity),
        current_setting('max_connections'),
        (SELECT count(*) FROM pg_stat_activity WHERE state='active'),
        (SELECT coalesce(sum(pg_database_size(datname)),0) FROM pg_database),
        (SELECT coalesce(round(100.0*sum(blks_hit)/nullif(sum(blks_hit)+sum(blks_read),0),1),0) FROM pg_stat_database),
        (SELECT coalesce(sum(xact_commit),0) FROM pg_stat_database),
        (SELECT coalesce(sum(xact_rollback),0) FROM pg_stat_database);`

const dbListSQL = `SELECT datname, pg_database_size(datname), datistemplate::int
   FROM pg_database ORDER BY pg_database_size(datname) DESC;`

// ── Вывод одного экземпляра ──

type instance struct {
	unit, bin, port, active, pgdata string
}

func reportInstance(in instance) {
	label := engineLabel(in.unit)

	var stColor, stText string
	switch in.active {
	case "active":
		stColor, stText = c.green, "● запущен"
	case "failed":
		stColor, stText = c.red, "✗ сбой"
	case "inactive":
		stColor, stText = c.yellow, "○ остановлен"
	default:
		stColor, stText = c.yellow, "○ "+in.active
	}

	fmt.Println()
	fmt.Printf("%s%s%s  %s(%s)%s\n", c.bold, label, c.nc, c.dim, in.unit, c.nc)
	fmt.Printf("  Статус:        %s%s%s   порт %s%s%s\n", stColor, stText, c.nc, c.bold, in.port, c.nc)
	pgdata := in.pgdata
	if pgdata == "" {
		pgdata = "—"
	}
	fmt.Printf("  Каталог:       %s\n", pgdata)

	// Размер каталога данных (виден и у остановленного экземпляра)
	if disk := dirBytes(in.pgdata); disk >= 0 {
		fmt.Printf("  Размер на ФС:  %s\n", human(disk))
	} else if in.pgdata != "" {
		fmt.Printf("  Размер на ФС:  %sнет доступа (нужен root)%s\n", c.dim, c.nc)
	}

	if in.active != "active" {
		return
	}
	if !canQuery {
		fmt.Printf("  %sСтатистика: запустите от root или postgres%s\n", c.dim, c.nc)
		return
	}

	rows := psqlQuery(in.bin, in.port, scalarsSQL)
	if len(rows) == 0 || len(rows[0]) < 9 {
		fmt.Printf("  %sНе удалось подключиться (peer-auth от postgres, порт %s)%s\n", c.yellow, in.port, c.nc)
		return
	}
	r := rows[0]
	ver, start := r[0], r[1]
	conns, maxConns, activeQ := r[2], r[3], r[4]
	total, hit, commit, rollback := r[5], r[6], r[7], r[8]

	startSec, _ := strconv.ParseInt(strings.SplitN(start, ".", 2)[0], 10, 64)
	up := duration(time.Now().Unix() - startSec)
	totalBytes, _ := strconv.ParseInt(total, 10, 64)

	fmt.Printf("  Версия:        %s\n", ver)
	fmt.Printf("  Аптайм:        %s\n", up)
	fmt.Printf("  Соединения:    %s / %s   (активных запросов: %s)\n", conns, maxConns, activeQ)
	fmt.Printf("  Суммарно БД:   %s%s%s\n", c.bold, human(totalBytes), c.nc)
	fmt.Printf("  Cache hit:     %s%%   commit: %s   rollback: %s\n", hit, commit, rollback)

	dbs := psqlQuery(in.bin, in.port, dbListSQL)
	if len(dbs) == 0 {
		return
	}
	fmt.Printf("  %s%-32s %12s%s\n", c.blue, "База", "Размер", c.nc)
	for _, d := range dbs {
		if len(d) < 3 || d[0] == "" {
			continue
		}
		b, _ := strconv.ParseInt(d[1], 10, 64)
		mark := ""
		if d[2] == "1" {
			mark = " " + c.dim + "(шаблон)" + c.nc
		}
		fmt.Printf("  %-32s %12s%s\n", d[0], human(b), mark)
	}
}

// ── main ──

func main() {
	var (
		directPort = flag.String("p", "", "опросить порт напрямую, в обход systemd")
		directBin  = flag.String("bin", "", "каталог bin с psql для режима -p (напр. /opt/pgpro/1c-18/bin)")
		noColor    = flag.Bool("no-color", false, "не использовать цвет")
	)
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "pg-status — состояние экземпляров PostgreSQL / Postgres Pro")
		fmt.Fprintln(os.Stderr, "\nИспользование:")
		fmt.Fprintln(os.Stderr, "  pg-status [фильтр]            все экземпляры (или подстрока имени/порта)")
		fmt.Fprintln(os.Stderr, "  pg-status -p <порт> [-bin D]  прямой опрос порта")
		fmt.Fprintln(os.Stderr, "\nОпции:")
		flag.PrintDefaults()
	}
	flag.Parse()

	colorEnabled := !*noColor && os.Getenv("NO_COLOR") == "" && isTerminal(os.Stdout)
	setupColors(colorEnabled)
	setupPrivileges()

	// Прямой опрос порта — в обход systemd
	if *directPort != "" {
		if _, err := strconv.Atoi(*directPort); err != nil {
			fmt.Fprintf(os.Stderr, "Порт должен быть числом: %s\n", *directPort)
			os.Exit(1)
		}
		if !canQuery {
			fmt.Fprintln(os.Stderr, "Прямой опрос требует прав root или пользователя postgres")
			os.Exit(1)
		}
		fmt.Printf("%sПрямой опрос порта %s%s\n", c.bold, *directPort, c.nc)
		reportInstance(instance{
			unit: "порт " + *directPort, bin: *directBin,
			port: *directPort, active: "active", pgdata: "",
		})
		return
	}

	if _, err := exec.LookPath("systemctl"); err != nil {
		fmt.Fprintln(os.Stderr, "systemctl не найден — используйте прямой опрос: pg-status -p <порт>")
		os.Exit(1)
	}

	filter := ""
	if flag.NArg() > 0 {
		filter = flag.Arg(0)
	}

	units := collectUnits()
	if len(units) == 0 {
		fmt.Println("Экземпляры PostgreSQL / Postgres Pro не обнаружены.")
		fmt.Println("Если сервер работает нештатно, опросите порт напрямую: pg-status -p <порт>")
		return
	}

	fmt.Printf("%sСостояние PostgreSQL / Postgres Pro%s   %s%s%s\n",
		c.bold, c.nc, c.dim, time.Now().Format("2006-01-02 15:04:05"), c.nc)
	if !canQuery {
		fmt.Printf("%sЗапуск не от root/postgres: статистика БД недоступна, показаны только systemd и размер на диске.%s\n",
			c.yellow, c.nc)
	}

	shown := 0
	for _, unit := range units {
		pid := unitPID(unit)
		pgdata := unitPGDATA(unit, pid)
		port := unitPort(unit, pid, pgdata)

		if filter != "" {
			hay := unit + " " + engineLabel(unit) + " " + port
			if !strings.Contains(hay, filter) {
				continue
			}
		}

		active := strings.TrimSpace(outputAny("systemctl", "is-active", unit))
		if active == "" {
			active = "unknown"
		}
		reportInstance(instance{unit: unit, bin: unitBin(unit), port: port, active: active, pgdata: pgdata})
		shown++
	}

	if shown == 0 {
		fmt.Printf("\nПод фильтр «%s» ничего не подошло.\n", filter)
	}
}

// isTerminal — stdout подключён к терминалу (для авто-выбора цвета)
func isTerminal(f *os.File) bool {
	fi, err := f.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}
