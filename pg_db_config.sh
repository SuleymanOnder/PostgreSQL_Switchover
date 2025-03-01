#!/bin/bash

# Function to get database configuration
get_db_config() {
    local DB_TYPE="postgre"
    
    if [ -n "$DatabaseName" ]; then
        log_message "INFO Finding Database Hostname from config database"
        
        # SQL Query based on database type
        local SQL_QUERY="SET NOCOUNT ON; 
            SELECT a.*, b.* 
            FROM [${DB_TYPE}.Databases] a 
            JOIN [${DB_TYPE}.Nodes] b 
            ON a.HostGroup = b.HostGroup 
            WHERE a.DatabaseName = '${DatabaseName}' 
            FOR JSON AUTO;"

        # Execute SQL query
        search_results_raw=$(sqlcmd -C -h-1 -y8000 \
            -S sqlserver.localhost.domain \
            -U $(echo user|base64 -d) \
            -P $(echo pass|base64 -d) \
            -d <db_name> \
            -Q "${SQL_QUERY}")

        if [ -n "$search_results_raw" ]; then
            # Clear existing NODES array
            unset NODES
            declare -A NODES

            # First find the Leader node
            LEADER_NODE=$(echo $search_results_raw | jq -r '.[0].b[] | select(.ClusterRole == "Leader") | .Hostname')
            LEADER_LOCATION=$(echo $search_results_raw | jq -r '.[0].b[] | select(.ClusterRole == "Leader") | .Location')

            # Set CURRENT_NODE to Leader node
            CURRENT_NODE="$LEADER_NODE"

            # Set primary nodes based on leader location
            if [ "$LEADER_LOCATION" = "DC1" ]; then
                NODES["DC1_PRIMARY"]="$LEADER_NODE"
                NODES["DC1_STANDBY"]=$(echo $search_results_raw | jq -r '.[0].b[] | select(.Location == "DC1" and .ClusterRole == "Sync Standby") | .Hostname')
                NODES["DC2_PRIMARY"]=$(echo $search_results_raw | jq -r '.[0].b[] | select(.Location == "DC2" and .ClusterRole == "Replica") | .Hostname' | head -1)
                NODES["DC2_STANDBY"]=$(echo $search_results_raw | jq -r '.[0].b[] | select(.Location == "DC2" and .ClusterRole == "Replica") | .Hostname' | tail -1)
            else
                NODES["DC2_PRIMARY"]="$LEADER_NODE"
                NODES["DC2_STANDBY"]=$(echo $search_results_raw | jq -r '.[0].b[] | select(.Location == "DC2" and .ClusterRole == "Sync Standby") | .Hostname')
                NODES["DC1_PRIMARY"]=$(echo $search_results_raw | jq -r '.[0].b[] | select(.Location == "DC1" and .ClusterRole == "Replica") | .Hostname' | head -1)
                NODES["DC1_STANDBY"]=$(echo $search_results_raw | jq -r '.[0].b[] | select(.Location == "DC1" and .ClusterRole == "Replica") | .Hostname' | tail -1)
            fi

            # Set DC prefixes
            SourceDCPrefix=$(echo ${NODES["${SOURCE_DC}_PRIMARY"]} | cut -c 1-4)
            TargetDCPrefix=$(echo ${NODES["${TARGET_DC}_PRIMARY"]} | cut -c 1-4)

            # Log configuration summary without debug messages
            log_message "Configuration Summary:"
            log_message "Database Name : $DatabaseName"
            log_message "Source DC     : $SOURCE_DC (${NODES[${SOURCE_DC}_PRIMARY]})"
            log_message "Target DC     : $TARGET_DC (${NODES[${TARGET_DC}_PRIMARY]})"
            log_message "Leader Node   : $CURRENT_NODE"

            # Export variables including CURRENT_NODE
            export NODES SourceDCPrefix TargetDCPrefix CURRENT_NODE
            
            # For debugging, verify array contents
            declare -p NODES >/dev/null 2>&1 || log_message "ERROR: NODES array not properly declared"
            
            return 0
        else
            log_message "ERROR: Database Hostname parsing error for $DatabaseName!"
            return 1
        fi
    else
        log_message "ERROR: DatabaseName parameter is not set!"
        return 1
    fi
}
export -f get_db_config
