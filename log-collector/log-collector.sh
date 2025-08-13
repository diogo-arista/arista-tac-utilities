#!/bin/bash

#================================================================================
# Arista Log Collector Script (v16 - Improved FTP Logic)
#
# This script collects logs from Arista devices running EOS.
# It now includes a more robust and user-friendly menu for FTP uploads.
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

# --- Log Collection Functions ---
collect_eos_logs() {
  local version_output="$1"
  print_header "Collecting EOS Logs"

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
    # ... Legacy collection logic ...
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
                ftp_command="copy $(basename "$LOG_FILE_PATH_REMOTE") ftp://$ftp_user:$encoded_pass@$ftp_server/support/$case_number/"
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
                # Note: Generic path may vary, this assumes a similar structure.
                ftp_command="copy $(basename "$LOG_FILE_PATH_REMOTE") ftp://$ftp_user:$encoded_pass@$ftp_server/"
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
    # Return the constructed command
    echo "$ftp_command"
}


# --- Main File Transfer Logic ---
transfer_logs() {
  if [[ -z "$LOG_FILE_PATH_REMOTE" ]]; then return; fi
  
  print_header "File Transfer"
  
  if [[ "$EXECUTION_MODE" == "remote" ]]; then
    while true; do
      echo "Log bundle is on device: $LOG_FILE_PATH_REMOTE"
      echo "What would you like to do?"
      echo "  1. Download file to this machine"
      echo "  2. Send file from device to another server"
      echo "  3. Do nothing"
      read -p "Choose an option [1-3]: " choice

      case "$choice" in
        1)
            scp_exec "$USERNAME@$TARGET_HOST:$LOG_FILE_PATH_REMOTE" .
            echo "Download complete."
            break
            ;;
        2)
            while true; do
                read -p "Choose upload method (scp/ftp): " upload_method
                case "$upload_method" in
                    scp)
                        read -p "Enter destination user: " dest_user
                        read -p "Enter destination host: " dest_host
                        read -p "Enter destination path: " dest_path
                        local scp_command="scp $LOG_FILE_PATH_REMOTE $dest_user@$dest_host:$dest_path"
                        ssh_exec $'enable\nbash '"$scp_command"
                        break
                        ;;
                    ftp)
                        local ftp_command=$(handle_ftp_upload)
                        if [[ -n "$ftp_command" ]]; then
                            echo "Executing on device: $ftp_command"
                            ssh_exec $'enable\n'"$ftp_command"
                            echo "Upload command sent."
                        fi
                        break
                        ;;
                    *) echo "Invalid upload method. Please enter 'scp' or 'ftp'." ;;
                esac
            done
            break
            ;;
        3)
            echo "Skipping file transfer."
            break
            ;;
        *) echo "Invalid option. Please enter a number between 1 and 3." ;;
      esac
    done
  else # Local execution
    while true; do
      read -p "Do you want to send the log file to a remote location? (y/n): " transfer_choice
      if [[ "$transfer_choice" == "n" ]]; then echo "Skipping upload."; break; fi
      
      if [[ "$transfer_choice" == "y" ]]; then
        while true; do
          read -p "Choose upload method (scp/ftp): " transfer_method
          case "$transfer_method" in
            scp)
              read -p "Enter remote user: " remote_user
              read -p "Enter remote host: " remote_host
              read -p "Enter remote path: " remote_path
              scp "$LOG_FILE_PATH_REMOTE" "$remote_user@$remote_host:$remote_path"
              break
              ;;
            ftp)
              local ftp_command=$(handle_ftp_upload)
              if [[ -n "$ftp_command" ]]; then
                  echo "Attempting to upload..."
                  # Need to add "flash:" prefix for local FastCli copy
                  local local_ftp_cmd="flash:$(echo $ftp_command | awk '{print $2}')"
                  local ftp_destination=$(echo $ftp_command | awk '{print $3}')
                  FastCli -p 15 -c "copy $local_ftp_cmd $ftp_destination"
                  echo "Upload command sent."
              fi
              break
              ;;
            *) echo "Invalid upload method. Please enter 'scp' or 'ftp'." ;;
          esac
        done
        break
      else
        echo "Invalid input. Please enter 'y' or 'n'."
      fi
    done
  fi
}

# --- Main Logic ---
main() {
  print_header "Arista Log Collector"
  
  if [ -f /etc/Eos-release ]; then
      EXECUTION_MODE="local_eos"
  fi

  if [[ "$EXECUTION_MODE" == "remote" ]]; then
    trap close_ssh_master_conn EXIT
    read -p "Enter target Arista device hostname or IP: " TARGET_HOST
    read -p "Enter username [admin]: " USERNAME
    USERNAME=${USERNAME:-admin}
    get_case_number
    start_ssh_master_conn

    local version_output=$(ssh_exec $'enable\nterminal length 0\nshow version')
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
        local version_output=$(FastCli -p 15 -c "show version")
        collect_eos_logs "$version_output"
    fi
  fi
  
  transfer_logs
  print_header "Script finished."
}

# Kick off the script
main
