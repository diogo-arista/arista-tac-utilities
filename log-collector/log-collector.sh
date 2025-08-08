#!/bin/bash

#================================================================================
# Arista Log Collector Script (v14 - Added Wait Message)
#
# This script collects logs from Arista devices running EOS.
# It now includes a message to inform the user that log collection may take time.
#================================================================================

# --- Global Variables ---
EXECUTION_MODE="remote"
CONTROL_SOCKET=""
TARGET_HOST=""
USERNAME=""
LOG_FILE_PATH_REMOTE=""

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

# --- Log Collection Functions (Context-Aware) ---
collect_eos_logs() {
  local version_output="$1"
  print_header "Collecting EOS Logs"

  local eos_version
  eos_version=$(echo "$version_output" | grep "Software image version" | awk '{print $4}')
  echo "Detected EOS version: $eos_version"

  # Add a message to set user expectations about the wait time.
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
    else # Local execution on EOS using FastCli
        bundle_output=$(FastCli -p 15 -c "send support-bundle flash:/ case-number $case_number")
    fi
    
    local filename
    filename=$(echo "$bundle_output" | grep -o 'support-bundle-.*\.zip' | head -n 1)
    
    if [[ -n "$filename" ]]; then
        LOG_FILE_PATH_REMOTE="/mnt/flash/$filename"
    else
        echo "Error: Could not determine the name of the generated support bundle."
        echo "--- Full command output from device ---"
        echo "$bundle_output"
        echo "---------------------------------------"
        exit 1
    fi
  else
    echo "Using legacy log collection commands for EOS versions older than 4.26.1F."
    local hostname datetime_tar
    
    if [[ "$EXECUTION_MODE" == "remote" ]]; then
        hostname=$(ssh_exec $'enable\nshow hostname' | grep "Hostname:" | awk '{print $2}')
        datetime_tar=$(ssh_exec $'enable\nbash date "+%F--%H%M"')
        ssh_exec $'enable\nshow tech-support' | gzip > "/tmp/show-tech.gz"
        scp_exec "/tmp/show-tech.gz" "$USERNAME@$TARGET_HOST:/mnt/flash/$case_number-$hostname-show-tech.log.gz"
        rm "/tmp/show-tech.gz"
        ssh_exec $'enable\nbash (cd /mnt/flash && tar -czvf '"$case_number"'-$HOSTNAME-misc-logs.tar.gz /var/log/ /mnt/flash/debug/ /mnt/flash/Fossil/ && tar --remove-files -cf TAC-bundle-'"$case_number"'-$HOSTNAME-'"$datetime_tar"'.tar '"$case_number"'-*.gz)'
        LOG_FILE_PATH_REMOTE=$(ssh_exec $'enable\nbash ls -1t /mnt/flash/TAC-bundle-'"$case_number"'-* | head -1')
    else # Local execution
        hostname=$(FastCli -p 15 -c "show hostname" | grep "Hostname:" | awk '{print $2}')
        datetime_tar=$(date "+%F--%H%M")
        FastCli -p 15 -c "show tech-support" | gzip > "/mnt/flash/$case_number-$hostname-show-tech.log.gz"
        tar -czvf "/mnt/flash/$case_number-$hostname-misc-logs.tar.gz" /var/log/ /mnt/flash/debug/ /mnt/flash/Fossil/
        tar --remove-files -C /mnt/flash -cf "/mnt/flash/TAC-bundle-$case_number-$hostname-$datetime_tar.tar" "$case_number"*.gz
        LOG_FILE_PATH_REMOTE=$(ls -1t /mnt/flash/TAC-bundle-"$case_number"-* | head -1)
    fi
  fi
  echo "Log bundle created on device: $LOG_FILE_PATH_REMOTE"
}

# --- File Transfer ---
transfer_logs() {
  if [[ -z "$LOG_FILE_PATH_REMOTE" ]]; then
    echo "Log file path not found. Skipping transfer."
    return
  fi
  
  print_header "File Transfer"
  
  if [[ "$EXECUTION_MODE" == "remote" ]]; then
      echo "Log bundle is on device: $LOG_FILE_PATH_REMOTE"
      echo "What would you like to do?"
      echo "  1. Download file to this machine"
      echo "  2. Send file from device to another server"
      echo "  3. Do nothing"
      read -p "Choose an option [1-3]: " choice

      case "$choice" in
        1)
            echo "Downloading log file from $TARGET_HOST..."
            scp_exec "$USERNAME@$TARGET_HOST:$LOG_FILE_PATH_REMOTE" .
            echo "Download complete: $(basename "$LOG_FILE_PATH_REMOTE")"
            ;;
        2)
            read -p "Choose upload method (scp/ftp): " upload_method
            case "$upload_method" in
                scp)
                    read -p "Enter destination user: " dest_user
                    read -p "Enter destination host: " dest_host
                    read -p "Enter destination path: " dest_path
                    local scp_command="scp $LOG_FILE_PATH_REMOTE $dest_user@$dest_host:$dest_path"
                    echo "Executing on device: $scp_command"
                    ssh_exec $'enable\nbash '"$scp_command"
                    echo "Device has been instructed to send the file. You may be prompted for a password."
                    ;;
                ftp)
                    read -p "Upload to Arista FTP server (ftp.arista.com)? (y/n): " arista_ftp_choice
                    if [[ "$arista_ftp_choice" == "y" ]]; then
                        read -p "Please enter your email address for the FTP password: " user_email
                        if [[ -z "$user_email" ]]; then echo "Email is required. Aborting."; return; fi
                        local encoded_email=${user_email//@/%40}
                        local ftp_command="copy $(basename "$LOG_FILE_PATH_REMOTE") ftp://anonymous:$encoded_email@ftp.arista.com/support/$case_number/"
                        echo "Executing on device: $ftp_command"
                        ssh_exec $'enable\n'"$ftp_command"
                        echo "Upload command sent."
                    fi
                    ;;
                *) echo "Invalid upload method." ;;
            esac
            ;;
        3)
            echo "Skipping file transfer."
            ;;
        *)
            echo "Invalid option."
            ;;
      esac
  else # Local execution
      read -p "Do you want to send the log file to a remote location? (y/n): " transfer_choice
      if [[ "$transfer_choice" != "y" ]]; then echo "Skipping upload."; return; fi

      read -p "Choose upload method (scp/ftp): " transfer_method
      case "$transfer_method" in
        scp)
          read -p "Enter remote user: " remote_user
          read -p "Enter remote host: " remote_host
          read -p "Enter remote path: " remote_path
          scp "$LOG_FILE_PATH_REMOTE" "$remote_user@$remote_host:$remote_path"
          ;;
        ftp)
          read -p "Upload to Arista FTP server (ftp.arista.com)? (y/n): " arista_ftp_choice
          if [[ "$arista_ftp_choice" == "y" ]]; then
            read -p "Please enter your email address for the FTP password: " user_email
            if [[ -z "$user_email" ]]; then echo "Email is required. Aborting."; return; fi
            local encoded_email=${user_email//@/%40}
            echo "Attempting to upload to Arista FTP server..."
            local ftp_command="copy flash:$(basename "$LOG_FILE_PATH_REMOTE") ftp://anonymous:$encoded_email@ftp.arista.com/support/$case_number/"
            FastCli -p 15 -c "$ftp_command"
            echo "Upload command sent."
          fi
          ;;
        *) 
          echo "Invalid transfer method." 
          ;;
      esac
  fi
}

# --- Main Logic ---
main() {
  print_header "Arista Log Collector"
  
  if [ -f /etc/Eos-release ]; then
      EXECUTION_MODE="local_eos"
  elif [ -f /etc/sonic/sonic-version.yml ]; then
      EXECUTION_MODE="local_sonic"
  fi

  if [[ "$EXECUTION_MODE" == "remote" ]]; then
    trap close_ssh_master_conn EXIT
    read -p "Enter target Arista device hostname or IP: " TARGET_HOST
    read -p "Enter username [admin]: " USERNAME
    USERNAME=${USERNAME:-admin}
    get_case_number
    start_ssh_master_conn

    local version_output
    version_output=$(ssh_exec $'enable\nterminal length 0\nshow version')

    if echo "$version_output" | grep -qi "Arista"; then
      collect_eos_logs "$version_output"
    else
      echo "Could not determine the OS of the remote device."
      exit 1
    fi
  else # On-Device Execution
    print_header "Running in On-Device Mode"
    get_case_number

    if [[ "$EXECUTION_MODE" == "local_eos" ]]; then
        local version_output
        version_output=$(FastCli -p 15 -c "show version")
        collect_eos_logs "$version_output"
    fi
  fi
  
  transfer_logs
  print_header "Script finished."
}

# Kick off the script
main