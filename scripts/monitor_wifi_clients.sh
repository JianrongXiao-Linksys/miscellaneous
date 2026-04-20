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
            log_with_timestamp "NO CLIENTS ASSOCIATED (was: $prev_has_clients clients)" >> "$LOG_FILE"
            echo "[$(date '+%H:%M:%S')] No clients associated - logged to $LOG_FILE"
        else
            log_with_timestamp "CLIENTS ASSOCIATED (count: $client_count)" >> "$LOG_FILE"
            echo "[$(date '+%H:%M:%S')] $client_count client(s) associated - logged to $LOG_FILE"
        fi
        prev_has_clients=$current_has_clients
    fi

    sleep "$INTERVAL"
done
