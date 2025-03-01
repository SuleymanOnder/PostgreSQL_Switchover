#!/bin/bash

# Function to perform switchover
perform_switchover() {
    local SOURCE_DC=$1
    local TARGET_DC=$2
    local LOG_FILE=$3
    local SOURCE_PREFIX=${DC_MAP[$SOURCE_DC]}
    local TARGET_PREFIX=${DC_MAP[$TARGET_DC]}
    local user=$CURRENT_USER

    # Get current cluster status
    CLUSTER_STATUS=$(get_cluster_status)

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

	    # Restart patroni service
        log_message "Restarting patroni service on node: $node"
        if ! execute_remote_command "$node" "sudo systemctl restart patroni"; then
            log_message "ERROR: Failed to restart patroni service on node $node"
            exit 1
        fi

        # Wait for service to fully restart and cluster to stabilize
        sleep 10  # Give some time for the service to restart
        if ! wait_for_cluster_stability; then
            log_message "ERROR: Cluster became unstable after updating source node"
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
    if ! execute_remote_command "$CURRENT_NODE" "sudo patronictl -c /etc/patroni/patroni.yml switchover --force --master $CURRENT_LEADER --candidate $NEW_LEADER"; then
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

    if [ "$SOURCE_NOSYNC_FALSE_COUNT" -gt 0]; then
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
    log_message "Performed By: $CURRENT_USER"
    log_message "Running Mode: SWITCHOVER"
    log_message "Source DC: $SOURCE_DC"
    log_message "Target DC: $TARGET_DC"
    log_message "Date: $UTC_DATETIME"
    log_message "Log File: $LOG_FILE"
    print_separator

    return 0
}

# Export only perform_switchover function
export -f perform_switchover
