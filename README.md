# PostgreSQL Switchover Tool

A robust, modular bash script framework for managing PostgreSQL database switchover operations between data centers using Patroni.

## Overview

This tool automates the process of performing controlled switchovers between PostgreSQL clusters in different data centers. It includes thorough safety checks, detailed logging, and step-by-step execution of the switchover process.

## Features

- **Modular Design**: Core script with specialized modules for different functions
- **Dual Operation Modes**:
  - SIMULATION: Performs all pre-checks without actual switchover
  - SWITCHOVER: Performs complete switchover operation
- **Comprehensive Logging**: Detailed timestamped logs with operation history
- **Safety Checks**: Multiple verification steps before critical operations
- **Interactive Prompts**: Option to proceed with actual switchover after simulation

## Script Components

The tool consists of three main scripts:

1. **SwitchOverPostgreSQL.sh**: Main entry point and orchestrator
2. **pg_switchover.sh**: Contains the switchover implementation
3. **pg_simulation.sh**: Contains the simulation implementation

## Detailed Process Flow

### Initialization Phase
- Parses command line arguments (RunningMode, SourceDC, TargetDC)
- Sets up logging with timestamped files
- Validates parameters and environment
- Maps datacenter codes to server prefixes

### Simulation Mode (pg_simulation.sh)
- Performs pre-switchover health checks:
  - ✓ Verifies postgres user existence
  - ✓ Checks patroni service status
  - ✓ Validates cluster leadership
  - ✓ Verifies synchronization status
  - ✓ Checks all node states, roles and replication lag
  - ✓ Tests SSH connectivity to all nodes
  - ✓ Verifies patroni configuration
  - ✓ Checks etcd connectivity
- Displays comprehensive health check results
- Offers option to proceed with actual switchover or exit

### Switchover Mode (pg_switchover.sh)
The switchover process is executed in six methodical steps:

#### Step 1: Target DC Preparation
- Updates all target datacenter nodes with:
  ```
  update_tags "$node" "false" "false"
  ```
- Enables these nodes to participate in leader election and synchronous replication
- Verifies cluster stability after each node update

#### Step 2: Source DC Preparation
- Updates non-leader nodes in source DC with:
  ```
  update_tags "$node" "true" "true"
  ```
- Prevents automatic failover from these nodes
- Disables synchronous replication
- Maintains current leader temporarily

#### Step 3: Switchover Execution
- Selects first target DC node as candidate for new leader
- Executes switchover command:
  ```
  sudo patronictl -c /etc/patroni/patroni.yml switchover --force --master "$CURRENT_LEADER" --candidate "$NEW_LEADER"
  ```
- Waits for cluster to stabilize
- Verifies new leadership

#### Step 4: Old Leader Update
- Updates former leader node to prevent automatic failback:
  ```
  update_tags "$CURRENT_LEADER" "true" "true"
  ```
- Completes leadership transition from source DC

#### Step 5: Target DC Replica Configuration
- Configures target DC replica nodes based on original configuration
- Maintains same number of synchronous replicas as source DC had
- Ensures optimal replication topology

#### Step 6: Final Source DC Update
- Sets all source DC nodes to `nofailover: true` and `nosync: true`
- Completes transition of replication configuration

### Verification and Reporting
- Checks final cluster status
- Generates comprehensive completion report

## Common Functions

The main script provides these utility functions used by both modules:

- `log_message()`: Unified logging function
- `print_separator()`: Visual log separators
- `get_cluster_status()`: Returns current patroni cluster status
- `verify_node_connection()`: Tests SSH connectivity
- `wait_for_cluster_stability()`: Ensures stable cluster state
- `update_tags()`: Updates patroni configuration tags
- `execute_remote_command()`: Executes commands on remote servers

## Prerequisites

- PostgreSQL with Patroni configuration
- SSH passwordless access between nodes
- Bash shell
- Required directory structure and permissions
- User with necessary permissions

### SSH Key Configuration

The script requires SSH key-based authentication for connecting between nodes. Follow these steps to set up the required SSH configuration:

1. Set up SSH directory on the remote server where the script will run:
   ```bash
   [root@<remote_server> /root]# sudo su - <remote_user>
   Creating home directory for <remote_user>.
   [<remote_user>@<remote_server> /home/<remote_user>]$ mkdir -p /home/<remote_user>/.ssh
   [<remote_user>@<remote_server> /home/<remote_user>]$ chmod 700 /home/<remote_user>/.ssh
   [<remote_user>@<remote_server> /home/<remote_user>]$ touch /home/<remote_user>/.ssh/authorized_keys
   [<remote_user>@<remote_server> /home/<remote_user>]$ chmod 600 /home/<remote_user>/.ssh/authorized_keys
   ```

2. Generate an SSH key pair on the remote server where the script will run:
   ```bash
   $ ssh-keygen -t rsa -b 4096
   Generating public/private rsa key pair.
   Enter file in which to save the key (/home/<remote_user>/.ssh/id_rsa): 
   Enter passphrase (empty for no passphrase): 
   Enter same passphrase again: 
   Your identification has been saved in /home/<remote_user>/.ssh/id_rsa.
   Your public key has been saved in /home/<remote_user>/.ssh/id_rsa.pub.
   The key fingerprint is:
   The key's randomart image <remote_user>@<remote_server>
   ```
   When prompted, press Enter to use the default location and leave the passphrase empty.

3. Verify the SSH key was created and get the public key content:
   ```bash
   [<remote_user>@<remote_server> /home/<remote_user>/.ssh]$ ls -la
   total 20
   drwx------ 2 <remote_user> domain users   71 Feb  5 17:18 .
   drwx------ 4 <remote_user> domain users  111 Feb  5 17:14 ..
   -rw------- 1 <remote_user> domain users 3401 Feb  5 15:38 id_rsa
   -rw-r--r-- 1 <remote_user> domain users  753 Feb  5 15:38 id_rsa.pub
   -rw-r--r-- 1 <remote_user> domain users 9840 Feb  9 19:02 known_hosts
   [<remote_user>@<remote_server> /home/<remote_user>/.ssh]$ cat id_rsa.pub 
   ssh-rsa KEY <remote_user>@<remote_server>
   ```

4. Verify that the PostgreSQL server's SSH directory structure is correct:
   ```bash
   $ ls -la /var/lib/pgsql/.ssh/
   ```
   You should see files similar to:
   ```
   total 24
   drwx------ 2 postgres postgres   80 Jan  7 10:58 .
   drwx------ 5 postgres postgres  122 Feb  9 12:40 ..
   -rw------- 1 postgres postgres 8635 Jan  6 09:03 authorized_keys
   -rw------- 1 postgres postgres 3389 Dec 25 11:48 id_rsa
   -rw-r--r-- 1 postgres postgres  750 Dec 25 11:48 id_rsa.pub
   -rw-r--r-- 1 postgres postgres 1237 Dec 25 11:49 known_hosts
   ```

5. Manually add the public SSH key to the authorized_keys file on all target PostgreSQL servers:
   ```bash
   $ echo "ssh-rsa KEY <remote_user>@<remote_server>" >> ~/.ssh/authorized_keys
   ```

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

The script relies on these permissions for proper operation. If they are not configured correctly, the switchover process may fail.

## Usage

```bash
sh SwitchOverPostgreSQL.sh RunningMode=[SWITCHOVER|SIMULATION] SourceDC=DC1 TargetDC=DC2
```

### Parameters

- `RunningMode`: Operation mode
  - SWITCHOVER: Performs actual switchover
  - SIMULATION: Runs pre-checks only
- `SourceDC`: Current primary datacenter (DC1 or DC2)
- `TargetDC`: Target datacenter for new primary (DC1 or DC2)

## Logging

Logs are stored in:
```
/var/lib/pgsql/patroni_switchover_logs/postgresql_switchover_YYYYMMDD_HHMMSS.log
/var/lib/pgsql/patroni_switchover_logs/postgresql_simulation_YYYYMMDD_HHMMSS.log
```

## Security Considerations

- Performs validation checks before critical operations
- Requires proper SSH configuration
- Includes error handling and stability verification
- Uses nondestructive operations where possible

## Installation

1. Copy all three script files to the same directory
2. Ensure they are executable:
   ```bash
   chmod +x SwitchOverPostgreSQL.sh pg_switchover.sh pg_simulation.sh
   ```
3. Run the main script with required parameters

## Examples

Run in simulation mode:
```bash
sh SwitchOverPostgreSQL.sh RunningMode=SIMULATION SourceDC=DC1 TargetDC=DC2
```

Run actual switchover:
```bash
sh SwitchOverPostgreSQL.sh RunningMode=SWITCHOVER SourceDC=DC1 TargetDC=DC2
```

## Author

- **Name:** Suleyman Onder
- **Version:** 5.0
- **Date:** 06-01-2025

## License

This project is licensed under the Apache License 2.0
