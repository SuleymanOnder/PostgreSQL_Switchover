# PostgreSQL Switchover Script

A robust bash script for managing PostgreSQL database switchover operations between data centers using Patroni.

## Overview

This script automates the process of performing a controlled switchover between PostgreSQL clusters in different data centers. It includes safety checks, logging, and step-by-step execution of the switchover process.

## Detailed Process Flow

### 1. Initial Setup and Validation
- Validates input parameters (SourceDC and TargetDC)
- Sets up logging environment with timestamped log files
- Creates necessary directories with appropriate permissions
- Captures initial cluster status using patronictl
- Maps datacenter codes to server prefixes for node identification
- Performs user permission checks to ensure proper sudo privileges
- Performs pre-flight checks to ensure script prerequisites are met

### 2. Pre-Switchover Preparation
- Gets current cluster status and identifies the current leader node
- Maps DC names to server prefixes for targeting specific node groups
- Requires explicit user confirmation before proceeding with critical operations
- Validates cluster stability to ensure a safe starting point
- Logs all initial states for audit and troubleshooting purposes

### 3. Target DC Configuration (Step 1)
- Identifies all nodes in target DC using prefix matching
- Sets `nofailover: false` to allow these nodes to participate in leader elections
- Sets `nosync: false` to enable synchronous replication on target DC nodes
- Waits for cluster stability after each node configuration change
- Prepares target DC to accept leadership by ensuring all nodes are properly configured
- Updates Patroni configuration files using sed and restarts services as needed

### 4. Source DC Non-Leader Configuration (Step 2)
- Identifies non-leader nodes in source DC while preserving current leader
- Sets `nofailover: true` to prevent automatic failover to these nodes
- Sets `nosync: true` to disable synchronous replication on these nodes
- Prevents unwanted failovers during the controlled switchover process
- Ensures cluster stability between each configuration change
- Preserves leader node settings temporarily to maintain service

### 5. Switchover Execution (Step 3)
- Selects specific target node from target DC for new leadership
- Executes Patroni switchover command with appropriate parameters
- Forces leadership change to target DC using `--force` option when necessary
- Monitors switchover progress with stability checks
- Waits for completion before proceeding to next steps
- Verifies new leader has been properly established

### 6. Post-Switchover Configuration
- Updates old leader settings (Step 4)
  - Sets `nofailover: true` to prevent automatic failback
  - Sets `nosync: true` to disable synchronous replication
  - Completes transition of leadership away from source DC
- Configures target DC non-leader nodes (Step 5)
  - Maintains same number of sync nodes as original configuration
  - Balances synchronous replication across appropriate nodes
  - Ensures replica nodes are properly configured based on their role
- Updates source DC nodes (Step 6)
  - Sets all nodes to `nosync: true` to complete DC transition
  - Ensures proper replication setup between DCs
  - Completes configuration to reflect new topology

### 7. Final Verification
- Performs final cluster status check with patronictl
- Generates detailed completion summary with timestamps
- Records all actions in log file for audit purposes
- Verifies that leader is now in target DC
- Confirms all nodes have appropriate configuration for their new roles
- Provides final status report to operator

## Prerequisites

- PostgreSQL with Patroni configuration
- SSH access between nodes with key-based authentication
- Script must be run as postgres user
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
sh SwitchOverPostgreSQL.sh SourceDC=DC1 TargetDC=DC2
```

### Parameters

- `SourceDC`: Source data center (DC1 or DC2)
- `TargetDC`: Target data center (DC1 or DC2)

## Suggestions for Best Practices

1. **Pre-Execution Planning**:
   - Schedule the switchover during off-peak hours
   - Notify all relevant teams before execution
   - Have a rollback plan ready in case of issues
   - Test the script in a non-production environment first

2. **Execution Environment**:
   - Execute from a terminal with stable connection
   - Use screen or tmux to prevent SSH disconnection issues
   - Monitor system resources during execution
   - Have database experts available during the process

3. **Post-Switchover Verification**:
   - Test application connectivity after switchover
   - Verify replication is working properly
   - Check all monitoring systems recognize the new leader
   - Run read/write tests to confirm functionality

4. **Documentation**:
   - Record the reason for switchover
   - Document any anomalies observed during the process
   - Keep logs for future reference and troubleshooting
   - Update configuration management documentation

## Logging

Logs are stored in:
```
/var/lib/pgsql/patroni_switchover_logs/postgresql_switchover_YYYYMMDD_HHMMSS.log
```

## Security Considerations

- Performs validation checks before critical operations
- Validates required sudo permissions at startup
- Requires proper SSH and sudo configurations
- Includes error handling and stability checking
- Maintains cluster stability throughout the process
- Creates log files with appropriate permissions (700)

## Author

- **Name:** Suleyman
- **Version:** 1.0
- **Date:** 25-12-2024

## License

This project is licensed under the Apache License 2.0 - see the LICENSE file for details