# PostgreSQL Switchover Script

A robust bash script for managing PostgreSQL database switchover operations between data centers using Patroni.

## Overview

This script automates the process of performing a controlled switchover between PostgreSQL clusters in different data centers. It includes safety checks, logging, and step-by-step execution of the switchover process.

## Detailed Process Flow

### 1. Initialization and Validation
- Parses command line arguments (RunningMode, SourceDC, TargetDC)
- Sets up logging with timestamped files in `/var/lib/pgsql/patroni_switchover_logs/`
- Validates that required parameters are provided and correct
- Maps datacenter codes (DC1/DC2) to server prefixes (ab01/ab02)
- Verifies postgres user permissions using `check_permissions()` function
- Checks for all required sudo permissions defined in the POSTGRECMD alias
- Exits if any validation checks fail

### 2. Pre-Switchover Assessment
- Retrieves current cluster status using `patronictl list` 
- Identifies cluster name and current leader node
- Displays initial state for operator verification
- Requires explicit "yes" confirmation before proceeding
- Establishes baseline metrics for post-switchover comparison

### 3. Target DC Preparation (Step 1)
- Identifies all nodes in target DC by filtering on prefix (ab01/ab02)
- Executes for each target node:
  ```
  update_tags "$node" "false" "false"
  ```
- This enables leader election participation and synchronous replication
- Waits for cluster stability after each configuration change
- Ensures target DC is ready to accept leadership

### 4. Source DC Preparation (Step 2)
- Identifies non-leader nodes in source DC (preserves leader temporarily)
- For each non-leader source node:
  ```
  update_tags "$node" "true" "true"
  ```
- This prevents automatic failover to these nodes (nofailover: true)
- Disables synchronous replication (nosync: true)
- Maintains stability during transition
- Preserves leader node's settings temporarily

### 5. Switchover Execution (Step 3)
- Selects first target DC node as candidate for new leader
- Executes switchover command:
  ```
  sudo patronictl -c /etc/patroni/patroni.yml switchover --force --master "$CURRENT_LEADER" --candidate "$NEW_LEADER"
  ```
- Waits 30 seconds for initial transition
- Calls `wait_for_cluster_stability()` to ensure completion
- Retrieves and logs new cluster status

### 6. Post-Switchover Configuration
- Updates old leader settings (Step 4):
  ```
  update_tags "$CURRENT_LEADER" "true" "true"
  ```
  - Prevents automatic failback
  - Completes leadership transition from source DC
  
- Balances target DC replica nodes (Step 5):
  - Counts how many source DC nodes had synchronous replication
  - Configures same number of target DC replica nodes with `nosync: false`
  - Sets remaining target DC replicas to `nosync: true`
  - Maintains consistent synchronous replication count
  
- Finalizes source DC configuration (Step 6):
  - Sets all source DC nodes to `nosync: true`
  - Completes transition of replication topology

### 7. Verification and Reporting
- Checks final cluster status with `patronictl list`
- Verifies leadership is now in target DC
- Logs comprehensive completion report:
  - Execution user
  - Operation mode
  - Source and target DCs
  - Timestamp
  - Log file location
- All actions and their outcomes are recorded in the log file

## Prerequisites

- PostgreSQL with Patroni configuration
- SSH access between nodes
- Sudo privileges for the postgres user (see below)
- Bash shell
- Required directory structure and permissions

### Required sudo permissions

The postgres user must have the following sudo permissions configured in the sudoers file:

```
Cmnd_Alias POSTGRECMD = \
    /usr/bin/patronictl, \
    /usr/local/bin/etcdctl, \
    /usr/bin/systemctl status patroni, \
    /usr/bin/systemctl status etcd, \
    /usr/bin/systemctl status haproxy, \
    /usr/bin/systemctl status postgresql15-server, \
    /usr/bin/systemctl status keepalived, \
    /usr/bin/systemctl start patroni, \
    /usr/bin/systemctl start etcd, \
    /usr/bin/systemctl start haproxy, \
    /usr/bin/systemctl start postgresql15-server, \
    /usr/bin/systemctl start keepalived, \
    /usr/bin/systemctl stop patroni, \
    /usr/bin/systemctl stop etcd, \
    /usr/bin/systemctl stop haproxy, \
    /usr/bin/systemctl stop postgresql15-server, \
    /usr/bin/systemctl stop keepalived, \
    /usr/bin/systemctl restart patroni, \
    /usr/bin/systemctl restart etcd, \
    /usr/bin/systemctl restart haproxy, \
    /usr/bin/systemctl restart postgresql15-server, \
    /usr/bin/systemctl restart keepalived, \
    /usr/bin/sed -i -f /tmp/patroni_sed_command /etc/patroni/patroni.yml, \
    /usr/bin/systemctl is-active --quiet patroni \
    /usr/bin/grep

%postgres ALL=(ALL)  NOPASSWD: POSTGRECMD
```

The script checks for these permissions before proceeding with the switchover.

## Usage

```bash
sh SwitchOverPostgreSQL.sh RunningMode=SWITCHOVER SourceDC=DC1 TargetDC=DC2
```

### Parameters

- `RunningMode`: Operation mode (currently only SWITCHOVER is supported)
- `SourceDC`: Source data center (DC1 or DC2)
- `TargetDC`: Target data center (DC1 or DC2)

## Logging

Logs are stored in:
```
/var/lib/pgsql/patroni_switchover_logs/postgresql_switchover_YYYYMMDD_HHMMSS.log
```

## Security Considerations

- Performs validation checks before critical operations
- Requires proper SSH and sudo configurations
- Includes error handling and rollback capabilities
- Maintains cluster stability throughout the process
- Verifies postgres user permissions on startup

## Author

- **Name:** Suleyman
- **Version:** 2.0
- **Date:** 26-12-2024

## License

This project is licensed under the Apache License 2.0 - see the LICENSE file for details