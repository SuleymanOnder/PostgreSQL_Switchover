#!/bin/bash

#===============================================================================
# Script Name: SwitchOverPostgreSQL.sh
# Description: Automates PostgreSQL switchover between data centers using Patroni
# Usage: sh SwitchOverPostgreSQL.sh RunningMode=[SWITCHOVER|SIMULATION] SourceDC=DC1 TargetDC=DC2
# Author: Suleyman Onder
# Version: 4.0 (05-01-2025)
# See README.md for detailed documentation
#===============================================================================

# Enable error handling
set -e

# Common Variables
DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
UTC_DATETIME=$(date -u '+%Y-%m-%d %H:%M:%S')
LOG_DIR="/var/lib/pgsql/patroni_switchover_logs"
LOG_FILE="${LOG_DIR}/postgresql_switchover_$(date '+%Y%m%d_%H%M%S').log"
CURRENT_USER="$(whoami)"

# Create log directory if it doesn't exist
if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    echo "Error: Cannot create log directory: $LOG_DIR"
    exit 1
fi

if ! chmod 700 "$LOG_DIR" 2>/dev/null; then
    echo "Error: Cannot set permissions on log directory: $LOG_DIR"
    exit 1
fi

# Map DC names to server prefixes
declare -A DC_MAP
DC_MAP=(
    ["DC1"]="ab01"
    ["DC2"]="ab02"
)
export DC_MAP

# Common Functions
log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}
export -f log_message

print_separator() {
    log_message "================================================="
}
export -f print_separator

get_cluster_status() {
    patronictl -c /etc/patroni/patroni.yml list
}
export -f get_cluster_status

verify_node_connection() {
    local node=$1
    if ! ssh -q -o BatchMode=yes -o ConnectTimeout=5 "$node" exit; then
        log_message "ERROR: Cannot connect to node $node"
        return 1
    fi
    return 0
}
export -f verify_node_connection

wait_for_cluster_stability() {
    local retries=6
    local wait_time=10
    local stable=false

    log_message "Waiting for cluster to stabilize..."
    
    while [ $retries -gt 0 ] && [ "$stable" = false ]; do
        local status=$(get_cluster_status)
        if ! echo "$status" | grep -q "stopping\|starting\|initiating"; then
            stable=true
            log_message "Cluster is stable"
        else
            log_message "Cluster is not stable yet, waiting..."
            sleep $wait_time
            retries=$((retries - 1))
        fi
    done

    if [ "$stable" = false ]; then
        log_message "ERROR: Cluster failed to stabilize"
        return 1
    fi
    return 0
}
export -f wait_for_cluster_stability

update_tags() {
    local server=$1
    local nofailover=$2
    local nosync=$3

    log_message "Updating tags for $server - nofailover: $nofailover, nosync: $nosync"

    cat > /tmp/patroni_sed_command << EOF
/^tags:/,/^[^ ]/ {
    s/nofailover:.*$/nofailover: $nofailover/
    s/nosync:.*$/nosync: $nosync/
}
EOF

    scp -q /tmp/patroni_sed_command ${server}:/tmp/

    if ! ssh -q ${server} "sudo /usr/bin/sed -i -f /tmp/patroni_sed_command /etc/patroni/patroni.yml"; then
        log_message "ERROR: Failed to update tags on $server"
        return 1
    fi

    if ! ssh -q "$server" "grep -q 'nofailover: $nofailover' /etc/patroni/patroni.yml && grep -q 'nosync: $nosync' /etc/patroni/patroni.yml"; then
        log_message "ERROR: Tag update verification failed for $server"
        return 1
    fi

    if ! ssh -q ${server} "sudo /usr/bin/systemctl restart patroni"; then
        log_message "ERROR: Failed to restart patroni on $server"
        return 1
    fi

    ssh -q ${server} "rm -f /tmp/patroni_sed_command"
    rm -f /tmp/patroni_sed_command

    log_message "Successfully updated tags for $server"
    sleep 20
    return 0
}
export -f update_tags

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        RunningMode=*)
        RUNNING_MODE="${1#*=}"
        shift
        ;;
        SourceDC=*)
        SOURCE_DC="${1#*=}"
        shift
        ;;
        TargetDC=*)
        TARGET_DC="${1#*=}"
        shift
        ;;
        *)
        echo "Unknown parameter: $1"
        echo "Usage: $0 RunningMode=[SWITCHOVER|SIMULATION] SourceDC=[DC2|DC1] TargetDC=[DC2|DC1]"
        exit 1
        ;;
    esac
done

# Validate input parameters
if [[ -z "$RUNNING_MODE" ]] || [[ -z "$SOURCE_DC" ]] || [[ -z "$TARGET_DC" ]]; then
    echo "Error: RunningMode, SourceDC and TargetDC must be specified"
    echo "Usage: $0 RunningMode=[SWITCHOVER|SIMULATION] SourceDC=[DC2|DC1] TargetDC=[DC2|DC1]"
    exit 1
fi

# Validate RunningMode
if [[ "$RUNNING_MODE" != "SWITCHOVER" && "$RUNNING_MODE" != "SIMULATION" ]]; then
    echo "Error: Invalid RunningMode. Only SWITCHOVER and SIMULATION are supported"
    exit 1
fi

# Validate Source and Target DC
if ! [[ -v "DC_MAP[$SOURCE_DC]" ]] || ! [[ -v "DC_MAP[$TARGET_DC]" ]]; then
    echo "Error: Invalid Source or Target DC. Valid values are DC2 and DC1"
    exit 1
fi

if [ "$SOURCE_DC" = "$TARGET_DC" ]; then
    echo "Error: Source and Target DC cannot be the same"
    exit 1
fi

# Create specific log file for the operation
if [ "$RUNNING_MODE" = "SIMULATION" ]; then
    LOG_FILE="${LOG_DIR}/postgresql_simulation_$(date '+%Y%m%d_%H%M%S').log"
else
    LOG_FILE="${LOG_DIR}/postgresql_switchover_$(date '+%Y%m%d_%H%M%S').log"
fi

# Ensure log file is created and writable
if ! touch "$LOG_FILE" 2>/dev/null; then
    echo "Error: Cannot create log file: $LOG_FILE"
    exit 1
fi
chmod 600 "$LOG_FILE"

# Export variables for child scripts
export LOG_FILE SOURCE_DC TARGET_DC CURRENT_USER UTC_DATETIME RUNNING_MODE

# Print header
print_separator
log_message "PostgreSQL Switchover Tool"
log_message "Running Mode: $RUNNING_MODE"
log_message "Current Date and Time (UTC): $UTC_DATETIME"
log_message "Current User's Login: $CURRENT_USER"
log_message "Source DC: $SOURCE_DC"
log_message "Target DC: $TARGET_DC"
log_message "Log File: $LOG_FILE"
print_separator

# Execute appropriate script based on mode
if [ "$RUNNING_MODE" = "SIMULATION" ]; then
    if [ -f "./pg_simulation.sh" ]; then
        # Source simulation script
        . ./pg_simulation.sh
        # Run simulation
        perform_simulation "$SOURCE_DC" "$TARGET_DC" "$LOG_FILE"
    else
        log_message "ERROR: pg_simulation.sh not found in current directory"
        exit 1
    fi
elif [ "$RUNNING_MODE" = "SWITCHOVER" ]; then
    if [ -f "./pg_switchover.sh" ]; then
        # Source switchover script
        . ./pg_switchover.sh
        # Run switchover
        perform_switchover "$SOURCE_DC" "$TARGET_DC" "$LOG_FILE"
    else
        log_message "ERROR: pg_switchover.sh not found in current directory"
        exit 1
    fi
fi

# Final status message
print_separator
log_message "Operation completed. Check the log file for details: $LOG_FILE"
print_separator

exit 0