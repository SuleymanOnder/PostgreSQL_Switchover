#!/bin/bash

# Function to perform simulation
perform_simulation() {
    local SOURCE_DC=$1
    local TARGET_DC=$2
    local LOG_FILE=$3

    # Validate parameters
    if [[ -z "$SOURCE_DC" ]] || [[ -z "$TARGET_DC" ]] || [[ -z "$LOG_FILE" ]]; then
        echo "Error: Missing required parameters for simulation"
        echo "Usage: perform_simulation SOURCE_DC TARGET_DC LOG_FILE"
        return 1
    fi

    # Get initial cluster status
    CLUSTER_STATUS=$(get_cluster_status)

    # SIMULATION MODE
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
    log_message "Node Statuses:"
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

    return 0
}

# Export functions for use in main script
export -f perform_simulation
