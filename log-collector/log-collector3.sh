#!/bin/bash

#================================================================================
# Arista Log Collector Script (v17 - Health Check & Enhanced Transfers)
#
# This script collects logs and performs a health check on Arista devices
# running EOS.
# - Adds a comprehensive health check before log collection.
# - Displays a live summary of the health check.
# - Saves the detailed health check to a separate file.
# - Enhances the transfer menu to handle both log files.
#================================================================================

# --- Global Variables ---
EXECUTION_MODE="remote"
CONTROL_SOCKET=""
TARGET_HOST=""
USERNAME=""
LOG_FILE_PATH_REMOTE=""
HEALTH_CHECK_FILE_PATH_REMOTE="" # New variable for the health check report

# --- Helper Functions ---
print_header() {
  echo ""
  echo "-----------------------------------------------------"
  echo "  $1"
  echo "-----------------------------------------------------"
}

# --- SSH Connection Management (for Remote Execution) ---
start_ssh_master_conn() {
  print_header "Establishing Remote Connection"
  echo "You will be prompted for the password for '$USERNAME@$TARGET_HOST'."

  mkdir -p ~/.ssh
  CONTROL_SOCKET=~/.ssh/control-${USERNAME}@${TARGET_HOST}-$$

  ssh -M -S "$CONTROL_SOCKET" -fN -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$USERNAME@$TARGET_HOST"

  if ! ssh -S "$CONTROL_SOCKET" -O check "$USERNAME@$TARGET_HOST" >/dev/null 2>&1; then
    echo "SSH master connection failed. Please check credentials and connectivity."
    rm -f "$CONTROL_SOCKET"
    exit 1
  fi
  echo "Connection successful. Proceeding..."
}

close_ssh_master_conn() {
  if [[ -n "$CONTROL_SOCKET" && -e "$CONTROL_SOCKET" ]]; then
    echo "Closing SSH master connection."
    ssh -S "$CONTROL_SOCKET" -O exit "$USERNAME@$TARGET_HOST" >/dev/null 2>&1
  fi
}

# Wrappers for remote execution
ssh_exec() {
  ssh -S "$CONTROL_SOCKET" -o StrictHostKeyChecking=no "$USERNAME@$TARGET_HOST" "$@"
}

scp_exec() {
  scp -o "ControlPath=$CONTROL_SOCKET" -o StrictHostKeyChecking=no "$@"
}

# --- Initial Setup ---
get_case_number() {
  read -p "Enter TAC case number [000000]: " case_number
  case_number=${case_number:-000000}
}

# --- NEW Health Check Function ---
perform_health_check() {
    print_header "Performing Pre-Collection Health Check"
    echo "This may take a moment..."

    local timestamp=$(date +%Y%m%d_%H%M%S)
    local hostname
    hostname=$(echo "$version_output" | grep "System MAC address" | awk '{print $NF}') # A way to get a unique identifier
    local check_filename="health-check-${case_number}-${hostname}-${timestamp}.log"
    HEALTH_CHECK_FILE_PATH_REMOTE="/mnt/flash/${check_filename}"

    # Define the comprehensive set of commands for the health check
    read -r -d '' health_commands << EOM
terminal length 0
echo "=== SYSTEM VERSION & HARDWARE ==="
show version
echo ""
echo "=== MEMORY & FILESYSTEM USAGE ==="
bash free -m
bash df -h
echo ""
echo "=== CPU UTILIZATION (TOP 5) ==="
show processes top once | head -n 12
echo ""
echo "=== COREDUMPS & AGENT CRASHES ==="
show agent logs crash
show core
echo ""
echo "=== CONFIGURED FEATURES SUMMARY ==="
show running-config | egrep "^(router bgp|interface vxlan|mlag configuration)"
echo ""
echo "=== PCI & INTERFACE ERRORS ==="
show hardware pci-error
show interfaces counters discards | grep -v " 0 "
show interfaces counters errors | grep -v " 0 "
echo ""
echo "=== CLOUDVISION (CVP) STATUS ==="
show cvx
echo ""
echo "=== CRITICAL SYSLOG MESSAGES (LAST 20) ==="
show logging | egrep "ERR|CRIT|ALERT|EMERG" | tail -n 20
echo ""
echo "=== SPANNING TREE ROOT ==="
show spanning-tree root detail
echo ""
echo "=== LLDP NEIGHBORS ==="
show lldp neighbors
terminal length 24
EOM

    local health_output
    if [[ "$EXECUTION_MODE" == "remote" ]]; then
        health_output=$(ssh_exec "$health_commands")
        # Save the output to a file on the remote device
        ssh_exec "echo -e \"$health_output\" > $HEALTH_CHECK_FILE_PATH_REMOTE"
    else # local_eos
        health_output=$(FastCli -p 15 -c "$health_commands")
        echo -e "$health_output" > "$HEALTH_CHECK_FILE_PATH_REMOTE"
    fi

    # --- Display Summary to User ---
    print_header "Health Check Summary"
    echo "Full report saved on device: $HEALTH_CHECK_FILE_PATH_REMOTE"
    echo ""
    echo -e "Hostname: \t$(echo "$health_output" | grep 'Hostname:' | awk '{print $2}')"
    echo -e "Model: \t\t$(echo "$health_output" | grep 'Model Name:' | awk '{print $3}')"
    echo -e "Serial: \t$(echo "$health_output" | grep 'Serial number:' | awk '{print $3}')"
    echo -e "EOS Version: \t$(echo "$health_output" | grep 'Software image version:' | awk '{print $4}')"
    echo -e "Memory Free: \t$(echo "$health_output" | grep 'Mem:' | awk '{print $4}') MB"
    echo -e "Flash Free: \t$(echo "$health_output" | grep '/mnt/flash' | awk '{print $4}')"
    local cpu_idle=$(echo "$health_output" | grep '%Cpu(s):' | awk '{print $8}')
    echo -e "CPU Idle: \t$cpu_idle%"
    local core_files=$(echo "$health_output" | grep -c 'core\.')
    echo -e "Core Dumps: \t$core_files found."
    local discards=$(echo "$health_output" | grep -A 1 'Discards' | grep -vc ' 0 ')
    echo -e "Intfs w/ Discards: $discards"
    echo "-----------------------------------------------------"
}


# --- Log Collection Functions ---
collect_eos_logs() {
  local version_output="$1"
  print_header "Collecting Full EOS Support Bundle"

  local eos_version
  eos_version=$(echo "$version_output" | grep "Software image version" | awk '{print $4}')
  echo "Detected EOS version: $eos_version"

  echo ""
  echo "Starting the log collection process..."
  echo "This may take from a few to several minutes. Please do not interrupt the script."
  echo ""

  required_version="4.26.1F"
  
  if [[ "$(printf '%s\n' "$required_version" "$eos_version" | sort -V | head -n1)" == "$required_version" ]]; then
    echo "Using 'send support-bundle' command."
    
    local bundle_output
    if [[ "$EXECUTION_MODE" == "remote" ]]; then
        bundle_output=$(ssh_exec $'enable\nsend support-bundle flash:/ case-number '"$case_number")
    else # Local execution
        bundle_output=$(FastCli -p 15 -c "send support-bundle flash:/ case-number $case_number")
    fi
    
    local filename
    filename=$(echo "$bundle_output" | grep -o 'support-bundle-.*\.zip' | head -n 1)
    
    if [[ -n "$filename" ]]; then
        LOG_FILE_PATH_REMOTE="/mnt/flash/$filename"
    else
        echo "Error: Could not determine the name of the generated support bundle."
        exit 1
    fi
  else
    echo "Using legacy log collection commands for EOS versions older than 4.26.1F."
    # ... Legacy collection logic would go here ...
    echo "Warning: Legacy log collection not fully implemented. Only health check was performed."
  fi
  echo "Log bundle created on device: $LOG_FILE_PATH_REMOTE"
}

# --- File Transfer Sub-Functions ---
handle_ftp_upload() {
    local ftp_command=""
    while true; do
        read -p "Upload to Arista FTP server (ftp.arista.com)? [Y/n/c] (Yes/No/Cancel): " ftp_choice
        ftp_choice=${ftp_choice:-Y}

        case "$ftp_choice" in
            [Yy])
                local ftp_server="ftp.arista.com"
                local ftp_user="anonymous"
                read -p "Please enter your email address for the FTP password: " ftp_pass
                if [[ -z "$ftp_pass" ]]; then
                    echo "Email is required for the Arista FTP server. Please try again."
                    continue
                fi
                local encoded_pass=${ftp_pass//@/%40}
                # We will return the base command structure, to be applied to each file
                ftp_command="ftp://$ftp_user:$encoded_pass@$ftp_server/support/$case_number/"
                break
                ;;
            [Nn])
                read -p "Enter custom FTP server address: " ftp_server
                if [[ -z "$ftp_server" ]]; then echo "Server address cannot be empty."; continue; fi
                read -p "Enter FTP username: " ftp_user
                if [[ -z "$ftp_user" ]]; then echo "Username cannot be empty."; continue; fi
                read -s -p "Enter FTP password: " ftp_pass
                echo ""
                local encoded_pass=${ftp_pass//@/%40}
                ftp_command="ftp://$ftp_user:$encoded_pass@$ftp_server/"
                break
                ;;
            [Cc])
                echo "FTP transfer cancelled."
                break
                ;;
            *)
                echo "Invalid option. Please choose Y, n, or c."
                ;;
        esac
    done
    # Return the constructed base URL
    echo "$ftp_command"
}


# --- Main File Transfer Logic ---
transfer_logs() {
  if [[ -z "$LOG_FILE_PATH_REMOTE" && -z "$HEALTH_CHECK_FILE_PATH_REMOTE" ]]; then return; fi
  
  print_header "File Transfer"
  
  if [[ "$EXECUTION_MODE" == "remote" ]]; then
    while true; do
      echo "Files available on device:"
      [[ -n "$LOG_FILE_PATH_REMOTE" ]] && echo " - Support Bundle: $LOG_FILE_PATH_REMOTE"
      [[ -n "$HEALTH_CHECK_FILE_PATH_REMOTE" ]] && echo " - Health Report:  $HEALTH_CHECK_FILE_PATH_REMOTE"
      echo ""
      echo "What would you like to do?"
      echo "  1. Download Support Bundle to this machine"
      echo "  2. Download Health Report to this machine"
      echo "  3. Download BOTH files to this machine"
      echo "  4. Send file(s) from device to another server (SCP/FTP)"
      echo "  5. Do nothing"
      read -p "Choose an option [1-5]: " choice

      case "$choice" in
        1)
            [[ -n "$LOG_FILE_PATH_REMOTE" ]] && scp_exec "$USERNAME@$TARGET_HOST:$LOG_FILE_PATH_REMOTE" .
            echo "Download complete."
            break
            ;;
        2)
            [[ -n "$HEALTH_CHECK_FILE_PATH_REMOTE" ]] && scp_exec "$USERNAME@$TARGET_HOST:$HEALTH_CHECK_FILE_PATH_REMOTE" .
            echo "Download complete."
            break
            ;;
        3)
            echo "Downloading both files..."
            [[ -n "$LOG_FILE_PATH_REMOTE" ]] && scp_exec "$USERNAME@$TARGET_HOST:$LOG_FILE_PATH_REMOTE" .
            [[ -n "$HEALTH_CHECK_FILE_PATH_REMOTE" ]] && scp_exec "$USERNAME@$TARGET_HOST:$HEALTH_CHECK_FILE_PATH_REMOTE" .
            echo "All downloads complete."
            break
            ;;
        4)
            while true; do
                read -p "Choose upload method (scp/ftp): " upload_method
                case "$upload_method" in
                    scp)
                        read -p "Enter destination user: " dest_user
                        read -p "Enter destination host: " dest_host
                        read -p "Enter destination path: " dest_path
                        if [[ -n "$LOG_FILE_PATH_REMOTE" ]]; then
                            echo "Sending Support Bundle via SCP..."
                            ssh_exec $'enable\nbash scp '"$LOG_FILE_PATH_REMOTE"' '"$dest_user@$dest_host:$dest_path"
                        fi
                        if [[ -n "$HEALTH_CHECK_FILE_PATH_REMOTE" ]]; then
                            echo "Sending Health Report via SCP..."
                            ssh_exec $'enable\nbash scp '"$HEALTH_CHECK_FILE_PATH_REMOTE"' '"$dest_user@$dest_host:$dest_path"
                        fi
                        break
                        ;;
                    ftp)
                        local ftp_base_url=$(handle_ftp_upload)
                        if [[ -n "$ftp_base_url" ]]; then
                            if [[ -n "$LOG_FILE_PATH_REMOTE" ]]; then
                                local ftp_command="copy $(basename "$LOG_FILE_PATH_REMOTE") ${ftp_base_url}"
                                echo "Executing on device: $ftp_command"
                                ssh_exec $'enable\n'"$ftp_command"
                            fi
                            if [[ -n "$HEALTH_CHECK_FILE_PATH_REMOTE" ]]; then
                                local ftp_command="copy $(basename "$HEALTH_CHECK_FILE_PATH_REMOTE") ${ftp_base_url}"
                                echo "Executing on device: $ftp_command"
                                ssh_exec $'enable\n'"$ftp_command"
                            fi
                            echo "Upload command(s) sent."
                        fi
                        break
                        ;;
                    *) echo "Invalid upload method. Please enter 'scp' or 'ftp'." ;;
                esac
            done
            break
            ;;
        5)
            echo "Skipping file transfer."
            break
            ;;
        *) echo "Invalid option. Please enter a number between 1 and 5." ;;
      esac
    done
  else # Local execution
    # Simplified local transfer logic for brevity
    echo "Files are stored locally on the device's flash:"
    [[ -n "$LOG_FILE_PATH_REMOTE" ]] && echo " - Support Bundle: $LOG_FILE_PATH_REMOTE"
    [[ -n "$HEALTH_CHECK_FILE_PATH_REMOTE" ]] && echo " - Health Report:  $HEALTH_CHECK_FILE_PATH_REMOTE"
    echo "You can transfer them using 'copy flash:<filename> <destination_url>'."
  fi
}

# --- Main Logic ---
main() {
  print_header "Arista Log Collector & Health Check"
  
  # Determine execution mode
  if [ -f /etc/Eos-release ]; then
      EXECUTION_MODE="local_eos"
  fi

  local version_output # Make this available to multiple functions

  if [[ "$EXECUTION_MODE" == "remote" ]]; then
    trap close_ssh_master_conn EXIT
    read -p "Enter target Arista device hostname or IP: " TARGET_HOST
    read -p "Enter username [admin]: " USERNAME
    USERNAME=${USERNAME:-admin}
    get_case_number
    start_ssh_master_conn

    version_output=$(ssh_exec $'enable\nterminal length 0\nshow version')
    if echo "$version_output" | grep -qi "Arista"; then
      perform_health_check # Run the health check first
      collect_eos_logs "$version_output"
    else
      echo "Could not determine the OS of the remote device."
      exit 1
    fi
  else # On-Device Execution
    print_header "Running in On-Device Mode"
    get_case_number

    if [[ "$EXECUTION_MODE" == "local_eos" ]]; then
        version_output=$(FastCli -p 15 -c "show version")
        perform_health_check # Run the health check first
        collect_eos_logs "$version_output"
    fi
  fi
  
  transfer_logs
  print_header "Script finished."
}

# Kick off the script
main
