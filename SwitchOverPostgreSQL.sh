#!/bin/bash

#===============================================================================
# Script Name: SwitchOverPostgreSQL.sh
# Description: Automates PostgreSQL switchover between data centers using Patroni
# Usage: sh SwitchOverPostgreSQL.sh RunningMode=[SWITCHOVER|SIMULATION] SourceDC=DC1 TargetDC=DC2
# Author: SuleymanOnder
# Version: 5.0 (06-01-2025)
# See README.md for detailed documentation
#===============================================================================

# Enable error handling
set -e

# Common Variables
DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
UTC_DATETIME=$(date -u '+%Y-%m-%d %H:%M:%S')
LOG_DIR="/data/postgresql/logs"
LOG_FILE="${LOG_DIR}/postgresql_switchover_$(date '+%Y%m%d_%H%M%S').log"
CURRENT_USER="remote_user"
SSH_KEY="/home/${CURRENT_USER}/.ssh/id_rsa"
SSH_OPTIONS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Node configuration
declare -A NODES
NODES=(
    ["DC1_PRIMARY"]="ab01host01"
    ["DC1_STANDBY"]="ab01host02"
    ["DC2_PRIMARY"]="ab02host01"
    ["DC2_STANDBY"]="ab02host02"
)
export NODES

# Map DC names to server prefixes
declare -A DC_MAP
DC_MAP=(
    ["DC1"]="ab01"
    ["DC2"]="ab02"
)
export DC_MAP

# Create log directory if it doesn't exist
if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    echo "Error: Cannot create log directory: $LOG_DIR"
    exit 1
fi

if ! chmod 700 "$LOG_DIR" 2>/dev/null; then
    echo "Error: Cannot set permissions on log directory: $LOG_DIR"
    exit 1
fi

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

# Function to verify remote node connection 
verify_node_connection() { 
    local node=$1 
    local user=$CURRENT_USER 
     
    # SSH warnings and banner messages are suppressed 
    if ! ssh -q $SSH_OPTIONS -o BatchMode=yes -o ConnectTimeout=5 "${user}@${node}" "exit" 2>/dev/null; then 
        log_message "ERROR: Cannot connect to node $node as ${user}" 
        return 1 
    fi 
    return 0 
} 
export -f verify_node_connection

# Function to execute remote commands 
execute_remote_command() { 
    local node=$1 
    local command=$2 
    local user=$CURRENT_USER 
     
    # SSH warnings and banner messages are suppressed 
    ssh -q $SSH_OPTIONS "${user}@${node}" "$command" 2>/dev/null 
} 
export -f execute_remote_command

get_cluster_status() {
    execute_remote_command "${NODES["DC1_PRIMARY"]}" "sudo -u postgres patronictl -c /etc/patroni/patroni.yml list"
}
export -f get_cluster_status

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
    
    # Create temporary command file
    cat > /tmp/patroni_update_command << EOF
sudo sed -i '/^tags:/,/^[^ ]/ {
    s/nofailover:.*$/nofailover: $nofailover/
    s/nosync:.*$/nosync: $nosync/
}' /etc/patroni/patroni.yml
EOF

    # Copy and execute command on remote server
    scp $SSH_OPTIONS -q /tmp/patroni_update_command "${CURRENT_USER}@${server}:/tmp/"
    if ! execute_remote_command "$server" "bash /tmp/patroni_update_command"; then
        log_message "ERROR: Failed to update tags on $server"
        return 1
    fi

    # Verify changes
    if ! execute_remote_command "$server" "sudo grep -q 'nofailover: $nofailover' /etc/patroni/patroni.yml && sudo grep -q 'nosync: $nosync' /etc/patroni/patroni.yml"; then
        log_message "ERROR: Tag update verification failed for $server"
        return 1
    fi

    # Restart patroni
    if ! execute_remote_command "$server" "sudo systemctl restart patroni"; then
        log_message "ERROR: Failed to restart patroni on $server"
        return 1
    fi

    # Cleanup
    execute_remote_command "$server" "rm -f /tmp/patroni_update_command"
    rm -f /tmp/patroni_update_command

    log_message "Successfully updated tags for $server"
    sleep 20
    return 0
}
export -f update_tags

# Verify SSH key exists and has correct permissions
if [ ! -f "$SSH_KEY" ]; then
    log_message "ERROR: SSH key not found: $SSH_KEY"
    exit 1
fi
chmod 600 "$SSH_KEY"

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

# Set current node
CURRENT_NODE="${NODES[${SOURCE_DC}_PRIMARY]}"

# Validate Current Node
if ! verify_node_connection "$CURRENT_NODE"; then
    echo "Error: Cannot connect to primary node: $CURRENT_NODE"
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
export LOG_FILE SOURCE_DC TARGET_DC CURRENT_USER UTC_DATETIME RUNNING_MODE CURRENT_NODE

# Print header
print_separator
log_message "PostgreSQL Switchover Tool"
log_message "Running Mode: $RUNNING_MODE"
log_message "Current Date and Time (UTC): $UTC_DATETIME"
log_message "Current User's Login: $CURRENT_USER"
log_message "Source DC: $SOURCE_DC"
log_message "Target DC: $TARGET_DC"
log_message "Current Node: $CURRENT_NODE"
log_message "Log File: $LOG_FILE"
print_separator

# Execute appropriate script based on mode
if [ "$RUNNING_MODE" = "SIMULATION" ]; then
    log_message "Starting simulation mode..."
    . ./pg_simulation.sh
    perform_simulation "$SOURCE_DC" "$TARGET_DC" "$LOG_FILE"
elif [ "$RUNNING_MODE" = "SWITCHOVER" ]; then
    log_message "Starting switchover mode..."
    . ./pg_switchover.sh
    perform_switchover "$SOURCE_DC" "$TARGET_DC" "$LOG_FILE"
fi

# Final status message
print_separator
log_message "Operation completed. Check the log file for details: $LOG_FILE"
print_separator

exit 0
