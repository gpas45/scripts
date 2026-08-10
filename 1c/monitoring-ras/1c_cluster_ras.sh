#!/usr/bin/env bash
#
# Сбор метрик кластера 1С:Предприятие 8.3 через RAS/RAC для Zabbix (Linux).
#
# Порт сборщика из статьи Infostart «Мониторинг кластера 1С 8.3 в Zabbix»
# (https://infostart.ru/1c/articles/1632627/) на штатный клиент администрирования
# rac. Linux-версия сознательно без внешних зависимостей: нужен только сам rac
# (из состава платформы 1С) и awk + coreutils, которые есть в любом дистрибутиве.
# PowerShell НЕ требуется (для Windows — отдельный 1c_cluster_ras.ps1).
#
# Режимы:
#   json                - единый JSON { cluster, workingservers, processes, bases }
#   discovery.ib        - LLD информационных баз
#   discovery.process   - LLD рабочих процессов (rphost)
#   discovery.server    - LLD рабочих серверов
#
# Аргументы: <mode> [ras_server] [cluster_user] [cluster_pwd]
#   ras_server по умолчанию localhost:1545
# Переменные окружения:
#   RAC_PATH             - путь к rac (иначе ищется в PATH и каталогах установки)
#   CORP_LICENSE_PATTERN - ERE КОРП/базовых лицензий, исключаемых из счётчика ПРОФ
#                          (по умолчанию без интервалов {3} — совместимо с mawk)
#
# Примеры:
#   ./1c_cluster_ras.sh json 1c-srv:1545
#   ./1c_cluster_ras.sh discovery.ib

set -eo pipefail

MODE="${1:-json}"
RAS_SERVER="${2:-localhost:1545}"
CLUSTER_USER="${3:-}"
CLUSTER_PWD="${4:-}"
CORP_LICENSE_PATTERN="${CORP_LICENSE_PATTERN:-ORG8B ... 500|ORGL8 ... 1}"

# --- Поиск rac ------------------------------------------------------------
find_rac() {
    if [ -n "${RAC_PATH:-}" ]; then
        [ -x "$RAC_PATH" ] || { echo "rac не исполняем: $RAC_PATH" >&2; exit 1; }
        printf '%s\n' "$RAC_PATH"; return
    fi
    if command -v rac >/dev/null 2>&1; then
        command -v rac; return
    fi
    local d f
    for d in /opt/1cv8 /opt/1C /usr/local/1cv8 /usr/lib/1cv8; do
        [ -d "$d" ] || continue
        f=$(find "$d" -type f -name rac 2>/dev/null | sort -r | head -n 1)
        if [ -n "$f" ]; then printf '%s\n' "$f"; return; fi
    done
    echo "rac не найден. Задайте путь через RAC_PATH." >&2
    exit 1
}

RACBIN=$(find_rac)

# Опции аутентификации кластера (только для команд внутри кластера).
AUTH=()
[ -n "$CLUSTER_USER" ] && AUTH+=("--cluster-user=$CLUSTER_USER")
[ -n "$CLUSTER_PWD" ] && AUTH+=("--cluster-pwd=$CLUSTER_PWD")

# UUID первого кластера (без auth — cluster list его не принимает).
CLUSTER_ID=$("$RACBIN" cluster list "$RAS_SERVER" | awk '$1=="cluster"{print $3; exit}')
[ -n "$CLUSTER_ID" ] || { echo "Кластеры не найдены (проверьте RAS/учётку)." >&2; exit 1; }

# Команда внутри кластера: rac <объект/команда> --cluster=<id> [auth] <server>.
racc() { "$RACBIN" "$@" "--cluster=$CLUSTER_ID" "${AUTH[@]}" "$RAS_SERVER"; }

# --- Сбор нужных секций (по режиму — минимум обращений к RAS) --------------
gather() {
    case "$MODE" in
        discovery.ib)
            echo "@@SECTION infobases"; racc infobase summary list; echo ;;
        discovery.process)
            echo "@@SECTION processes"; racc process list; echo ;;
        discovery.server)
            echo "@@SECTION servers"; racc server list; echo ;;
        json)
            echo "@@SECTION cluster_info"; racc cluster info; echo
            echo "@@SECTION servers";      racc server list; echo
            echo "@@SECTION infobases";    racc infobase summary list; echo
            echo "@@SECTION sessions";     racc session list; echo
            echo "@@SECTION connections";  racc connection list; echo
            echo "@@SECTION processes";    racc process list; echo
            echo "@@SECTION licenses";     racc license list; echo ;;
        *)
            echo "Неизвестный режим: $MODE" >&2; exit 1 ;;
    esac
}

# --- Разбор rac и генерация JSON (awk, без внешних зависимостей) -----------
read -r -d '' AWK_PROG <<'AWK' || true
function trim(s){ gsub(/^[ \t\r]+|[ \t\r]+$/,"",s); return s }
function jesc(s,  r){ r=s; gsub(/\\/,"\\\\",r); gsub(/"/,"\\\"",r); gsub(/\r/,"",r); gsub(/\n/,"\\n",r); gsub(/\t/,"\\t",r); return r }
function num(s){ return (s ~ /^-?[0-9]+$/) ? s : "0" }
function numf(s,  t){ t=s; gsub(/,/,".",t); return (t ~ /^-?[0-9]+(\.[0-9]+)?$/) ? t : "0" }
function booly(s){ return (s=="yes") ? "true" : "false" }

function clearcur(   k){ for(k in cur) delete cur[k]; cur_has=0 }

function commit(   k,i){
    if(!cur_has) return
    if(section=="cluster_info"){ for(k in cur) ci[k]=cur[k] }
    else if(section=="servers"){ i=++nsrv;
        srv_uuid[i]=cur["server"]; srv_name[i]=cur["name"]; srv_host[i]=cur["agent-host"];
        srv_port[i]=cur["agent-port"]; srv_conn[i]=cur["connections-limit"];
        srv_iblim[i]=cur["infobases-limit"]; srv_mem[i]=cur["memory-limit"] }
    else if(section=="infobases"){ i=++nib;
        ib_uuid[i]=cur["infobase"]; ib_name[i]=cur["name"]; ib_descr[i]=cur["descr"];
        ibname[cur["infobase"]]=cur["name"] }
    else if(section=="sessions"){ i=++nsess;
        s_uuid[i]=cur["session"]; s_id[i]=cur["session-id"]; s_ib[i]=cur["infobase"];
        s_proc[i]=cur["process"]; s_app[i]=cur["app-id"]; s_user[i]=cur["user-name"];
        s_host[i]=cur["host"]; s_mem[i]=cur["memory-current"]; s_cpu[i]=cur["cpu-time-current"];
        s_db[i]=cur["db-proc-took"]; sidx[cur["session"]]=i }
    else if(section=="connections"){ nconn++ }
    else if(section=="processes"){ i=++nproc;
        p_uuid[i]=cur["process"]; p_pid[i]=cur["pid"]; p_port[i]=cur["port"];
        p_host[i]=cur["host"]; p_started[i]=cur["started-at"]; p_mem[i]=cur["memory-size"];
        p_conn[i]=cur["connections"]; p_run[i]=cur["running"]; p_use[i]=cur["use"];
        p_isen[i]=cur["is-enable"]; p_perf[i]=cur["available-perfomance"]; p_avg[i]=cur["avg-call-time"] }
    else if(section=="licenses"){ i=++nlic; l_sess[i]=cur["session"]; l_short[i]=cur["short-presentation"] }
    clearcur()
}

function sessbrief(idx,   k){
    if(idx==""||idx==0) return "null"
    k=idx
    return "{\"infoBase\":\"" jesc(ibname[s_ib[k]]) "\",\"SessionID\":\"" jesc(s_id[k]) \
           "\",\"AppID\":\"" jesc(s_app[k]) "\",\"userName\":\"" jesc(s_user[k]) \
           "\",\"MemoryCurrent\":" num(s_mem[k]) ",\"cpuTimeCurrent\":" num(s_cpu[k]) \
           ",\"dbProcTook\":" num(s_db[k]) "}"
}

/^@@SECTION /{ commit(); section=$2; clearcur(); next }
/^[ \t\r]*$/{ commit(); next }
{
    idx=index($0,":")
    if(idx>0){
        key=trim(substr($0,1,idx-1))
        val=trim(substr($0,idx+1))
        if(key!=""){ cur[key]=val; cur_has=1 }
    }
}

END{
    commit()

    if(mode=="discovery.ib"){
        printf "{\"data\":["
        for(i=1;i<=nib;i++){ if(i>1)printf ",";
            printf "{\"{#IBUUID}\":\"%s\",\"{#IBNAME}\":\"%s\",\"{#IBDESCR}\":\"%s\"}",
                jesc(ib_uuid[i]), jesc(ib_name[i]), jesc(ib_descr[i]) }
        printf "]}\n"; exit
    }
    if(mode=="discovery.process"){
        printf "{\"data\":["
        for(i=1;i<=nproc;i++){ if(i>1)printf ",";
            printf "{\"{#PROCUUID}\":\"%s\",\"{#PROCHOST}\":\"%s\",\"{#PROCPORT}\":\"%s\",\"{#PROCPID}\":\"%s\"}",
                jesc(p_uuid[i]), jesc(p_host[i]), jesc(p_port[i]), jesc(p_pid[i]) }
        printf "]}\n"; exit
    }
    if(mode=="discovery.server"){
        printf "{\"data\":["
        for(i=1;i<=nsrv;i++){ if(i>1)printf ",";
            printf "{\"{#SRVUUID}\":\"%s\",\"{#SRVNAME}\":\"%s\",\"{#SRVHOST}\":\"%s\"}",
                jesc(srv_uuid[i]), jesc(srv_name[i]), jesc(srv_host[i]) }
        printf "]}\n"; exit
    }

    # --- json: агрегаты по сессиям -------------------------------------
    for(i=1;i<=nlic;i++){
        if(l_sess[i]!=""){ users_count++; licensed[l_sess[i]]=1
            if(l_short[i] !~ corp){ prof_count++; prof_idx[++nprof]=i } }
    }
    for(i=1;i<=nsess;i++){
        a=s_app[i]
        if(a=="1CV8"||a=="1CV8C") clients++
        else if(a=="WSConnection") ws++
        else if(a=="HTTPServiceConnection") http++
        else if(a=="BackgroundJob") jobs++
        else if(a=="COMConnection") com++
        else if(a=="WebServerExtension") web++

        pu=s_proc[i]; proc_sess[pu]++
        if(licensed[s_uuid[i]]) proc_users[pu]++
        m=num(s_mem[i])+0; if(!(pu in proc_topmem)||m>proc_topmemv[pu]){ proc_topmem[pu]=i; proc_topmemv[pu]=m }
        c=num(s_cpu[i])+0; if(!(pu in proc_topcpu)||c>proc_topcpuv[pu]){ proc_topcpu[pu]=i; proc_topcpuv[pu]=c }
        d=num(s_db[i])+0;  if(!(pu in proc_topdb) ||d>proc_topdbv[pu]) { proc_topdb[pu]=i;  proc_topdbv[pu]=d }

        iu=s_ib[i]; ib_sess[iu]++
        if(licensed[s_uuid[i]]) ib_users[iu]++
        if(s_user[i] ~ /^reg[0-9][0-9][0-9]/) reg[iu SUBSEP s_user[i]]++
    }

    # --- cluster --------------------------------------------------------
    printf "{\"cluster\":{"
    printf "\"uuid\":\"%s\",", jesc(cluster_id)
    printf "\"name\":\"%s\",", jesc(ci["name"])
    printf "\"host\":\"%s\",", jesc(ci["host"])
    printf "\"MainPort\":%s,", num(ci["main-port"])
    printf "\"MaxMemorySize\":%s,", num(ci["max-memory-size"])
    printf "\"KillByMemoryWithDump\":%s,", booly(ci["kill-by-memory-with-dump"])
    printf "\"LoadBalancingMode\":\"%s\",", jesc(ci["load-balancing-mode"])
    printf "\"SessionFaultToleranceLevel\":%s,", num(ci["session-fault-tolerance-level"])
    printf "\"ExpirationTimeout\":%s,", num(ci["expiration-timeout"])
    printf "\"LifeTimeLimit\":%s,", num(ci["lifetime-limit"])
    printf "\"SecurityLevel\":%s,", num(ci["security-level"])
    printf "\"KillProblemProcesses\":%s,", booly(ci["kill-problem-processes"])
    printf "\"workingservers_count\":%d,", nsrv
    printf "\"sessions_count\":%d,", nsess
    printf "\"connections_count\":%d,", nconn
    printf "\"users_count\":%d,", users_count
    printf "\"clients_count\":%d,", clients
    printf "\"ws_count\":%d,", ws
    printf "\"http_count\":%d,", http
    printf "\"jobs_count\":%d,", jobs
    printf "\"com_count\":%d,", com
    printf "\"web_count\":%d,", web
    printf "\"prolicense_count\":%d,", prof_count
    printf "\"prolicense_users\":["
    pc=0
    for(j=1;j<=nprof;j++){ li=prof_idx[j]; su=l_sess[li]; if(pc++)printf ","
        if(su in sidx){ k=sidx[su]; ibn=ibname[s_ib[k]]; un=s_user[k]; ho=s_host[k] } else { ibn=""; un=""; ho="" }
        printf "{\"infoBase\":\"%s\",\"userName\":\"%s\",\"host\":\"%s\",\"license\":\"%s\"}",
            jesc(ibn), jesc(un), jesc(ho), jesc(l_short[li]) }
    printf "]}"

    # --- workingservers -------------------------------------------------
    printf ",\"workingservers\":["
    for(i=1;i<=nsrv;i++){ if(i>1)printf ","
        printf "{\"uuid\":\"%s\",\"Name\":\"%s\",\"HostName\":\"%s\",\"MainPort\":%s,\"connections_limit\":%s,\"infobases_limit\":%s,\"memory_limit\":%s}",
            jesc(srv_uuid[i]), jesc(srv_name[i]), jesc(srv_host[i]), num(srv_port[i]),
            num(srv_conn[i]), num(srv_iblim[i]), num(srv_mem[i]) }
    printf "]"

    # --- processes ------------------------------------------------------
    printf ",\"processes\":["
    for(i=1;i<=nproc;i++){ if(i>1)printf ","; pu=p_uuid[i]
        ns=(pu in proc_sess)?proc_sess[pu]:0
        nu=(pu in proc_users)?proc_users[pu]:0
        printf "{\"PID\":\"%s\",\"MainPort\":%s,\"HostName\":\"%s\",\"StartedAt\":\"%s\",",
            jesc(p_pid[i]), num(p_port[i]), jesc(p_host[i]), jesc(p_started[i])
        printf "\"MemorySize\":%s,\"connections\":%s,\"Running\":%s,\"Use\":\"%s\",\"IsEnable\":%s,",
            num(p_mem[i]), num(p_conn[i]), booly(p_run[i]), jesc(p_use[i]), booly(p_isen[i])
        printf "\"AvailablePerf\":%s,\"AvgCallTime\":%s,\"sessions\":%d,\"users\":%d,",
            num(p_perf[i]), numf(p_avg[i]), ns, nu
        printf "\"session_mem\":%s,\"session_CPU\":%s,\"session_proc_took\":%s}",
            sessbrief((pu in proc_topmem)?proc_topmem[pu]:0),
            sessbrief((pu in proc_topcpu)?proc_topcpu[pu]:0),
            sessbrief((pu in proc_topdb)?proc_topdb[pu]:0) }
    printf "]"

    # --- bases ----------------------------------------------------------
    printf ",\"bases\":{\"list\":["
    for(i=1;i<=nib;i++){ if(i>1)printf ","; iu=ib_uuid[i]
        bs=(iu in ib_sess)?ib_sess[iu]:0
        bu=(iu in ib_users)?ib_users[iu]:0
        printf "{\"BaseName\":\"%s\",\"Description\":\"%s\",\"sessions\":%d,\"users\":%d,\"reglaments\":[",
            jesc(ib_name[i]), jesc(ib_descr[i]), bs, bu
        rc=0
        for(key in reg){ split(key,parts,SUBSEP); if(parts[1]==iu){ if(rc++)printf ","
            printf "{\"username\":\"%s\",\"count\":%d}", jesc(parts[2]), reg[key] } }
        printf "]}" }
    printf "]}}\n"
}
AWK

gather | awk -v mode="$MODE" -v corp="$CORP_LICENSE_PATTERN" -v cluster_id="$CLUSTER_ID" "$AWK_PROG"
