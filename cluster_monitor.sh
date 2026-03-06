#!/bin/bash

###############################################################################
# Script Name   : cluster_monitor.sh
# Purpose       : Unified Master/Worker health and storage reporting.
###############################################################################

# Import Configuration
if [ -f "./config.sh" ]; then
    source ./config.sh
else
    echo "Error: config.sh not found!"
    exit 1
fi

mkdir -p "$BASE_DIR"

# Clear old summary file
: > "$SUMMARY_FILE"

# Redirect all output to terminal + summary file
exec > >(tee -a "$SUMMARY_FILE") 2>&1

###############################################################################
# SCRIPT LOCK
###############################################################################

LOCK_FILE="/tmp/cluster_monitor.lock"
exec 200>"$LOCK_FILE"

flock -n 200 || {
    echo "Another instance of cluster_monitor.sh is already running. Exiting..."
    exit 1
}

###############################################################################
# ========================= FORMATTING HELPERS ===============================
###############################################################################

section() {
    echo ""
    printf '%0.s=' {1..120}
    echo ""
    printf "%-120s\n" "$1"
    printf '%0.s=' {1..120}
    echo ""
}

sub_section() {
    echo ""
    printf "%-120s\n" "$1"
    printf '%0.s-' {1..120}
    echo ""
}

log_it() {
    printf "[%s] [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"
}

###############################################################################
# ============================= FUNCTIONS ====================================
###############################################################################

check_cluster_status() {
    sub_section "CMSH DEVICE STATUS"
    cmsh -c "device status"
}

check_device_connectivity() {
    sub_section "DEVICE CONNECTIVITY STATUS"

    printf "%-5s %-25s %-15s\n" "ID" "Node Name" "Ping Status"
    printf "%-5s %-25s %-15s\n" "-----" "-------------------------" "---------------"

    row_count=1
    cmsh -c "device list" | awk '/PhysicalNode/ {print $2, $3}' | while read -r name type; do
        if ping -c 1 -W "$PING_TIMEOUT" "$name" > /dev/null 2>&1; then
            ping_stat="ONLINE"
        else
            ping_stat="OFFLINE"
        fi
        printf "%-5s %-25s %-15s\n" "$row_count" "$name" "$ping_stat"
        ((row_count++))
    done
}

check_system_storage() {
    sub_section "SYSTEM STORAGE SUMMARY"

    printf "%-12s %-35s %-10s %-10s %-12s %-8s\n" \
    "Node" "Data Path" "Total" "Avail" "Used" "Use%"
    printf "%-12s %-35s %-10s %-10s %-12s %-8s\n" \
    "------------" "-----------------------------------" "--------" "--------" "----------" "------"

    read -r h_total h_used h_avail h_usage h_total_kb < <(df -k / 2>/dev/null | awk 'NR==2 {print $2, $3, $4, $5, $2}')
    h_total_human=$(df -h / | awk 'NR==2 {print $2}')
    h_used_human=$(df -h / | awk 'NR==2 {print $3}')
    h_avail_human=$(df -h / | awk 'NR==2 {print $4}')

    printf "%-12s %-35s %-10s %-10s %-12s %-8s\n" \
    "Headnode" "/" "$h_total_human" "$h_avail_human" "$h_used_human" "$h_usage"

    home_used_kb=$(du -sk /home 2>/dev/null | awk '{print $1}')
    home_used_human=$(du -sh /home 2>/dev/null | awk '{print $1}')
    home_pct=$(awk "BEGIN {printf \"%.1f%%\", ($home_used_kb / $h_total_kb) * 100}")

    printf "%-12s %-35s %-10s %-10s %-12s %-8s\n" \
    "Headnode" "/home (home data)" "$h_total_human" "$h_avail_human" "$home_used_human" "$home_pct"

    read -r hb_total hb_used hb_avail hb_usage < <(df -h "$HARBOR_PATH" 2>/dev/null | awk 'NR==2 {print $2, $3, $4, $5}')
    printf "%-12s %-35s %-10s %-10s %-12s %-8s\n" \
    "Headnode" "/workspace (harbor images)" "$hb_total" "$hb_avail" "$hb_used" "$hb_usage"

    read -r w_total w_used w_avail w_usage < <(ssh -q "$WORKER_NODE" "df -h /workspace" 2>/dev/null | awk 'NR==2 {print $2, $3, $4, $5}')
    printf "%-12s %-35s %-10s %-10s %-12s %-8s\n" \
    "Worker" "/workspace" "$w_total" "$w_avail" "$w_used" "$w_usage"
}

check_top_home_users() {
    sub_section "TOP $TOP_USER_COUNT HOME STORAGE USERS (/home)"

    top_users=$(du -sk /home/* 2>/dev/null | sort -rn | head -n "$TOP_USER_COUNT")

    if [ -z "$top_users" ]; then
        log_it "WARNING" "No user directories found in /home"
    else
        printf "%-40s %-15s\n" "User (ID)" "Size"
        printf "%-40s %-15s\n" "----------------------------------------" "-------------"

        echo "$top_users" | while read -r size_kb path; do
            user_name=$(basename "$path")
            size_human=$(du -sh "$path" | awk '{print $1}')
            printf "%-40s %-15s\n" "$user_name" "$size_human"
        done
    fi
}

check_user_logins() {
    sub_section "USER LOGIN ACTIVITY (LAST 24 HOURS)"

    raw_users=$(last -w --since yesterday | grep -vE "reboot|wtmp|^$" | awk '{print $1}' | sort -u)

    if [ -z "$raw_users" ]; then
        log_it "INFO" "Total unique users logged in (last 1d): 0"
    else
        user_count=$(echo "$raw_users" | wc -l)
        user_list=$(echo "$raw_users" | paste -sd "," -)
        log_it "INFO" "Total unique users logged in (last 1d): $user_count"
        log_it "INFO" "Active Users: $user_list"
    fi
}

check_worker_temp() {
    sub_section "WORKER NODE TEMPERATURE"

    temp_value=$(ssh -q "$WORKER_NODE" "$TEMP_CMD 2>/dev/null" | \
                 grep -A 10 "TEMP_AMBIENT" | grep "ReadingCelsius" | awk '{print $3}')

    if [ -z "$temp_value" ]; then
        log_it "WARNING" "Could not retrieve temperature"
    else
        printf "Ambient Temperature (%s): %s °C\n" "$WORKER_NODE" "$temp_value"
    fi
}

check_private_storage() {
    sub_section "PRIVATE STORAGE BREAKDOWN ($PRIVATE_STORAGE_BASE)"

    data=$(ssh -q "$WORKER_NODE" "du -sh $PRIVATE_STORAGE_BASE/* 2>/dev/null")

    if [ -z "$data" ]; then
        log_it "WARNING" "No user directories found in $PRIVATE_STORAGE_BASE"
    else
        printf "%-40s %-15s\n" "User (ID)" "Size"
        printf "%-40s %-15s\n" "----------------------------------------" "-------------"

        echo "$data" | while read -r size path; do
            printf "%-40s %-15s\n" "$(basename "$path")" "$size"
        done
    fi
}

check_worker_images() {
    sub_section "WORKER IMAGE INVENTORY"

    img_count=$(ssh -q "$WORKER_NODE" "$IMAGE_COUNT_CMD" 2>/dev/null)

    if [ -z "$img_count" ]; then
        log_it "ERROR" "Could not retrieve image count from $WORKER_NODE"
    else
        printf "Total number of images present at worker node (%s): %s\n" "$WORKER_NODE" "$img_count"
    fi
}

check_k8s_workload() {
    sub_section "KUBERNETES WORKLOAD ANALYSIS"

    all_pods=$(kubectl get pods -A --no-headers 2>/dev/null)

    total_running=$(echo "$all_pods" | awk '$4 == "Running"' | wc -l)
    total_user=$(echo "$all_pods" | awk -v pat="^$PATTERN_TOTAL" '$1 ~ pat' | wc -l)
    count_industry=$(echo "$all_pods" | awk -v pat="^$PATTERN_INDUSTRY" '$1 ~ pat' | wc -l)
    count_faculty=$(echo "$all_pods" | awk -v pat="^$PATTERN_FACULTY" '$1 ~ pat' | wc -l)
    count_student=$(echo "$all_pods" | awk -v pat="^$PATTERN_STUDENT" '$1 ~ pat' | wc -l)

    printf "%-55s %-10s\n" "Category" "Count"
    printf "%-55s %-10s\n" "-------------------------------------------------------" "--------"

    printf "%-55s %-10s\n" "Total Pods (System Running)" "$total_running"
    printf "%-55s %-10s\n" "Total User Pods (NS: $PATTERN_TOTAL*)" "$total_user"
    printf "%-55s %-10s\n" "Industry User Pods (NS: $PATTERN_INDUSTRY*)" "$count_industry"
    printf "%-55s %-10s\n" "Faculty User Pods (NS: $PATTERN_FACULTY*)" "$count_faculty"
    printf "%-55s %-10s\n" "Student User Pods (NS: $PATTERN_STUDENT*)" "$count_student"
}

check_gpu_processes() {
    sub_section "GPU PROCESS SUMMARY"

    proc_count=$(ssh -q "$WORKER_NODE" "$GPU_PROC_CMD 2>/dev/null" | \
                 grep -v "No devices were found" | wc -l)

    [ -z "$proc_count" ] && proc_count=0

    printf "Total GPU processes running on %s: %s\n" "$WORKER_NODE" "$proc_count"
}

check_k8s_mig_report() {
    sub_section "KUBERNETES MIG ALLOCATION REPORT"

    printf "%-35s %-10s %-10s %-10s\n" \
    "MIG Resource" "Total" "Used" "Free"
    printf "%-35s %-10s %-10s %-10s\n" \
    "-----------------------------------" "--------" "--------" "--------"

    node_desc=$(kubectl describe node "$WORKER_NODE")

    resources=$(echo "$node_desc" | awk '
        /Capacity:/ {cap=1; next}
        /Allocatable:/ {cap=0}
        cap && /nvidia.com\// {gsub(":","",$1); print $1}
    ')

    for resource in $resources; do

        total=$(echo "$node_desc" | awk -v r="$resource" '
            /Capacity:/ {cap=1; next}
            /Allocatable:/ {cap=0}
            cap && $1==r":" {print $2}
        ')

        used=$(echo "$node_desc" | awk -v r="$resource" '
            /Allocated resources:/ {alloc=1; skip=2; next}
            alloc && skip>0 {skip--; next}
            alloc && $1==r {print $2}
        ')

        [ -z "$total" ] && total=0
        [ -z "$used" ] && used=0

        free=$((total - used))

        printf "%-35s %-10s %-10s %-10s\n" \
        "$resource" "$total" "$used" "$free"
    done
}

###############################################################################
# ============================= MAIN EXECUTION ================================
###############################################################################

section "CLUSTER HEALTH SUMMARY REPORT"
log_it "INFO" "Report Started"

check_cluster_status
check_device_connectivity
check_system_storage
check_top_home_users
check_user_logins
check_worker_temp
check_private_storage
check_worker_images
check_k8s_workload
check_gpu_processes
check_k8s_mig_report

section "REPORT DIRECTORY"
echo "$BASE_DIR"

log_it "INFO" "Report Completed"
