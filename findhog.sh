#!/usr/bin/env bash 

set -u 
# Globals 
SCRIPT_NAME="$(basename "$0")"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
REPORT_DIR="./reports"
REPORT_FILE="${REPORT_DIR}/findhog_report_${TIMESTAMP}.txt"
LOG_FILE="${REPORT_DIR}/findhog.log"

CPU_THRESHOLD=50
TOP_N=5

OS_NAME="$(uname -s)"

usage() {
    cat <<EOF >&2
Usage: ${SCRIPT_NAME} <mode> [options]

Modes: 
    snapshot                       Take a single system resource snapshot 
    monitor <interval> <reps>      Take repeated snapshots 
                                        interval -> seconds between snapshots (positive integer)
                                        reps -> num of snapshots to take (positive num/integer)

Examples:
    ${SCRIPT_NAME} snapshot
    ${SCRIPT_NAME} monitor 5 6

Exit codes:
    0 = success
    1 = fail 
    2 = incorrect usage 
EOF
    exit 2
}

is_pos_integer() {
    local value="$1"
    [[ "$value" =~ ^[1-9][0-9]*$ ]]
    return $?
}

check_dependencies() {
    local required_tools=(ps sort head wc awk date)
    local tool

    for tool in "${required_tools[@]}"; do
        command -v "$tool" >/dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            return 1
        fi 
    done
    return 0
}

get_top_processes() {
    local sort_field="$1"
    local ps_field_idx

    if [[ "$sort_field" == "cpu" ]]; then
        ps_field_idx=3
    else 
        ps_field_idx=4
    fi

    ps -eo pid,comm,%cpu,%mem 2>/dev/null \
        | tail -n +2 \
        | sort -k"${ps_field_idx}" -rn \
        | head -n "${TOP_N}"
}

get_total_mem_pct() {
    if [[ "$OS_NAME" == "Linux" ]]; then 
        free -m 2>/dev/null | awk '/^Mem:/ { printf "%.1f", ($2-$7)/$2 * 100 }'
    elif [[ "$OS_NAME" == "Darwin" ]]; then
        local page_free page_active page_inactive page_wired total_pages used_pages
        page_free=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub("\\.","",$3); print $3}')
        page_active=$(vm_stat 2>/dev/null | awk '/Pages active/ {gsub("\\.","",$3); print $3}')
        page_inactive=$(vm_stat 2>/dev/null | awk '/Pages inactive/ {gsub("\\.","",$3); print $3}')
        page_wired=$(vm_stat 2>/dev/null | awk '/Pages wired down/ {gsub("\\.","",$4); print $4}')
        used_pages=$(( page_active + page_wired ))
        total_pages=$(( used_pages + page_free + page_inactive))

        if [[ "$total_pages" -gt 0 ]]; then
            awk -v u="$used_pages" -v t="$total_pages" 'BEGIN { printf "%.1f", (u/t)*100 }'
        else 
            echo "0.0"
        fi 
    else    echo "0.0"
    fi 
}

LAST_HOG_CT=0
count_hogs(){
    local threshold="$1"
    local count

    count=$(ps -eo %cpu 2>/dev/null | tail -n +2 | awk -v t="$threshold" '$1+0 > t { c++ } END { print c+0 }')
    LAST_HOG_CT="$count"

    if [[ "$count" -gt 0 ]]; then 
        return 0
    else 
        return 1
    fi 
}

write_report() {
    local content="$1"

    mkdir -p "$REPORT_DIR" 2>/dev/null
    if [[ $? -ne 0 ]]; then 
        return 1
    fi

    echo "$content" > "$REPORT_FILE" 2>>"$LOG_FILE"
    if [[ $? -ne 0 ]]; then 
        return 1
    fi 

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Report written: ${REPORT_FILE}" >> "$LOG_FILE" 2>>"$LOG_FILE"
    return 0
}

run_snapshot() {
    local top_cpu top_mem mem_pct load_avg proc_ct report 

    top_cpu="$(get_top_processes cpu)"
    if [[ -z "$top_cpu" ]]; then 
        echo "Error: failed to retrieve process list (ps returned no data)." >&2
        return 1
    fi 

    top_mem="$(get_top_processes mem)"
    mem_pct="$(get_total_mem_pct)"
    proc_ct="$(ps -eo pid 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"

    if [[ "$OS_NAME" == "Linux" ]]; then 
        load_avg="$(cut -d ' ' -f1-3 /proc/loadavg 2>/dev/null)"
    else
        load_avg="$(uptime 2>/dev/null | awk -F'load average[s]?:' '{print $2}'| sed 's/^ *//')"
    fi 

    count_hogs "$CPU_THRESHOLD"
    local hog_status=$?

    report=$(cat <<EOF
=======================================================================
    HOGFINDER SNAPSHOT REPORT 
    Generated: $(date '+%Y-%m-%d %H:%M:%S')
    OS: ${OS_NAME}
=======================================================================

    System Overview:
        Total processes running : ${proc_ct}
        Memory in use           : ${mem_pct}%
    
    Top ${TOP_N} processes by CPU usage: 
    PID COMMAND               %CPU      %MEM
    $(echo "$top_cpu" | awk '{printf " %-6s %-20s %-6s %-6s\n", $1, $2, $3, $4}')

    Top ${TOP_N} processes by memory usage: 
    PID COMMAND               %CPU      %MEM
    $(echo "$top_mem" | awk '{printf " %-6s %-20s %-6s %-6s\n", $1, $2, $3, $4}')

    Hog Analysis (threshold: >${CPU_THRESHOLD}% CPU):
EOF
)

        if [[ $hog_status -eq 0 ]]; then 
            report="${report}
          WARNING: ${LAST_HOG_CT} process(es) excedded ${CPU_THRESHOLD}% CPU usage."
        else 
            report="${report}
                OK: No processes exceeded ${CPU_THRESHOLD}% CPU usage."
        fi 
        report="${report}
======================================================================="

    echo "$report"

    write_report "$report"

    if [[ $? -ne 0 ]]; then 
        echo "WARNING: could not write report file to ${REPORT_FILE}" >&2
    else 
        echo 
        echo "(Report saved to ${REPORT_FILE})"
    fi 

    return 0
}

run_monitor() {
    local interval="$1"
    local reps="$2"
    local i hog_names_file persistent_summary 

    mkdir -p "$REPORT_DIR" 2>/dev/null 
    hog_names_file="${REPORT_DIR}/.monitor_hogs_${TIMESTAMP}.tmp"
    : > "$hog_names_file"

    echo "Monitoring system: ${reps} snapshot(s), ${interval}s apart..."
    echo 

    for (( i=1; i<=reps; i++ )); do 
        echo "--- Snapshot ${i} of ${reps} ($(date '+%H:%M:%S')) ---"

        ps -eo comm,%cpu 2>/dev/null \
            | tail -n +2 \
            | awk -v t="$CPU_THRESHOLD" '$2+0 > t { print $1 }' >> "$hog_names_file"

        count_hogs "$CPU_THRESHOLD"
        if [[ $? -eq 0 ]]; then 
            echo " ${LAST_HOG_CT} proces(es) over ${CPU_THRESHOLD}% CPU this sample."
        else 
            echo " No hogs this sample."
        fi 

        if [[ $i -lt $reps ]]; then 
            sleep "$interval"
        fi 
    done 

    echo 
    echo "======================================================================="
    echo " PERSISTENT HOG SUMMARY (appeared in 2+ samples)"
    echo "======================================================================="

    persistent_summary="$(sort "$hog_names_file" | uniq -c | sort -rn | awk '$1 >= 2 { printf " %-20s appeared in %s samples\n", $2, $1}')"

    if [[ -n "$persistent_summary" ]]; then 
        echo "$persistent_summary"
    else 
        echo " No process was a repeat offender across samples."
    fi
    echo "======================================================================="

    write_report "Monitor run: ${reps} snapshots @ ${interval}s. Persistent hogs:
${persistent_summary:-none}"
    rm -f "$hog_names_file" 2>>"$LOG_FILE"

    return 0
}


main() {
    if [[ $# -lt 1 ]]; then 
        usage
    fi 
    
    check_dependencies 
    if [[ $? -ne 0 ]]; then 
        echo "Error: one or more required tools (ps, sort, head, wc, awk, date) are missing." >&2
        exit 1
    fi 

    local mode="$1"
    shift 

    case "$mode" in 
        snapshot)
            if [[ $# -ne 0 ]]; then 
                usage
            fi 
            run_snapshot
            if [[ $?  -ne 0 ]]; then
                echo "Snapshot failed." >&2
                exit 1
            fi 
            ;;
        monitor)
            if [[ $# -ne 2 ]]; then 
                usage
            fi 

            is_pos_integer "$1"
            if [[ $? -ne 0 ]]; then 
                echo "ERROR: interval must be a positive integer." >&2
                usage 
            fi 

            is_pos_integer "$2" 
            if [[ $? -ne 0 ]]; then 
                echo "ERROR: reps must be a positive integer." >&2
                usage
            fi 

            run_monitor "$1" "$2"
            if [[ $?  -ne 0 ]]; then 
                echo "Monitor run failed." >&2
                exit 1
            fi 
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "ERROR: unknown mode '${mode}'" >&2
            usage 
            ;;
    esac

    exit 0
}

main "$@"