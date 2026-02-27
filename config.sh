#!/bin/bash

# ===== NODE CONFIGURATION =====
MASTER_NODE="gu-k8s-master"
WORKER_NODE="gu-k8s-worker"

# ===== PATH CONFIGURATION =====
PRIVATE_STORAGE_BASE="/workspace/private-storage"
HARBOR_PATH="/workspace"

# ===== COMMAND CONFIGURATION =====
TEMP_CMD="nvsm show temperatures"
# --since yesterday allows us to capture the last 24-hour window
LOGIN_COUNT_CMD="last --since yesterday | grep -v 'reboot' | grep -v 'wtmp' | awk '{print \$1}' | sort -u | wc -l"
# Command to fetch image count via CRI (Container Runtime Interface)
IMAGE_COUNT_CMD="crictl images -q | wc -l"
# GPU Process query
GPU_PROC_CMD="nvidia-smi --query-compute-apps=pid --format=csv,noheader"

# ===== WORKLOAD PATTERNS =====
PATTERN_TOTAL="dgx-"
PATTERN_INDUSTRY="dgx-i"
PATTERN_FACULTY="dgx-f"
PATTERN_STUDENT="dgx-s"

# ===== PING/NETWORK CONFIGURATION =====
PING_COUNT=2
PING_TIMEOUT=2

# ===== HOME STORAGE CONFIGURATION =====
TOP_USER_COUNT=3

# ===== LOGGING STRUCTURE =====
TODAY=$(date '+%Y-%m-%d')
TIME_NOW=$(date '+%H%M%S')
BASE_DIR="./logs/$TODAY/$TIME_NOW"

SUMMARY_FILE="$BASE_DIR/summary.log"
