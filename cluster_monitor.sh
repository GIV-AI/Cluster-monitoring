#!/bin/bash

###############################################################################
# Script Name   : cluster_monitor.sh
###############################################################################

# Import Configuration
if [ -f "./config.sh" ]; then
    source ./config.sh
else
    echo "Error: config.sh not found!"
    exit 1
fi

mkdir -p "$BASE_DIR"

# ===== HELPER FUNCTIONS =====

log_it() {
    local level=$1
    local msg=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" | tee -a "$SUMMARY_FILE"
}

draw_line() {
    log_it "INFO" "--------------------------------------------------------------"
}

# --- Function: Node Status (CMSH) ---
check_cluster_status() {
    log_it "INFO" "CMSH Device Status:"
    cmsh -c "device status" | tee -a "$SUMMARY_FILE"
}

# --- Function: Private Storage Breakdown (Worker) ---
check_private_storage() {
    log_it "INFO" "Private Storage Breakdown ($PRIVATE_STORAGE_BASE):"
    local data
    data=$(ssh -q "$WORKER_NODE" "du -sh $PRIVATE_STORAGE_BASE/* 2>/dev/null")

    if [ -z "$data" ]; then
        log_it "WARNING" "No user directories found in $PRIVATE_STORAGE_BASE"
    else
        printf "| %-20s | %-10s |\n" "User (ID)" "Size" | tee -a "$SUMMARY_FILE"
        printf "|----------------------|------------|\n" | tee -a "$SUMMARY_FILE"
        echo "$data" | while read -r size path; do
            printf "| %-20s | %-10s |\n" "$(basename "$path")" "$size" | tee -a "$SUMMARY_FILE"
        done
    fi
}



# --- Function: Top Home Storage Users ---
check_top_home_users() {
    log_it "INFO" "Top $TOP_USER_COUNT Home Storage Users (/home):"
    
    # Get sizes of all directories in /home, sort numerically (human-readable), and take top N
    # 'du -sh' for display, but we use 'du -sk' for accurate sorting
    local top_users
    top_users=$(du -sk /home/* 2>/dev/null | sort -rn | head -n "$TOP_USER_COUNT")

    if [ -z "$top_users" ]; then
        log_it "WARNING" "No user directories found in /home"
    else
        printf "| %-20s | %-10s |\n" "User (ID)" "Size" | tee -a "$SUMMARY_FILE"
        printf "|----------------------|------------|\n" | tee -a "$SUMMARY_FILE"
        
        echo "$top_users" | while read -r size_kb path; do
            local user_name=$(basename "$path")
            # Convert KB back to Human Readable for the table
            local size_human=$(du -sh "$path" | awk '{print $1}')
            printf "| %-20s | %-10s |\n" "$user_name" "$size_human" | tee -a "$SUMMARY_FILE"
        done
    fi
}


# --- Function: Worker Image Inventory ---
check_worker_images() {
    log_it "INFO" "Counting Container Images on $WORKER_NODE..."
    local img_count
    img_count=$(ssh -q "$WORKER_NODE" "$IMAGE_COUNT_CMD" 2>/dev/null)
    
    if [ -z "$img_count" ]; then
        log_it "ERROR" "Could not retrieve image count from $WORKER_NODE"
    else
        log_it "INFO" "Total number of images present at worker node: $img_count"
    fi
}

# --- Function: Kubernetes Workload Analysis ---
check_k8s_workload() {
    log_it "INFO" "Analyzing Kubernetes Workload (Pods)..."
    local all_pods
    all_pods=$(kubectl get pods -A --no-headers 2>/dev/null)

    local total_running=$(echo "$all_pods" | awk '$4 == "Running"' | wc -l)
    local total_user=$(echo "$all_pods" | awk -v pat="^$PATTERN_TOTAL" '$1 ~ pat' | wc -l)
    local count_industry=$(echo "$all_pods" | awk -v pat="^$PATTERN_INDUSTRY" '$1 ~ pat' | wc -l)
    local count_faculty=$(echo "$all_pods" | awk -v pat="^$PATTERN_FACULTY" '$1 ~ pat' | wc -l)
    local count_student=$(echo "$all_pods" | awk -v pat="^$PATTERN_STUDENT" '$1 ~ pat' | wc -l)

    printf "| %-32s | %-10s |\n" "Category" "Count" | tee -a "$SUMMARY_FILE"
    printf "|----------------------------------|------------|\n" | tee -a "$SUMMARY_FILE"
    printf "| %-32s | %-10s |\n" "Total Pods (System Running)" "$total_running" | tee -a "$SUMMARY_FILE"
    printf "| %-32s | %-10s |\n" "Total User Pods (NS: $PATTERN_TOTAL*)" "$total_user" | tee -a "$SUMMARY_FILE"
    printf "| %-32s | %-10s |\n" "Industry User Pods (NS: $PATTERN_INDUSTRY*)" "$count_industry" | tee -a "$SUMMARY_FILE"
    printf "| %-32s | %-10s |\n" "Faculty User Pods (NS: $PATTERN_FACULTY*)" "$count_faculty" | tee -a "$SUMMARY_FILE"
    printf "| %-32s | %-10s |\n" "Student User Pods (NS: $PATTERN_STUDENT*)" "$count_student" | tee -a "$SUMMARY_FILE"
}

# --- Function: Device Connectivity ---
check_device_connectivity() {
    log_it "INFO" "Device List & Connectivity Status (2s Timeout):"
    printf "| %-3s | %-15s | %-15s |\n" "ID" "Node Name" "Ping Status" | tee -a "$SUMMARY_FILE"
    printf "|-----|-----------------|-----------------|\n" | tee -a "$SUMMARY_FILE"

    local row_count=1
    cmsh -c "device list" | awk '/PhysicalNode/ {print $2, $3}' | while read -r name type; do
        if ping -c 1 -W "$PING_TIMEOUT" "$name" > /dev/null 2>&1; then
            ping_stat="ONLINE"
        else
            ping_stat="OFFLINE"
        fi
        printf "| %-3s | %-15s | %-15s |\n" "$row_count" "$name" "$ping_stat" | tee -a "$SUMMARY_FILE"
        ((row_count++))
    done
}

# --- Function: Unified System Storage Table ---
# --- Function: Unified System Storage Table (Updated with Total Use) ---
check_system_storage() {
    log_it "INFO" "System Storage Summary (Active Data Paths):"
    
    # Header with new "Total Use" column
    printf "| %-12s | %-28s | %-8s | %-8s | %-10s | %-6s |\n" "Node" "Data Path" "Total" "Avail" "Total Use" "Use%" | tee -a "$SUMMARY_FILE"
    printf "|--------------|------------------------------|----------|----------|------------|--------|\n" | tee -a "$SUMMARY_FILE"

    # 1. Headnode - Root (/)
    # Fetching values: Total(2), Used(3), Avail(4), Use%(5)
    read -r h_total h_used h_avail h_usage h_total_kb < <(df -k / 2>/dev/null | awk 'NR==2 {print $2, $3, $4, $5, $2}')
    h_total_human=$(df -h / | awk 'NR==2 {print $2}')
    h_used_human=$(df -h / | awk 'NR==2 {print $3}')
    h_avail_human=$(df -h / | awk 'NR==2 {print $4}')
    
    printf "| %-12s | %-28s | %-8s | %-8s | %-10s | %-6s |\n" "Headnode" "/" "$h_total_human" "$h_avail_human" "$h_used_human" "$h_usage" | tee -a "$SUMMARY_FILE"

    # 2. Headnode - Combined /home (home data)
    home_used_kb=$(du -sk /home 2>/dev/null | awk '{print $1}')
    home_used_human=$(du -sh /home 2>/dev/null | awk '{print $1}')
    
    # Calculate %: (Home Used / Total Disk) * 100
    home_pct=$(awk "BEGIN {printf \"%.1f%%\", ($home_used_kb / $h_total_kb) * 100}")

    printf "| %-12s | %-28s | %-8s | %-8s | %-10s | %-6s |\n" "Headnode" "/home (home data)" "$h_total_human" "$h_avail_human" "$home_used_human" "$home_pct" | tee -a "$SUMMARY_FILE"

    # 3. Headnode - /workspace/ (harbor images)
    read -r hb_total hb_used hb_avail hb_usage < <(df -h "$HARBOR_PATH" 2>/dev/null | awk 'NR==2 {print $2, $3, $4, $5}')
    printf "| %-12s | %-28s | %-8s | %-8s | %-10s | %-6s |\n" "Headnode" "/workspace/ (harbor images)" "$hb_total" "$hb_avail" "$hb_used" "$hb_usage" | tee -a "$SUMMARY_FILE"

    # 4. Worker - /workspace
    read -r w_total w_used w_avail w_usage < <(ssh -q "$WORKER_NODE" "df -h /workspace" 2>/dev/null | awk 'NR==2 {print $2, $3, $4, $5}')
    printf "| %-12s | %-28s | %-8s | %-8s | %-10s | %-6s |\n" "Worker" "/workspace" "$w_total" "$w_avail" "$w_used" "$w_usage" | tee -a "$SUMMARY_FILE"
}


# --- Function: Headnode User Login Activity ---
check_user_logins() {
    log_it "INFO" "Checking unique user logins in the last 24 hours..."
    local raw_users
    raw_users=$(last --since yesterday | grep -vE "reboot|wtmp|^$" | awk '{print $1}' | sort -u)

    if [ -z "$raw_users" ]; then
        log_it "INFO" "Total unique users logged in (last 1d): 0"
    else
        local user_count=$(echo "$raw_users" | wc -l)
        local user_list=$(echo "$raw_users" | paste -sd "," -)
        log_it "INFO" "Total unique users logged in (last 1d): $user_count"
        log_it "INFO" "Active Users: $user_list"
    fi
}

# --- Function: Worker Thermal Status ---
check_worker_temp() {
    log_it "INFO" "Checking Worker Node ($WORKER_NODE) Ambient Temperature..."
    local temp_value
    temp_value=$(ssh -q "$WORKER_NODE" "$TEMP_CMD 2>/dev/null" | grep -A 10 "TEMP_AMBIENT" | grep "ReadingCelsius" | awk '{print $3}')
    if [ -z "$temp_value" ]; then
        log_it "WARNING" "Could not retrieve temperature from $WORKER_NODE"
    else
        log_it "INFO" "AMBIENT - temp : $temp_value degreeC"
    fi
}

# --- Function: GPU Process Count ---
check_gpu_processes() {
    log_it "INFO" "Analyzing GPU Workload on $WORKER_NODE..."
    local proc_count
    proc_count=$(ssh -q "$WORKER_NODE" "$GPU_PROC_CMD 2>/dev/null" | grep -v "No devices were found" | wc -l)
    [ -z "$proc_count" ] && proc_count=0
    log_it "INFO" "Total number of processes running on GPU: $proc_count"
}

###############################################################################
# Main Execution Flow
###############################################################################

draw_line
log_it "INFO" "Cluster Health Summary Report Started"
draw_line
check_cluster_status
draw_line
check_device_connectivity
draw_line
check_system_storage
draw_line
check_top_home_users
draw_line
check_user_logins
draw_line
check_worker_temp
draw_line
check_private_storage
draw_line
check_worker_images
draw_line
check_k8s_workload
draw_line
check_gpu_processes
draw_line

log_it "INFO" "Report Directory: $BASE_DIR"
draw_line
