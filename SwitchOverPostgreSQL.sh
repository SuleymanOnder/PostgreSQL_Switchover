#!/bin/bash

#===============================================================================
# Script Name: SwitchOverPostgreSQL.sh
# Description: Automates PostgreSQL switchover between data centers using Patroni
# Usage: sh SwitchOverPostgreSQL.sh RunningMode=[SWITCHOVER|SIMULATION] SourceDC=DC1 TargetDC=DC2
# Author: SuleymanOnder
# Version: 3.0 (27-12-2024)
# See README.md for detailed documentation
#===============================================================================

# Set error handling
set -e

# Get current date and time for logging
DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
UTC_DATETIME=$(date -u '+%Y-%m-%d %H:%M:%S')
LOG_DIR="/var/lib/pgsql/patroni_switchover_logs"
LOG_FILE="${LOG_DIR}/postgresql_switchover_$(date '+%Y%m%d_%H%M%S').log"

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

# Map DC names to server prefixes
declare -A DC_MAP=(
    ["DC1"]="ab01"
    ["DC2"]="ab02"
)

SOURCE_PREFIX=${DC_MAP[$SOURCE_DC]}
TARGET_PREFIX=${DC_MAP[$TARGET_DC]}

if [[ -z "$SOURCE_PREFIX" ]] || [[ -z "$TARGET_PREFIX" ]]; then
    echo "Error: Invalid datacenter names. Use DC2 or DC1"
    exit 1
fi

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"

# Logging function
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to print separator
print_separator() {
    log_message "================================================="
}

# Function to get cluster status
get_cluster_status() {
    patronictl -c /etc/patroni/patroni.yml list
}

# Function to verify node connection
verify_node_connection() {
    local node=$1
    if ! ssh -q -o BatchMode=yes -o ConnectTimeout=5 "$node" exit; then
        log_message "ERROR: Cannot connect to node $node"
        return 1
    fi
    return 0
}

# Function to wait for cluster stability
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

# Function to update patroni tags with verification
update_tags() {
    local server=$1
    local nofailover=$2
    local nosync=$3

    log_message "Updating tags for $server - nofailover: $nofailover, nosync: $nosync"

    # Create sed command file locally
    cat > /tmp/patroni_sed_command << EOF
/^tags:/,/^[^ ]/ {
    s/nofailover:.*$/nofailover: $nofailover/
    s/nosync:.*$/nosync: $nosync/
}
EOF

    # Copy sed command file to remote server
    scp -q /tmp/patroni_sed_command ${server}:/tmp/

    # Apply changes using sudo with allowed command
    if ! ssh -q ${server} "sudo /usr/bin/sed -i -f /tmp/patroni_sed_command /etc/patroni/patroni.yml"; then
        log_message "ERROR: Failed to update tags on $server"
        return 1
    fi

    # Verify changes
    if ! ssh -q "$server" "grep -q 'nofailover: $nofailover' /etc/patroni/patroni.yml && grep -q 'nosync: $nosync' /etc/patroni/patroni.yml"; then
        log_message "ERROR: Tag update verification failed for $server"
        return 1
    fi

    # Restart patroni using sudo with allowed command
    if ! ssh -q ${server} "sudo /usr/bin/systemctl restart patroni"; then
        log_message "ERROR: Failed to restart patroni on $server"
        return 1
    fi

    # Clean up
    ssh -q ${server} "rm -f /tmp/patroni_sed_command"
    rm -f /tmp/patroni_sed_command

    log_message "Successfully updated tags for $server"
    sleep 20
    return 0
}

# Check required permissions
check_permissions() {
    log_message "Checking required permissions..."
    
    # Check if running as postgres user
    if [[ "$(whoami)" != "postgres" ]]; then
        log_message "ERROR: This script must be run as the postgres user"
        return 1
    }
    
    # Check sudo permissions
    required_commands=(
        "/usr/bin/patronictl"
        "/usr/local/bin/etcdctl"
        "/usr/bin/systemctl status patroni"
        "/usr/bin/systemctl status etcd"
        "/usr/bin/systemctl status haproxy"
        "/usr/bin/systemctl status postgresql15-server"
        "/usr/bin/systemctl status keepalived"
        "/usr/bin/systemctl start patroni"
        "/usr/bin/systemctl start etcd"
        "/usr/bin/systemctl start haproxy"
        "/usr/bin/systemctl start postgresql15-server"
        "/usr/bin/systemctl start keepalived"
        "/usr/bin/systemctl stop patroni"
        "/usr/bin/systemctl stop etcd"
        "/usr/bin/systemctl stop haproxy"
        "/usr/bin/systemctl stop postgresql15-server"
        "/usr/bin/systemctl stop keepalived"
        "/usr/bin/systemctl restart patroni"
        "/usr/bin/systemctl restart etcd"
        "/usr/bin/systemctl restart haproxy"
        "/usr/bin/systemctl restart postgresql15-server"
        "/usr/bin/systemctl restart keepalived"
        "/usr/bin/sed -i -f /tmp/patroni_sed_command /etc/patroni/patroni.yml"
        "/usr/bin/systemctl is-active --quiet patroni"
        "/usr/bin/grep"
    )
    
    missing_permissions=false
    for cmd in "${required_commands[@]}"; do
        if ! sudo -l | grep -q "$cmd"; then
            log_message "ERROR: Missing sudo permission for: $cmd"
            missing_permissions=true
        fi
    done
    
    if [ "$missing_permissions" = true ]; then
        log_message "Required sudo permissions not found. Please ensure the postgres user has the POSTGRECMD permission set in sudoers."
        log_message "Expected sudoers configuration:"
        log_message "Cmnd_Alias POSTGRECMD = \\"
        for cmd in "${required_commands[@]}"; do
            if [ "$cmd" = "${required_commands[-1]}" ]; then
                log_message "    $cmd"
            else
                log_message "    $cmd, \\"
            fi
        done
        log_message "%postgres ALL=(ALL)  NOPASSWD: POSTGRECMD"
        return 1
    fi
    
    log_message "Permission checks passed"
    return 0
}

# Validate RunningMode
if [[ "$RUNNING_MODE" != "SWITCHOVER" && "$RUNNING_MODE" != "SIMULATION" ]]; then
    echo "Error: Invalid RunningMode. Only SWITCHOVER and SIMULATION are supported"
    exit 1
fi

# Print header
print_separator
log_message "PostgreSQL Switchover Tool"
log_message "Running Mode: $RUNNING_MODE"
log_message "Current Date and Time (UTC): $UTC_DATETIME"
log_message "Current User's Login: $(whoami)"
print_separator

# Check required permissions
if ! check_permissions; then
    log_message "ERROR: Permission check failed. Exiting."
    exit 1
fi

# Get initial cluster status and information
CLUSTER_STATUS=$(get_cluster_status)
log_message "Initial cluster status:"
echo "$CLUSTER_STATUS" | tee -a "$LOG_FILE"

# Get cluster name
CLUSTER_NAME=$(echo "$CLUSTER_STATUS" | grep "Cluster:" | awk '{print $3}')
log_message "Cluster name: $CLUSTER_NAME"

# SIMULATION MODE
if [[ "$RUNNING_MODE" == "SIMULATION" ]]; then
    log_message "Starting SIMULATION mode checks..."
    log_message "================================================="
    log_message "Running pre-switchover health checks"
    log_message "Source DC: $SOURCE_DC"
    log_message "Target DC: $TARGET_DC"
    log_message "================================================="

    # Check 1: Verify postgres user
    if id postgres &>/dev/null; then
        log_message "✓ postgres user exists"
    else
        log_message "✗ ERROR: postgres user does not exist"
        exit 1
    fi

    # Check 2: Verify patroni service
    if systemctl is-active --quiet patroni; then
        log_message "✓ patroni service is running"
    else
        log_message "✗ ERROR: patroni service is not running"
        exit 1
    fi

    # Check 3: Verify cluster status
    CURRENT_LEADER=$(echo "$CLUSTER_STATUS" | grep "Leader" | tr -s ' ' | cut -d' ' -f2)
    if [[ -n "$CURRENT_LEADER" ]]; then
        log_message "✓ Current leader found: $CURRENT_LEADER"
    else
        log_message "✗ ERROR: No leader found in cluster"
        exit 1
    fi

    # Check 4: Verify synchronization status
    SYNC_STANDBY=$(echo "$CLUSTER_STATUS" | grep "Sync Standby" | tr -s ' ' | cut -d' ' -f2)
    if [[ -n "$SYNC_STANDBY" ]]; then
        log_message "✓ Sync Standby node found: $SYNC_STANDBY"
    else
        log_message "✗ ERROR: No Sync Standby node found"
        exit 1
    fi

    # Check 5: Node status check
    log_message "Node States:"
    echo "$CLUSTER_STATUS" | while read -r line; do
    if [[ $line =~ ${DC_MAP[$SOURCE_DC]}|${DC_MAP[$TARGET_DC]} ]]; then
        NODE=$(echo "$line" | tr -s ' ' | cut -d' ' -f2)
        STATE=$(echo "$line" | tr -s ' ' | cut -d' ' -f4)
        
        # Determine role
        if [[ $line =~ "Leader" ]]; then
            ROLE="Leader"
        elif [[ $line =~ "Sync Standby" ]]; then
            ROLE="Sync Standby"
        elif [[ $line =~ "Replica" ]]; then
            ROLE="Replica"
        else
            ROLE="Unknown"
        fi
        
        # Get and format lag
        LAG=$(echo "$line" | tr -s ' ' | cut -d' ' -f7 | sed 's/|//')
        if [[ -z "$LAG" ]] || [[ "$LAG" == "|" ]]; then
            if [[ "$ROLE" == "Sync Standby" ]]; then
                LAG="Standby"
            else
                LAG="0s"
            fi
        fi
        
        log_message "OK: $NODE - State: $STATE, Role: $ROLE, Lag: $LAG"
    fi
    done

    # Check 6: SSH connectivity
    log_message "Checking SSH connectivity..."
    echo "$CLUSTER_STATUS" | while read -r line; do
        if [[ $line =~ ${DC_MAP[$SOURCE_DC]}|${DC_MAP[$TARGET_DC]} ]]; then
            NODE=$(echo "$line" | tr -s ' ' | cut -d' ' -f2)
            if verify_node_connection "$NODE"; then
                log_message "✓ SSH connection successful to $NODE"
            else
                log_message "✗ ERROR: Cannot connect to $NODE"
                exit 1
            fi
        fi
    done

    # Summary
    log_message "================================================="
    log_message "SIMULATION SUMMARY:"
    log_message "Current Primary: $CURRENT_LEADER ($SOURCE_DC)"
    log_message "Target DC: $TARGET_DC"
    log_message "Sync Standby: $SYNC_STANDBY"
    log_message "All pre-checks completed successfully!"
    log_message "================================================="

    # Ask for proceeding with actual switchover
    read -p "Pre-checks completed successfully. Proceed with actual switchover? (yes/no): " PROCEED
    if [[ "$PROCEED" == "yes" ]]; then
        RUNNING_MODE="SWITCHOVER"
        log_message "Proceeding with switchover..."
    else
        log_message "Simulation completed. Exiting."
        exit 0
    fi
fi

# SWITCHOVER MODE
if [[ "$RUNNING_MODE" == "SWITCHOVER" ]]; then
    # Get current leader
    CURRENT_LEADER=$(echo "$CLUSTER_STATUS" | grep "Leader" | tr -s ' ' | cut -d' ' -f2)
    log_message "Current leader: $CURRENT_LEADER"

    # Step 1: Update target DC nodes with verification
    log_message "Step 1: Updating target DC (${TARGET_DC}) nodes - setting nofailover and nosync to false"
    TARGET_NODES=($(echo "$CLUSTER_STATUS" | grep "${TARGET_PREFIX}" | tr -s ' ' | cut -d' ' -f2))
    
    # Verify all target nodes are accessible
    for node in "${TARGET_NODES[@]}"; do
        if ! verify_node_connection "$node"; then
            log_message "ERROR: Pre-check failed - Cannot proceed with switchover"
            exit 1
        fi
    done

    # Update target nodes
    for node in "${TARGET_NODES[@]}"; do
        if ! update_tags "$node" "false" "false"; then
            log_message "ERROR: Failed to update target node $node"
            exit 1
        fi
        if ! wait_for_cluster_stability; then
            log_message "ERROR: Cluster became unstable after updating $node"
            exit 1
        fi
    done
    log_message "Target DC nodes updated successfully"

    # Step 2: Update source DC non-leader nodes
    log_message "Step 2: Updating source DC (${SOURCE_DC}) non-leader nodes - setting nofailover and nosync to true"
    echo "$CLUSTER_STATUS" | grep "${SOURCE_PREFIX}" | while read -r line; do
        if ! echo "$line" | grep -q "Leader"; then
            node=$(echo "$line" | tr -s ' ' | cut -d' ' -f2)
            if ! update_tags "$node" "true" "true"; then
                log_message "ERROR: Failed to update source node $node"
                exit 1
            fi
            if ! wait_for_cluster_stability; then
                log_message "ERROR: Cluster became unstable after updating source node"
                exit 1
            fi
        fi
    done
    log_message "Source DC non-leader nodes updated successfully"

    # Step 3: Select and verify target node for switchover
    log_message "Step 3: Selecting target node for leadership"
    TARGET_NODES=($(echo "$CLUSTER_STATUS" | grep "${TARGET_PREFIX}" | tr -s ' ' | cut -d' ' -f2))
    NEW_LEADER=${TARGET_NODES[0]}
    log_message "Selected new leader: $NEW_LEADER"

    # Verify new leader candidate
    if ! verify_node_connection "$NEW_LEADER"; then
        log_message "ERROR: Cannot connect to new leader candidate $NEW_LEADER"
        exit 1
    fi

    # Perform switchover
    log_message "Initiating switchover to $NEW_LEADER..."
    if ! sudo patronictl -c /etc/patroni/patroni.yml switchover --force --master "$CURRENT_LEADER" --candidate "$NEW_LEADER"; then
        log_message "ERROR: Switchover command failed"
        exit 1
    fi
    sleep 30
    
    if ! wait_for_cluster_stability; then
        log_message "ERROR: Cluster unstable after switchover"
        exit 1
    fi

    # Get new status
    NEW_STATUS=$(get_cluster_status)
    log_message "New cluster status after switchover:"
    echo "$NEW_STATUS" | tee -a "$LOG_FILE"

    # Step 4: Update old leader
    log_message "Step 4: Updating old leader settings"
    if ! update_tags "$CURRENT_LEADER" "true" "true"; then
        log_message "ERROR: Failed to update old leader"
        exit 1
    fi
    if ! wait_for_cluster_stability; then
        log_message "ERROR: Cluster unstable after updating old leader"
        exit 1
    fi
    log_message "Old leader updated successfully"

    # Step 5: Update target DC non-leader nodes based on source DC count
    SOURCE_NOSYNC_FALSE_COUNT=$(echo "$CLUSTER_STATUS" | grep "${SOURCE_PREFIX}" | grep -v "nosync: true" | wc -l)

    if [ "$SOURCE_NOSYNC_FALSE_COUNT" -gt 0 ]; then
        log_message "Step 5: Found $SOURCE_NOSYNC_FALSE_COUNT nodes with nosync: false in source DC"
        COUNT=0
        echo "$NEW_STATUS" | grep "${TARGET_PREFIX}" | while read -r line; do
            if ! echo "$line" | grep -q "Leader"; then
                node=$(echo "$line" | tr -s ' ' | cut -d' ' -f2)
                if [ "$COUNT" -lt "$SOURCE_NOSYNC_FALSE_COUNT" ]; then
                    if ! update_tags "$node" "false" "false"; then
                        log_message "ERROR: Failed to update target node $node"
                        exit 1
                    fi
                    COUNT=$((COUNT + 1))
                else
                    if ! update_tags "$node" "false" "true"; then
                        log_message "ERROR: Failed to update target node $node"
                        exit 1
                    fi
                fi
                if ! wait_for_cluster_stability; then
                    log_message "ERROR: Cluster unstable after updating target node"
                    exit 1
                fi
            fi
        done
        log_message "Updated target DC nodes configuration successfully"
    fi

    # Step 6: Final update of source DC nodes
    log_message "Step 6: Final update of source DC nodes - setting nosync to true"
    echo "$NEW_STATUS" | grep "${SOURCE_PREFIX}" | while read -r line; do
        node=$(echo "$line" | tr -s ' ' | cut -d' ' -f2)
        if ! update_tags "$node" "true" "true"; then
            log_message "ERROR: Failed to update source node $node"
            exit 1
        fi
        if ! wait_for_cluster_stability; then
            log_message "ERROR: Cluster unstable after updating source node"
            exit 1
        fi
    done
    log_message "Source DC nodes final update completed successfully"

    # Final status check
    log_message "Final cluster status:"
    FINAL_STATUS=$(get_cluster_status)
    echo "$FINAL_STATUS" | tee -a "$LOG_FILE"

    # Print summary
    print_separator
    log_message "SWITCHOVER COMPLETED"
    log_message "Executed By: $(whoami)"
    log_message "Operation Mode: $RUNNING_MODE"
    log_message "Source DC: $SOURCE_DC"
    log_message "Target DC: $TARGET_DC"
    log_message "Date: $DATETIME"
    log_message "Log File: $LOG_FILE"
    print_separator
fi