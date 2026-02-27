#!/bin/bash

###############################################################################
# Script Name   : cluster_monitor.sh
# Purpose       : Enhanced reporting with Worker Node storage tracking.
###############################################################################

# ===== INTEGRATED CONFIGURATION =====
MASTER_NODE="k8s-master"
WORKER_NODE="k8s-worker"
USER_HOME_PATH="/home"
PRIVATE_STORAGE_BASE="/workspace/private-storage"
HARBOR_PATH="/workspace/harbor-image"

# Date & Time Structure
TODAY=$(date '+%Y-%m-%d')
TIME_NOW=$(date '+%H%M%S')
BASE_DIR="./logs/$TODAY/$TIME_NOW"
mkdir -p "$BASE_DIR"
SUMMARY_FILE="$BASE_DIR/summary.log"

tog_log_summary() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "$SUMMARY_FILE"
}

###############################################################################
# Execution Start
###############################################################################

tog_log_summary "INFO" "--------------------------------------------------------------"
tog_log_summary "INFO" "Cluster Health Summary Report"
tog_log_summary "INFO" "--------------------------------------------------------------"

# --- 1. Numbered Worker Nodes ---
DEVICE_LIST=$(cmsh -c "device list")
OTHER_NODES=$(echo "$DEVICE_LIST" | awk '/PhysicalNode/ {print $2}')

tog_log_summary "INFO" "Detected Nodes:"
echo "$OTHER_NODES" | awk '{print NR ". " $1}' | tee -a "$SUMMARY_FILE"

# --- 2. Worker Node /workspace Usage ---
WORKER_WORKSPACE_USAGE=$(ssh -q "$WORKER_NODE" "df -h /workspace" | awk 'NR==2 {print $5}')
tog_log_summary "INFO" "Worker Node ($WORKER_NODE) /workspace Usage: $WORKER_WORKSPACE_USAGE"

# --- 3. Private Storage User List & Usage (Worker Node) ---
tog_log_summary "INFO" "Private Storage User List (/workspace/private-storage):"

# This command fetches the directory names and their sizes from the worker node
STORAGE_DATA=$(ssh -q "$WORKER_NODE" "du -sh $PRIVATE_STORAGE_BASE/* 2>/dev/null")

if [ -z "$STORAGE_DATA" ]; then
    tog_log_summary "WARNING" "No user directories found in $PRIVATE_STORAGE_BASE"
else
    printf "| %-20s | %-10s |\n" "User (ID)" "Storage" | tee -a "$SUMMARY_FILE"
    printf "|----------------------|------------|\n" | tee -a "$SUMMARY_FILE"
    
    # Process the data into the table
    echo "$STORAGE_DATA" | while read -r size path; do
        username=$(basename "$path")
        printf "| %-20s | %-10s |\n" "$username" "$size" | tee -a "$SUMMARY_FILE"
    done
fi

# --- 4. Top 3 Home Users Table (Headnode) ---
USER_DIR_FILE="$BASE_DIR/top_users.log"
du -sh /home/* 2>/dev/null | sort -hr | head -n 3 > "$USER_DIR_FILE"

tog_log_summary "INFO" "Top 3 Largest Headnode User Directories (/home):"
printf "| %-20s | %-10s |\n" "User" "Storage" | tee -a "$SUMMARY_FILE"
printf "|----------------------|------------|\n" | tee -a "$SUMMARY_FILE"
while read -r size path; do
    user=$(basename "$path")
    printf "| %-20s | %-10s |\n" "$user" "$size" | tee -a "$SUMMARY_FILE"
done < "$USER_DIR_FILE"

# --- 5. Total Home Storage Summary ---
TOTAL_HOME_STORAGE=$(du -sh /home 2>/dev/null | awk '{print $1}')
tog_log_summary "INFO" "Total Cumulative /home Storage: $TOTAL_HOME_STORAGE"

# --- 6. Disk Usage (Headnode) ---
HEADNODE_USAGE=$(df / | awk 'NR==2 {print $5}')
tog_log_summary "INFO" "Headnode root directory / Usage: $HEADNODE_USAGE"

tog_log_summary "INFO" "--------------------------------------------------------------"
tog_log_summary "INFO" "Report Directory: $BASE_DIR"
tog_log_summary "INFO" "--------------------------------------------------------------"
