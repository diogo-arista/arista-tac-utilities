#!/bin/bash

#================================================================================
# Arista Log Collector Script (Final Version)
#
# This script collects logs from Arista devices running EOS.
# It functions when run from a remote host OR on the device itself.
#================================================================================

# --- Global Variables ---
EXECUTION_MODE="remote"
CONTROL_SOCKET=""
TARGET_HOST=""
USERNAME=""
LOG_FILE_PATH_REMOTE=""
case_number=""
transfer_protocol=""
remote_host=""
vrf_name=""
using_default_ftp=false

# --- Helper Functions ---
print_header() {
  echo ""
  echo "-----------------------------------------------------"
  echo "  $1"
  echo "-----------------------------------------------------"
}

show_help() {
  echo "Arista Log Collector Script"
  echo ""
  echo "Usage: ./log-collector.sh [-d <device>] [-u <user>] [-c <case>] [-t <proto>] [-r <host>] [-v <vrf>] [-h]"
  echo ""
  echo "This script collects support logs from Arista EOS devices."
  echo "It can be run with arguments to perform an initial transfer automatically."
  echo ""
  echo "Options:"
  echo "  -d <device>        Target device hostname or IP address."
  echo "  -u <user>          Username for logging in."
  echo "  -c <case>          TAC case number."
  echo "  -t <proto>         Initial transfer protocol ('scp' or 'ftp')."
  echo "  -r <host>          Remote host for the initial transfer."
  echo "  -v <vrf>           VRF to use for the transfer (e.g., 'management')."
  echo "  -h                 Display this help message and exit."
  echo ""
  echo "If options are omitted, the script will be fully interactive."
}


# --- SSH Connection Management ---
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
ssh_exec() { ssh -S "$CONTROL_SOCKET" -o StrictHostKeyChecking=no "$USERNAME@$TARGET_HOST" "$@"; }
scp_exec() { scp -o "ControlPath=$CONTROL_SOCKET" -o StrictHostKeyChecking=no "$@"; }

# --- Initial Setup ---
get_case_number() {
  if [[ -z "$case_number" ]]; then
    read -p "Enter TAC case number [000000]: " case_number
    case_number=${case_number:-000000}
  else
    echo "Using Case Number from argument: $case_number" >&2
  fi
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
  required_version="4.26.1F"
  
  if [[ "$(printf '%s\n' "$required_version" "$eos_version" | sort -V | head -n1)" == "$required_version" ]]; then
    # --- REAL LOG COLLECTION ---
    echo "This may take from a few to several minutes. Please do not interrupt the script."
    echo ""
    echo "Using 'send support-bundle' command. You will now see the live output from the device."
    print_header "Live Device Output - Start"
    
    if [[ "$EXECUTION_MODE" == "remote" ]]; then
        ssh_exec $'enable\nsend support-bundle flash:/ case-number '"$case_number"
    else # Local execution
        FastCli -p 15 -c "send support-bundle flash:/ case-number $case_number"
    fi

    print_header "Live Device Output - End"
    echo "Log generation command finished. Locating the created file..."

    local filename_path
    if [[ "$EXECUTION_MODE" == "remote" ]]; then
        filename_path=$(ssh_exec $'enable\nbash ls -1t /mnt/flash/support-bundle-*'"$case_number"'*.zip 2>/dev/null | head -n 1')
    else # Local execution
        filename_path=$(ls -1t /mnt/flash/support-bundle-*${case_number}*.zip 2>/dev/null | head -1)
    fi

    if [[ -n "$filename_path" ]]; then
        LOG_FILE_PATH_REMOTE=$(echo "$filename_path" | tr -d '\r')
    else
        echo "Error: Could not find the generated support bundle on the device's flash."
        exit 1
    fi
    # --- END REAL LOG COLLECTION ---
  else
    # --- REAL LEGACY LOG COLLECTION ---
    echo "Using legacy log collection commands for EOS versions older than 4.26.1F."
    echo "This may take several minutes. Please wait..."
    local hostname datetime_tar
    
    if [[ "$EXECUTION_MODE" == "remote" ]]; then
        hostname=$(ssh_exec $'enable\nshow hostname' | grep "Hostname:" | awk '{print $2}' | tr -d '\r')
        datetime_tar=$(ssh_exec $'enable\nbash date "+%F--%H%M"' | tr -d '\r')
        
        ssh_exec $'enable\nshow tech-support | gzip > "/mnt/flash/'"$case_number"'-'"$hostname"'-show-tech.log.gz"'
        ssh_exec $'enable\nbash sudo tar -czvf "/mnt/flash/'"$case_number"'-'"$hostname"'-misc-logs.tar.gz" /var/log/ /mnt/flash/debug/ /mnt/flash/Fossil/ 2>/dev/null'
        
        ssh_exec $'enable\nbash (cd /mnt/flash && tar --remove-files -cf "TAC-bundle-'"$case_number"'-'"$hostname"'-'"$datetime_tar"'.tar" '"$case_number"'-*.gz)'
        
        LOG_FILE_PATH_REMOTE=$(ssh_exec $'enable\nbash ls -1t /mnt/flash/TAC-bundle-'"$case_number"'-* | head -n 1' | tr -d '\r')
    else # Local execution
        hostname=$(FastCli -p 15 -c "show hostname" | grep "Hostname:" | awk '{print $2}')
        datetime_tar=$(date "+%F--%H%M")
        
        FastCli -p 15 -c "show tech-support" | gzip > "/mnt/flash/$case_number-$hostname-show-tech.log.gz"
        sudo tar -czvf "/mnt/flash/$case_number-$hostname-misc-logs.tar.gz" /var/log/ /mnt/flash/debug/ /mnt/flash/Fossil/ >/dev/null 2>&1
        
        (cd /mnt/flash && sudo tar --remove-files -cf "TAC-bundle-$case_number-$hostname-$datetime_tar.tar" "$case_number"*.gz)
        
        LOG_FILE_PATH_REMOTE=$(ls -1t /mnt/flash/TAC-bundle-"$case_number"-* | head -1)
    fi
    # --- END REAL LEGACY LOG COLLECTION ---
  fi
  echo "Log bundle created on device: $LOG_FILE_PATH_REMOTE"
}

# --- File Transfer Action Functions ---
perform_download() {
    echo "" >&2; echo "---> Performing Download..." >&2
    scp_exec "$USERNAME@$TARGET_HOST:$LOG_FILE_PATH_REMOTE" .
    echo "Download complete." >&2
}

perform_scp_upload() {
    echo "" >&2; echo "---> Performing SCP Upload..." >&2
    local dest_host=$1
    local transfer_vrf=$vrf_name
    if [[ -z "$dest_host" ]]; then read -p "Enter destination host: " dest_host; else echo "Using destination host from argument: $dest_host" >&2; fi
    read -p "Enter destination user: " dest_user
    read -p "Enter destination path: " dest_path
    if [[ -z "$transfer_vrf" ]]; then read -p "Enter VRF for this transfer [default]: " transfer_vrf; transfer_vrf=${transfer_vrf:-default}; else echo "Using VRF from argument: $transfer_vrf" >&2; fi
    local scp_url="scp://$dest_user@$dest_host/$dest_path"
    local copy_command="copy flash:$(basename "$LOG_FILE_PATH_REMOTE") $scp_url"
    local final_sequence
    if [[ "$transfer_vrf" == "default" ]]; then final_sequence="$copy_command"; else final_sequence="run cli vrf $transfer_vrf ; $copy_command"; fi
    if [[ "$EXECUTION_MODE" == "remote" ]]; then echo "Executing on device: $final_sequence" >&2; ssh_exec $'enable\n'"$final_sequence"; else echo "Executing: $final_sequence" >&2; FastCli -p 15 -c "$final_sequence"; fi
    echo "Upload command sent." >&2
}

perform_ftp_upload() {
    echo "" >&2; echo "---> Performing FTP Upload..." >&2
    local ftp_url=$(handle_ftp_upload "$1")
    if [[ -n "$ftp_url" ]]; then
        local transfer_vrf=$vrf_name
        if [[ -z "$transfer_vrf" ]]; then read -p "Enter VRF for this transfer [default]: " transfer_vrf; transfer_vrf=${transfer_vrf:-default}; else echo "Using VRF from argument: $transfer_vrf" >&2; fi
        local copy_command="copy flash:$(basename "$LOG_FILE_PATH_REMOTE") $ftp_url"
        local final_sequence
        if [[ "$transfer_vrf" == "default" ]]; then final_sequence="$copy_command"; else final_sequence="run cli vrf $transfer_vrf ; $copy_command"; fi
        if [[ "$EXECUTION_MODE" == "remote" ]]; then echo "Executing on device: $final_sequence" >&2; ssh_exec $'enable\n'"$final_sequence"; else echo "Executing: $final_sequence" >&2; FastCli -p 15 -c "$final_sequence"; fi
        echo "Upload command sent." >&2
    fi
}

handle_ftp_upload() {
    local ftp_url_suffix=""
    local ftp_server=$1
    if [[ -n "$ftp_server" ]]; then
        if [[ "$ftp_server" == "ftp.arista.com" ]]; then
            if [[ "$using_default_ftp" = true ]]; then echo "Using default Arista FTP server: ftp.arista.com" >&2; fi
            local ftp_user="anonymous"; read -p "Please enter your email address for the FTP password: " ftp_pass
            if [[ -z "$ftp_pass" ]]; then echo "Email is required. FTP cancelled." >&2; return; fi
            local encoded_pass=${ftp_pass//@/%40}; ftp_url_suffix="ftp://$ftp_user:$encoded_pass@$ftp_server/support/$case_number/"
        else
             echo "Using FTP server from argument: $ftp_server" >&2; read -p "Enter FTP username: " ftp_user
             if [[ -z "$ftp_user" ]]; then echo "Username cannot be empty. FTP cancelled." >&2; return; fi
             read -s -p "Enter FTP password: " ftp_pass; echo ""; local encoded_pass=${ftp_pass//@/%40}; ftp_url_suffix="ftp://$ftp_user:$encoded_pass@$ftp_server/"
        fi
    else
        while true; do read -p "Upload to Arista FTP server (ftp.arista.com)? [Y/n/c]: " ftp_choice; ftp_choice=${ftp_choice:-Y}; case "$ftp_choice" in [Yy]) local ftp_server="ftp.arista.com"; local ftp_user="anonymous"; read -p "Email for FTP pass: " ftp_pass; if [[ -z "$ftp_pass" ]]; then echo "Email required."; continue; fi; local encoded_pass=${ftp_pass//@/%40}; ftp_url_suffix="ftp://$ftp_user:$encoded_pass@$ftp_server/support/$case_number/"; break ;; [Nn]) read -p "Custom FTP server: " ftp_server; read -p "FTP user: " ftp_user; read -s -p "FTP pass: " ftp_pass; echo ""; local encoded_pass=${ftp_pass//@/%40}; ftp_url_suffix="ftp://$ftp_user:$encoded_pass@$ftp_server/"; break ;; [Cc]) echo "FTP cancelled."; break ;; *) echo "Invalid option." ;; esac; done
    fi
    echo "$ftp_url_suffix"
}

# --- Main File Transfer Logic ---
transfer_logs() {
  if [[ -z "$LOG_FILE_PATH_REMOTE" ]]; then return; fi
  print_header "File Transfer"
  if [[ -n "$transfer_protocol" ]]; then
    echo "Performing initial transfer based on arguments..." >&2
    case "$transfer_protocol" in
      scp) perform_scp_upload "$remote_host" ;;
      ftp) perform_ftp_upload "$remote_host" ;;
    esac
  fi
  if [[ "$EXECUTION_MODE" == "remote" ]]; then
    while true; do echo "" >&2; echo "Log bundle is on device: $LOG_FILE_PATH_REMOTE" >&2; echo "  1. Download file to this machine" >&2; echo "  2. Send file from device to another server" >&2; echo "  3. Exit Script" >&2; read -p "Choose an option [1-3]: " choice; case "$choice" in 1) perform_download ;; 2) while true; do read -p "Choose upload method [ftp/scp]: " um; um=${um:-ftp}; case "$um" in scp) perform_scp_upload; break ;; ftp) perform_ftp_upload; break ;; *) echo "Invalid method." >&2;; esac; done ;; 3) echo "Exiting file transfer menu." >&2; break ;; *) echo "Invalid option." >&2;; esac; done
  else # Local
    while true; do echo "" >&2; echo "Log bundle is on device: $LOG_FILE_PATH_REMOTE" >&2; echo "  1. Send file to a remote location" >&2; echo "  2. Exit Script" >&2; read -p "Choose an option [1-2]: " choice; case "$choice" in 1) while true; do read -p "Choose upload method [ftp/scp]: " um; um=${um:-ftp}; case "$um" in scp) perform_scp_upload; break ;; ftp) perform_ftp_upload; break ;; *) echo "Invalid method." >&2;; esac; done ;; 2) echo "Exiting file transfer menu." >&2; break ;; *) echo "Invalid option." >&2;; esac; done
  fi
}

# --- Main Logic ---
main() {
  while getopts "hd:u:c:t:r:v:" opt; do
    case $opt in
      h) show_help; exit 0 ;;
      d) TARGET_HOST="$OPTARG" ;;
      u) USERNAME="$OPTARG" ;;
      c) case_number="$OPTARG" ;;
      t) transfer_protocol="$OPTARG" ;;
      r) remote_host="$OPTARG" ;;
      v) vrf_name="$OPTARG" ;;
      \?) echo "Invalid option: -$OPTARG" >&2; show_help; exit 1 ;;
      :) echo "Option -$OPTARG requires an argument." >&2; show_help; exit 1 ;;
    esac
  done
  if [[ "$transfer_protocol" == "scp" && -z "$remote_host" ]]; then echo "Error: -r <remote_host> is required for -t scp." >&2; exit 1; fi
  if [[ "$transfer_protocol" == "ftp" && -z "$remote_host" ]]; then remote_host="ftp.arista.com"; using_default_ftp=true; fi
  print_header "Arista Log Collector"
  if [ -f /etc/Eos-release ]; then EXECUTION_MODE="local_eos"; fi
  if [[ "$EXECUTION_MODE" == "remote" ]]; then
    trap close_ssh_master_conn EXIT
    if [[ -z "$TARGET_HOST" ]]; then read -p "Enter target Arista device hostname or IP: " TARGET_HOST; else echo "Using Target Host from argument: $TARGET_HOST" >&2; fi
    if [[ -z "$USERNAME" ]]; then read -p "Enter username [admin]: " USERNAME; USERNAME=${USERNAME:-admin}; else echo "Using Username from argument: $USERNAME" >&2; fi
    get_case_number
    start_ssh_master_conn
    local version_output=$(ssh_exec $'enable\nterminal length 0\nshow version')
    if echo "$version_output" | grep -qi "Arista"; then collect_eos_logs "$version_output"; else echo "Could not determine OS."; exit 1; fi
  else # On-Device
    print_header "Running in On-Device Mode"
    get_case_number
    if [[ "$EXECUTION_MODE" == "local_eos" ]]; then local version_output=$(FastCli -p 15 -c "show version"); collect_eos_logs "$version_output"; fi
  fi
  transfer_logs
  print_header "Script finished."
}

main "$@"