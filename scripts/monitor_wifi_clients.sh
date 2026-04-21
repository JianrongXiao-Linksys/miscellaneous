#!/bin/sh

# WiFi Client Association Monitor
# Monitors ath10 interface and logs when clients associate/disassociate

LOG_FILE="/tmp/clients.log"
INTERFACE="ath10"
INTERVAL=30

# Track previous state: 0 = no clients, 1 = has clients
prev_has_clients=-1

log_with_timestamp() {
    echo "========================================"
    echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Event: $1"
    echo "----------------------------------------"
    wlanconfig "$INTERFACE" list sta
    echo ""
}

count_clients() {
    # Count lines that start with a MAC address pattern (xx:xx:xx:xx:xx:xx)
    wlanconfig "$INTERFACE" list sta 2>/dev/null | grep -c '^[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:'
}

echo "Starting WiFi client monitor on $INTERFACE"
echo "Logging to $LOG_FILE"
echo "Checking every $INTERVAL seconds..."

while true; do
    client_count=$(count_clients)

    if [ "$client_count" -eq 0 ]; then
        current_has_clients=0
    else
        current_has_clients=1
    fi

    # Detect state change
    if [ "$prev_has_clients" -ne "$current_has_clients" ]; then
        if [ "$current_has_clients" -eq 0 ]; then
            log_with_timestamp "NO CLIENTS ASSOCIATED (was: $prev_has_clients clients)" 2>&1 | tee -a "$LOG_FILE"
            echo "[$(date '+%H:%M:%S')] No clients associated"

            # Run diagnostic collection when no clients detected
            echo "[$(date '+%H:%M:%S')] Running diagnostic collection..."

            # 1. Run the monitor script
            if [ -x /tmp/wifistats_regdump.sh ]; then
                sh -x /tmp/wifistats_regdump.sh 2>&1 | tee -a "$LOG_FILE"
            fi

            # 2. First QDSS trace capture
            echo "Starting first QDSS trace capture..." | tee -a "$LOG_FILE"
            cnsscli -i qcn6432_pci0 --enable_qdss_tracing 1 2>&1 | tee -a "$LOG_FILE"
            cnsscli -i qcn6432_pci0 --qdss_start 2>&1 | tee -a "$LOG_FILE"
            cnsscli -i qcn6432_pci0 --qdss_stop 0x1 2>&1 | tee -a "$LOG_FILE"

            # 3. Upload trace file to lab server via scp (dropbear key-based auth)
            TRACE_FILE="/data/vendor/wifi/cHwTrc0_QCN6432_1.bin"
            REMOTE_HOST="192.168.5.85"
            REMOTE_USER="linksys"
            REMOTE_DIR="/home/linksys"
            TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
            REMOTE_FILENAME="cHwTrc0_QCN6432_1_${TIMESTAMP}.bin"
            echo "Uploading trace file to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/${REMOTE_FILENAME}..." | tee -a "$LOG_FILE"
            scp -o StrictHostKeyChecking=no -i /root/.ssh/id_dropbear "$TRACE_FILE" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/${REMOTE_FILENAME}" 2>&1 | tee -a "$LOG_FILE"
            if [ $? -eq 0 ]; then
                echo "Upload successful" | tee -a "$LOG_FILE"
            else
                echo "SCP upload failed, falling back to local copy" | tee -a "$LOG_FILE"
                cp "$TRACE_FILE" /tmp/ 2>&1 | tee -a "$LOG_FILE"
            fi

            # 4. Second QDSS trace and trigger FW recovery
            echo "Starting second QDSS trace and triggering FW recovery..." | tee -a "$LOG_FILE"
            cnsscli -i qcn6432_pci0 --enable_qdss_tracing 1 2>&1 | tee -a "$LOG_FILE"
            cnsscli -i qcn6432_pci0 --qdss_start 2>&1 | tee -a "$LOG_FILE"
            cfg80211tool wifi1 set_fw_recovery 1 2>&1 | tee -a "$LOG_FILE"
            cfg80211tool wifi1 set_fw_hang 1 2>&1 | tee -a "$LOG_FILE"

            echo "[$(date '+%H:%M:%S')] Diagnostic collection completed"
        else
            log_with_timestamp "CLIENTS ASSOCIATED (count: $client_count)" 2>&1 | tee -a "$LOG_FILE"
            echo "[$(date '+%H:%M:%S')] $client_count client(s) associated"
        fi
        prev_has_clients=$current_has_clients
    fi

    sleep "$INTERVAL"
done
