#!/bin/bash
set -euo pipefail

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

  # WARNING: StrictHostKeyChecking=no is removed for security.
  # On first connection, you will be prompted to verify the host key.
  # To avoid future prompts, add the host key to ~/.ssh/known_hosts.
  ssh -M -S "$CONTROL_SOCKET" -fN -o ConnectTimeout=10 "$USERNAME@$TARGET_HOST"

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
  # Removed StrictHostKeyChecking=no for security.
  scp -o "ControlPath=$CONTROL_SOCKET" "$@"
}

# --- Initial Setup ---
get_case_number() {
  while true; do
    read -p "Enter TAC case number [000000]: " case_number
    case_number=${case_number:-000000}
    if [[ "$case_number" =~ ^[0-9]+$ ]]; then
      break
    else
      echo "Invalid TAC case number. Please enter a numeric value."
    fi
  done
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
    local command_status=0

    if [[ "$EXECUTION_MODE" == "remote" ]]; then
        bundle_output=$(ssh_exec $'enable\nsend support-bundle flash:/ case-number '"$case_number" 2>&1) || command_status=$?
    else # Local execution
        bundle_output=$(FastCli -p 15 -c "send support-bundle flash:/ case-number $case_number" 2>&1) || command_status=$?
    fi

    if [[ "$command_status" -ne 0 ]]; then
        echo "Error: Failed to generate support bundle. Command exited with status $command_status."
        echo "Output: $bundle_output"
        exit 1
    fi
    
    local filename
    filename=$(echo "$bundle_output" | grep -o 'support-bundle-.*\.zip' | head -n 1)
    
    if [[ -z "$filename" ]]; then
        echo "Error: Could not determine the name of the generated support bundle from the output."
        echo "Please check the device output for errors or unexpected format."
        echo "Output: $bundle_output"
        exit 1
    fi
    LOG_FILE_PATH_REMOTE="/mnt/flash/$filename"
  else
    echo "EOS version $eos_version is older than the required version 4.26.1F."
    echo "Legacy log collection logic is not implemented in this script version."
    echo "Please update the device to EOS 4.26.1F or newer, or use an older log collector script."
    exit 1
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
                # Basic validation for IP address or hostname
                if [[ -z "$ftp_server" ]]; then
                    echo "Server address cannot be empty."
                    continue
                elif ! [[ "$ftp_server" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$ftp_server" =~ ^[a-zA-Z0-9.-]+$ ]]; then
                    echo "Invalid FTP server address. Please enter a valid IP address or hostname."
                    continue
                fi
                read -p "Enter FTP username: " ftp_user
                if [[ -z "$ftp_user" ]]; then echo "Username cannot be empty."; continue; fi
                read -s -p "Enter FTP password: " ftp_pass
                echo ""
                local encoded_pass=${ftp_pass//@/%40}
                read -p "Enter custom FTP destination path (e.g., /path/to/uploads/): " custom_ftp_path
                custom_ftp_path=${custom_ftp_path:-/} # Default to root if empty
                ftp_command="copy $(basename "$LOG_FILE_PATH_REMOTE") ftp://$ftp_user:$encoded_pass@$ftp_server/$custom_ftp_path"
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

# Helper function to perform upload (SCP or FTP)
# Arguments: $1 = "remote" or "local", $2 = LOG_FILE_PATH_REMOTE
perform_upload() {
  local mode="$1"
  local log_file="$2"
  local upload_method

  while true; do
    read -p "Choose upload method (scp/ftp): " upload_method
    case "$upload_method" in
      scp)
        read -p "Enter destination user: " dest_user
        read -p "Enter destination host: " dest_host
        read -p "Enter destination path: " dest_path
        
        if [[ "$mode" == "remote" ]]; then
          # Escape user inputs for the remote shell to prevent command injection
          local escaped_dest_user=$(printf %q "$dest_user")
          local escaped_dest_host=$(printf %q "$dest_host")
          local escaped_dest_path=$(printf %q "$dest_path")
          local remote_scp_cmd="scp ${log_file} ${escaped_dest_user}@${escaped_dest_host}:${escaped_dest_path}"
          if ssh_exec $'enable\n'"$remote_scp_cmd"; then
              echo "SCP upload command sent to device."
          else
              echo "Error: Failed to send SCP command to device."
              exit 1
          fi
        else # Local execution
          if scp "$log_file" "$dest_user@$dest_host:$dest_path"; then
              echo "SCP upload complete."
          else
              echo "Error: Failed to upload file via SCP."
              exit 1
          fi
        fi
        break
        ;;
      ftp)
        local ftp_command=$(handle_ftp_upload)
        if [[ -n "$ftp_command" ]]; then
            echo "Attempting to upload..."
            if [[ "$mode" == "remote" ]]; then
                echo "Executing on device: $ftp_command"
                if ssh_exec $'enable\n'"$ftp_command"; then
                    echo "FTP upload command sent to device."
                else
                    echo "Error: Failed to send FTP command to device."
                    exit 1
                fi
            else # Local execution
                # Need to add "flash:" prefix for local FastCli copy
                local local_ftp_cmd="flash:$(echo "$ftp_command" | awk '{print $2}')"
                local ftp_destination=$(echo "$ftp_command" | awk '{print $3}')
                if FastCli -p 15 -c "copy $local_ftp_cmd $ftp_destination"; then
                    echo "FTP upload command sent."
                else
                    echo "Error: Failed to send FTP command via FastCli."
                    exit 1
                fi
            fi
        fi
        break
        ;;
      *) echo "Invalid upload method. Please enter 'scp' or 'ftp'." ;;
    esac
  done
}

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
            if scp_exec "$USERNAME@$TARGET_HOST:$LOG_FILE_PATH_REMOTE" .; then
                echo "Download complete."
            else
                echo "Error: Failed to download file."
                exit 1
            fi
            break
            ;;
        2)
            perform_upload "remote" "$LOG_FILE_PATH_REMOTE"
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
        perform_upload "local" "$LOG_FILE_PATH_REMOTE"
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

    local version_output
    if ! version_output=$(ssh_exec $'enable\nterminal length 0\nshow version' 2>&1); then
      echo "Error: Failed to get version from remote device."
      echo "Output: $version_output"
      exit 1
    fi

    if echo "$version_output" | grep -qi "Arista"; then
      collect_eos_logs "$version_output"
    else
      echo "Error: Could not determine the OS of the remote device. Output did not contain 'Arista'."
      echo "Output: $version_output"
      exit 1
    fi
  else # On-Device Execution
    print_header "Running in On-Device Mode"
    get_case_number

    if [[ "$EXECUTION_MODE" == "local_eos" ]]; then
        local version_output
        if ! version_output=$(FastCli -p 15 -c "show version" 2>&1); then
            echo "Error: Failed to get version from local EOS device."
            echo "Output: $version_output"
            exit 1
        fi
        collect_eos_logs "$version_output"
    fi
  fi
  
  transfer_logs
  print_header "Script finished."
}

# Kick off the script
main
