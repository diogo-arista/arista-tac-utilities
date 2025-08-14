#!/bin/bash
#================================================================================
# Arista Log Collector Script (v17.1)
# - Fix: argument parser typo (esac)
# - Fix: robust remote bash quoting (ssh_bash)
# - Plus all v17 improvements
#================================================================================

set -euo pipefail

# --- Global Variables ---
EXECUTION_MODE="remote"           # "remote" (workstation) or "local_eos" (on-device)
CONTROL_SOCKET=""
TARGET_HOST=""
USERNAME=""
case_number=""
LOG_FILE_NAME=""                  # e.g. support-bundle-xxx.zip or legacy-techsupport-*.tar.gz
LOG_FILE_FLASH=""                 # e.g. flash:support-bundle-xxx.zip
LOG_FILE_PATH_REMOTE=""           # e.g. /mnt/flash/support-bundle-xxx.zip
FLASH_DIR="/mnt/flash"

# SSH options
STRICT_SSH="no"
SSH_BASE_OPTS=()
SCP_BASE_OPTS=()

# --- Helpers ---
print_header() {
  echo ""
  echo "-----------------------------------------------------"
  echo "  $1"
  echo "-----------------------------------------------------"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--strict-hostkey]

Options:
  --strict-hostkey   Enable StrictHostKeyChecking=yes (default is no for convenience)
  -h, --help         Show this help
EOF
}

# URL-encode stdin to stdout (for FTP credentials)
urlencode() {
  local c
  while IFS= read -r -n1 c; do
    case "$c" in
      [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
      *) printf '%%%02X' "'$c" ;;
    esac
  done
}

ver_ge() {  # usage: ver_ge MIN CURRENT -> true if CURRENT >= MIN
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

# --- SSH Connection Management (for Remote Execution) ---
configure_ssh_opts() {
  if [[ "$STRICT_SSH" == "yes" ]]; then
    SSH_BASE_OPTS=(-o StrictHostKeyChecking=yes)
    SCP_BASE_OPTS=(-o StrictHostKeyChecking=yes)
  else
    SSH_BASE_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
    SCP_BASE_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
  fi
}

start_ssh_master_conn() {
  print_header "Establishing Remote Connection"
  echo "You will be prompted for the password for '$USERNAME@$TARGET_HOST'."

  mkdir -p ~/.ssh
  CONTROL_SOCKET=~/.ssh/control-${USERNAME}@${TARGET_HOST}-$$

  ssh -M -S "$CONTROL_SOCKET" -fN -o ConnectTimeout=10 "${SSH_BASE_OPTS[@]}" "$USERNAME@$TARGET_HOST" || {
    echo "SSH master connection failed. Please check credentials and connectivity."
    rm -f "$CONTROL_SOCKET" 2>/dev/null || true
    exit 1
  }

  if ! ssh -S "$CONTROL_SOCKET" -O check "${SSH_BASE_OPTS[@]}" "$USERNAME@$TARGET_HOST" >/dev/null 2>&1; then
    echo "SSH master connection not available."
    rm -f "$CONTROL_SOCKET" 2>/dev/null || true
    exit 1
  fi
  echo "Connection successful. Proceeding..."
}

close_ssh_master_conn() {
  if [[ -n "${CONTROL_SOCKET:-}" && -e "$CONTROL_SOCKET" ]]; then
    echo "Closing SSH master connection."
    ssh -S "$CONTROL_SOCKET" -O exit "${SSH_BASE_OPTS[@]}" "$USERNAME@$TARGET_HOST" >/dev/null 2>&1 || true
  fi
}

# Wrappers for remote execution
ssh_cli() {
  # Runs EOS CLI commands via Cli -c "..." (semicolon-separated)
  # Example: ssh_cli "enable; terminal length 0; show version"
  ssh -S "$CONTROL_SOCKET" "${SSH_BASE_OPTS[@]}" "$USERNAME@$TARGET_HOST" \
    "Cli -c \"$*\""
}

ssh_bash() {
  # Run an arbitrary bash command on the device using EOS Cli -> bash -lc "<cmd>"
  # We escape backslashes and double quotes so they survive all layers.
  local cmd="$*"
  cmd=${cmd//\\/\\\\}
  cmd=${cmd//\"/\\\"}
  ssh -S "$CONTROL_SOCKET" "${SSH_BASE_OPTS[@]}" "$USERNAME@$TARGET_HOST" \
    "Cli -c \"enable; bash -lc \\\"$cmd\\\"\""
}

scp_exec() {
  # scp from device to local machine
  scp -o "ControlPath=$CONTROL_SOCKET" "${SCP_BASE_OPTS[@]}" "$@"
}

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict-hostkey) STRICT_SSH="yes"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done
configure_ssh_opts
trap close_ssh_master_conn EXIT INT TERM

# --- Initial Setup ---
get_case_number() {
  read -r -p "Enter TAC case number [000000]: " case_number
  case_number=${case_number:-000000}
}

# --- Version & Environment ---
parse_eos_version() {
  # Accepts 'show version' output on stdin
  # Prints the version token (e.g., 4.30.3M)
  awk -F': *' '/Software image version/ {print $2; exit}' | awk '{print $1}'
}

# --- Log Collection ---
collect_eos_logs() {
  local version_output="$1"
  print_header "Collecting EOS Logs"

  local eos_version required_version
  eos_version=$(echo "$version_output" | parse_eos_version)
  required_version="4.26.1F"
  echo "Detected EOS version: ${eos_version:-unknown}"

  echo ""
  echo "Starting the log collection process..."
  echo "This may take from a few to several minutes. Please do not interrupt the script."
  echo ""

  if [[ -z "$eos_version" ]]; then
    echo "Could not parse EOS version from 'show version' output." >&2
    exit 1
  fi

  if ver_ge "$required_version" "$eos_version"; then
    echo "Using 'send support-bundle' command."
    local bundle_output filename
    if [[ "$EXECUTION_MODE" == "remote" ]]; then
      bundle_output=$(ssh_cli "enable; send support-bundle flash:/ case-number $case_number")
    else
      bundle_output=$(FastCli -p 15 -c "send support-bundle flash:/ case-number $case_number")
    fi
    filename=$(echo "$bundle_output" | grep -o 'support-bundle-.*\.zip' | head -n 1 || true)
    if [[ -z "$filename" ]]; then
      echo "Error: Could not determine the name of the generated support bundle." >&2
      exit 1
    fi
    LOG_FILE_NAME="$filename"
  else
    echo "Using legacy log collection for EOS < $required_version"
    local legacy_name="legacy-techsupport-$(date +%Y%m%d-%H%M%S).tar.gz"
    # Capture tech-support to flash and tar it
    if [[ "$EXECUTION_MODE" == "remote" ]]; then
      ssh_cli "enable; terminal length 0; show tech-support | redirect flash:tech-support.txt"
      ssh_bash "cd $FLASH_DIR && tar -czf \"$legacy_name\" tech-support.txt"
    else
      FastCli -p 15 -c "terminal length 0; show tech-support | redirect flash:tech-support.txt"
      FastCli -p 15 -c "bash -lc 'cd $FLASH_DIR && tar -czf \"$legacy_name\" tech-support.txt'"
    fi
    LOG_FILE_NAME="$legacy_name"
  fi

  LOG_FILE_FLASH="flash:${LOG_FILE_NAME}"
  LOG_FILE_PATH_REMOTE="${FLASH_DIR}/${LOG_FILE_NAME}"

  echo "Log bundle created on device: $LOG_FILE_PATH_REMOTE"

  # Show size / free space
  if [[ "$EXECUTION_MODE" == "remote" ]]; then
    ssh_bash "ls -lh \"$LOG_FILE_PATH_REMOTE\" || stat -c '%n %s bytes' \"$LOG_FILE_PATH_REMOTE\"; echo; df -h \"$FLASH_DIR\" | tail -1"
  else
    FastCli -p 15 -c "bash -lc 'ls -lh \"$LOG_FILE_PATH_REMOTE\" || stat -c \"%n %s bytes\" \"$LOG_FILE_PATH_REMOTE\"; echo; df -h \"$FLASH_DIR\" | tail -1'"
  fi
}

# --- FTP Destination Builder ---
# Prompts user and returns the FTP URL (ftp://user:pass@host/path/)
handle_ftp_destination() {
  local ftp_url=""
  while true; do
    read -r -p "Upload to Arista FTP server (ftp.arista.com)? [Y/n/c] (Yes/No/Cancel): " ftp_choice
    ftp_choice=${ftp_choice:-Y}
    case "$ftp_choice" in
      [Yy])
        local ftp_server="ftp.arista.com"
        local ftp_user="anonymous"
        local ftp_pass
        read -r -p "Please enter your email address for the FTP password: " ftp_pass
        if [[ -z "$ftp_pass" ]]; then
          echo "Email is required for the Arista FTP server. Please try again."
          continue
        fi
        local enc_pass
        enc_pass=$(printf '%s' "$ftp_pass" | urlencode)
        ftp_url="ftp://$ftp_user:$enc_pass@$ftp_server/support/$case_number/"
        break
        ;;
      [Nn])
        local ftp_server ftp_user ftp_pass enc_pass
        read -r -p "Enter custom FTP server address: " ftp_server
        [[ -z "$ftp_server" ]] && { echo "Server address cannot be empty."; continue; }
        read -r -p "Enter FTP username: " ftp_user
        [[ -z "$ftp_user" ]] && { echo "Username cannot be empty."; continue; }
        read -s -r -p "Enter FTP password: " ftp_pass; echo ""
        enc_pass=$(printf '%s' "$ftp_pass" | urlencode)
        ftp_url="ftp://$ftp_user:$enc_pass@$ftp_server/"
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
  echo "$ftp_url"
}

# --- Main File Transfer Logic ---
transfer_logs() {
  [[ -n "${LOG_FILE_PATH_REMOTE:-}" ]] || return 0

  print_header "File Transfer"

  if [[ "$EXECUTION_MODE" == "remote" ]]; then
    while true; do
      echo "Log bundle is on device: $LOG_FILE_PATH_REMOTE"
      echo "What would you like to do?"
      echo "  1. Download file to this machine"
      echo "  2. Send file from device to another server (SCP/FTP via EOS 'copy')"
      echo "  3. Do nothing"
      read -r -p "Choose an option [1-3]: " choice

      case "$choice" in
        1)
          scp_exec "$USERNAME@$TARGET_HOST:$LOG_FILE_PATH_REMOTE" .
          echo "Download complete: ./$(basename "$LOG_FILE_PATH_REMOTE")"
          break
          ;;
        2)
          while true; do
            read -r -p "Choose upload method (scp/ftp): " upload_method
            case "$upload_method" in
              scp)
                local dest_user dest_host dest_path scp_url
                read -r -p "Enter destination user: " dest_user
                read -r -p "Enter destination host: " dest_host
                read -r -p "Enter destination path (e.g. /incoming/): " dest_path
                [[ "$dest_path" != /* ]] && dest_path="/$dest_path"
                scp_url="scp://$dest_user@$dest_host$dest_path"
                echo "Executing on device: copy $LOG_FILE_FLASH $scp_url"
                ssh_cli "enable; copy $LOG_FILE_FLASH $scp_url"
                echo "Upload command sent (device may prompt for password on its console/log)."
                break
                ;;
              ftp)
                local ftp_url
                ftp_url=$(handle_ftp_destination)
                if [[ -n "$ftp_url" ]]; then
                  echo "Executing on device: copy $LOG_FILE_FLASH $ftp_url"
                  ssh_cli "enable; copy $LOG_FILE_FLASH $ftp_url"
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
  else
    # On-Device mode: use EOS 'copy' for uploads
    while true; do
      read -r -p "Do you want to send the log file to a remote location? (y/n): " transfer_choice
      case "$transfer_choice" in
        n|N) echo "Skipping upload."; break ;;
        y|Y)
          while true; do
            read -r -p "Choose upload method (scp/ftp): " transfer_method
            case "$transfer_method" in
              scp)
                local remote_user remote_host remote_path scp_url
                read -r -p "Enter remote user: " remote_user
                read -r -p "Enter remote host: " remote_host
                read -r -p "Enter remote path (e.g. /incoming/): " remote_path
                [[ "$remote_path" != /* ]] && remote_path="/$remote_path"
                scp_url="scp://$remote_user@$remote_host$remote_path"
                FastCli -p 15 -c "copy $LOG_FILE_FLASH $scp_url"
                echo "Upload command sent."
                break
                ;;
              ftp)
                local ftp_url
                ftp_url=$(handle_ftp_destination)
                if [[ -n "$ftp_url" ]]; then
                  FastCli -p 15 -c "copy $LOG_FILE_FLASH $ftp_url"
                  echo "Upload command sent."
                fi
                break
                ;;
              *) echo "Invalid upload method. Please enter 'scp' or 'ftp'." ;;
            esac
          done
          break
          ;;
        *)
          echo "Invalid input. Please enter 'y' or 'n'."
          ;;
      esac
    done
  fi
}

# --- Main Logic ---
main() {
  print_header "Arista Log Collector (v17.1)"

  # Detect on-device
  if [[ -f /etc/Eos-release ]]; then
    EXECUTION_MODE="local_eos"
  fi

  if [[ "$EXECUTION_MODE" == "remote" ]]; then
    read -r -p "Enter target Arista device hostname or IP: " TARGET_HOST
    read -r -p "Enter username [admin]: " USERNAME
    USERNAME=${USERNAME:-admin}
    get_case_number
    start_ssh_master_conn

    # Show version
    local version_output
    version_output=$(ssh_cli "enable; terminal length 0; show version")
    if echo "$version_output" | grep -qi "Arista"; then
      collect_eos_logs "$version_output"
    else
      echo "Could not determine the OS of the remote device." >&2
      exit 1
    fi
  else
    print_header "Running in On-Device Mode"
    get_case_number
    local version_output
    version_output=$(FastCli -p 15 -c "terminal length 0; show version")
    collect_eos_logs "$version_output"
  fi

  transfer_logs
  print_header "Script finished."
}

main
