#!/bin/bash

# #############################################################################
# Arista TAC Log Collection Script (v27)
#
# This script collects a support bundle from an Arista EOS device.
# It can be run directly on the EOS device or remotely from a client machine.
#
# Changelog:
# v27: Final fix for on-box FTP transfers. Correctly constructs the remote
#      URL path and adds a note about pre-existing directories.
# v26: Corrected FTP URL construction and copy command pathing.
#
# #############################################################################

# --- Functions ---

display_help() {
    echo "Arista TAC Log Collection Script"
    echo "Automates log collection. Can be run on-box or remotely."
    echo ""
    echo "USAGE:"
    echo "  bash $(basename "$0") [CASE_NUMBER] [OPTIONS]"
    echo ""
    echo "ARGUMENTS:"
    echo "  [CASE_NUMBER]    (Optional) The TAC case number. If not provided,"
    echo "                   a placeholder will be used."
    echo ""
    echo "OPTIONS:"
    echo "  -h, --help       Display this help message and exit."
}

version_ge() {
    test "$(printf '%s\n' "$1" "$2" | sort -V | head -n 1)" = "$2"
}

decompress_bundle() {
    local local_bundle_path="$1"
    if [[ ! -f "$local_bundle_path" ]]; then return 1; fi
    local local_dir
    local bundle_filename
    local subfolder_name
    local decompression_path
    local_dir=$(dirname "$local_bundle_path")
    bundle_filename=$(basename "$local_bundle_path")
    subfolder_name="${bundle_filename%.zip}"
    subfolder_name="${subfolder_name%.tar}"
    subfolder_name="${subfolder_name%.tar.gz}"
    decompression_path="${local_dir}/${subfolder_name}"
    read -p "Would you like to decompress the bundle into './${decompression_path}/'? [y/N]: " decompress_choice
    if [[ "$decompress_choice" =~ ^[Yy]$ ]]; then
        echo "Decompressing bundle..."
        mkdir -p "$decompression_path"
        if [[ "$bundle_filename" == *.zip ]]; then
            unzip -q "$local_bundle_path" -d "$decompression_path"
        elif [[ "$bundle_filename" == *.tar* ]]; then
            tar -xf "$local_bundle_path" -C "$decompression_path"
        fi
        echo "Successfully decompressed to: ${decompression_path}"
    fi
}

transfer_onbox_bundle() {
    local local_file_path="$1"
    if [[ ! -f "$local_file_path" ]]; then
        echo "Error: Source bundle file not found at ${local_file_path}."
        return 1
    fi

    read -p "Would you like to transfer this bundle to a remote host? [y/N]: " transfer_choice
    if [[ ! "$transfer_choice" =~ ^[Yy]$ ]]; then
        echo -e "\n-----------\n\nCompleted. Please download the bundle from the switch at: \n\n ${local_file_path} \n"
        return 0
    fi

    read -p "Protocol to use for transfer [scp/ftp]: " protocol
    protocol=${protocol:-scp}

    local remote_host
    local remote_user
    local remote_url
    local source_filename
    source_filename=$(basename "$local_file_path")

    if [[ "$protocol" == "ftp" ]]; then
        echo "FTP transfer selected."
        read -p "FTP server address [ftp.arista.com]: " temp_host
        remote_host=${temp_host:-ftp.arista.com}
        
        read -p "FTP user [anonymous]: " remote_user
        remote_user=${remote_user:-anonymous}

        read -p "FTP root upload directory on server [/support]: " remote_root_dir
        remote_root_dir=${remote_root_dir:-/support}
        # Ensure path starts with a slash but does not end with one
        [[ "$remote_root_dir" != /* ]] && remote_root_dir="/${remote_root_dir}"
        remote_root_dir=${remote_root_dir%/}

        remote_url="ftp://${remote_user}@${remote_host}${remote_root_dir}/${CASE_NUMBER}/${source_filename}"
        echo "NOTE: For FTP to succeed, the destination directory '${remote_root_dir}/${CASE_NUMBER}/' must already exist on the server."

    elif [[ "$protocol" == "scp" ]]; then
        echo "SCP transfer selected."
        read -p "Remote host address: " remote_host
        if [[ -z "$remote_host" ]]; then echo "Error: Remote host is required."; return 1; fi
        
        read -p "Remote user [admin]: " remote_user
        remote_user=${remote_user:-admin}

        read -p "Remote path and filename [/tmp/${source_filename}]: " remote_full_path
        remote_full_path=${remote_full_path:-/tmp/${source_filename}}
        remote_url="scp://${remote_user}@${remote_host}:${remote_full_path}"
    else
        echo "Error: Unsupported protocol '${protocol}'. Aborting."
        return 1
    fi

    local final_copy_cmd="copy flash:${source_filename} ${remote_url}"

    echo "The following command will be run:"
    echo "  ${final_copy_cmd}"
    read -p "Proceed? [Y/n]: " proceed_choice
    if [[ "$proceed_choice" =~ ^[Nn]$ ]]; then
        echo "Transfer cancelled by user."
        return 1
    fi
    
    FastCli -p 15 -c "$final_copy_cmd"

    if [[ $? -eq 0 ]]; then
        echo "Transfer successful."
    else
        echo "Error: Transfer failed. Please check the URL, credentials, and network connectivity."
        echo "The file is still available on the switch at ${local_file_path}"
    fi
}


# --- Argument Parsing ---
if [[ "$1" == "-h" || "$1" == "--help" ]]; then display_help; exit 0; fi

# --- Main Script ---
echo "--- Arista TAC Log Collection Script ---"

RUN_MODE="remote"
if [ -f /usr/bin/FastCli ]; then RUN_MODE="on-box"; fi

CASE_NUMBER="$1"
if [[ -z "$CASE_NUMBER" ]]; then read -p "Please enter the TAC case number: " CASE_NUMBER; fi
if [[ -z "$CASE_NUMBER" ]]; then
    CASE_NUMBER="0000"
    echo "Warning: No case number provided. Using placeholder '${CASE_NUMBER}'. Using a real case number is highly recommended."
fi
echo "Using Case Number: $CASE_NUMBER"

# ==============================================================================
# --- REMOTE EXECUTION MODE ---
# ==============================================================================
if [[ "$RUN_MODE" == "remote" ]]; then
    echo "Running in Remote Mode."
    read -p "Enter target Arista device address: " REMOTE_HOST
    read -p "Enter username for ${REMOTE_HOST} [default: admin]: " temp_user
    REMOTE_USER=${temp_user:-admin}
    if [[ -z "$REMOTE_HOST" || -z "$REMOTE_USER" ]]; then echo "Error: Hostname and username are required."; exit 1; fi

    LOCAL_DATE_FOLDER=$(date "+%Y-%m-%d")
    mkdir -p "$LOCAL_DATE_FOLDER"
    echo "Downloaded logs will be saved to: ./${LOCAL_DATE_FOLDER}/"

    CONTROL_PATH="/tmp/ssh-mux-%r@%h:%p"
    echo "Establishing master SSH connection to ${REMOTE_HOST} as user '${REMOTE_USER}'..."
    echo "You will be prompted for the password once."

    ssh -o ControlMaster=auto -o ControlPath="$CONTROL_PATH" -o ControlPersist=120s -Nf "${REMOTE_USER}@${REMOTE_HOST}"
    SSH_STATUS=$?
    if [ $SSH_STATUS -ne 0 ]; then echo "Error: SSH connection failed."; exit $SSH_STATUS; fi

    function cleanup { ssh -o ControlPath="$CONTROL_PATH" -O exit "${REMOTE_USER}@${REMOTE_HOST}" 2>/dev/null; }
    trap cleanup EXIT

    run_remote_eos_cmd() { ssh -o ControlPath="$CONTROL_PATH" "${REMOTE_USER}@${REMOTE_HOST}" "$@"; }
    run_remote_bash_cmd() { ssh -o ControlPath="$CONTROL_PATH" "${REMOTE_USER}@${REMOTE_HOST}" bash << EOF
$@
EOF
    }
    scp_remote_file() { scp -o ControlPath="$CONTROL_PATH" "${REMOTE_USER}@${REMOTE_HOST}:$1" "$2"; }

    echo "Checking remote EOS version..."
    REMOTE_HOSTNAME=$(run_remote_eos_cmd show hostname | awk '/Hostname:/ {print $2}')
    REMOTE_EOS_VERSION=$(run_remote_eos_cmd show version | grep 'Software image version' | awk '{print $4}')
    if [[ -z "$REMOTE_EOS_VERSION" ]]; then echo "Error: Could not determine remote EOS version."; exit 1; fi
    echo "Detected Remote EOS version: $REMOTE_EOS_VERSION on host ${REMOTE_HOSTNAME}"

    TARGET_VERSION="4.26.1F"
    if version_ge "$REMOTE_EOS_VERSION" "$TARGET_VERSION"; then
        echo "Running on a modern EOS version. Using 'send support-bundle' remotely..."
        run_remote_eos_cmd send support-bundle "flash:" case-number "${CASE_NUMBER}"
        echo "Finding generated bundle on remote device..."
        BUNDLE_PATH=$(run_remote_bash_cmd "ls -t /mnt/flash/support-bundle-SR${CASE_NUMBER}-* 2>/dev/null | head -1")
        if [[ -z "$BUNDLE_PATH" ]]; then echo "Warning: Could not automatically find bundle."; exit 0; fi
        
        BUNDLE_FILENAME=$(basename "${BUNDLE_PATH}")
        echo "Downloading bundle from remote device..."
        scp_remote_file "${BUNDLE_PATH}" "${LOCAL_DATE_FOLDER}/"
        
        echo -e "\n---------- SUCCESS! ----------"
        echo -e "Remote Location: ${REMOTE_HOST}:${BUNDLE_PATH}"
        echo -e "Local Location:  ./${LOCAL_DATE_FOLDER}/${BUNDLE_FILENAME}"
        echo -e "--------------------------------\n"
        decompress_bundle "./${LOCAL_DATE_FOLDER}/${BUNDLE_FILENAME}"
    else
        echo "Running on an older EOS version. Manually collecting logs remotely..."
        DATE_STAMP=$(run_remote_bash_cmd "date +%m_%d.%H%M")
        DATETIME_STAMP=$(run_remote_bash_cmd "date '+%F--%H%M'")

        echo "Collecting logs..."
        run_remote_bash_cmd "cd / && sudo tar --exclude lastlog -czvf /mnt/flash/${CASE_NUMBER}-${REMOTE_HOSTNAME}-var-log-${DATE_STAMP}.tar.gz var/log/"
        run_remote_bash_cmd "cd /mnt/flash && sudo tar -cvf /mnt/flash/${CASE_NUMBER}-${REMOTE_HOSTNAME}-history-tech-${DATE_STAMP}.tar schedule/tech-support/"
        run_remote_bash_cmd "cd /mnt/flash && sudo tar -czvf /mnt/flash/${CASE_NUMBER}-${REMOTE_HOSTNAME}-debug-folder-${DATE_STAMP}.tar.gz debug/"
        run_remote_bash_cmd "cd /mnt/flash && sudo tar -czvf /mnt/flash/${CASE_NUMBER}-${REMOTE_HOSTNAME}-fossil-folder-${DATE_STAMP}.tar.gz Fossil/"
        run_remote_bash_cmd "cd /var/ && sudo tar --dereference -czvf /mnt/flash/${CASE_NUMBER}-${REMOTE_HOSTNAME}-var-core-${DATE_STAMP}.tar.gz core/"
        run_remote_bash_cmd "FastCli -p 15 -c 'show tech-support' | gzip > /mnt/flash/${CASE_NUMBER}-${REMOTE_HOSTNAME}-show-tech-${DATE_STAMP}.log.gz"
        
        echo "Bundling all collected files..."
        FINAL_BUNDLE_NAME="TAC-bundle-${CASE_NUMBER}-${REMOTE_HOSTNAME}-${DATETIME_STAMP}.tar"
        run_remote_bash_cmd "cd /mnt/flash && tar --remove-files -cf ${FINAL_BUNDLE_NAME} ${CASE_NUMBER}-*"
        
        BUNDLE_PATH="/mnt/flash/${FINAL_BUNDLE_NAME}"
        echo "Downloading bundle from remote device..."
        scp_remote_file "${BUNDLE_PATH}" "${LOCAL_DATE_FOLDER}/"

        echo -e "\n---------- SUCCESS! ----------"
        echo -e "Remote Location: ${REMOTE_HOST}:${BUNDLE_PATH}"
        echo -e "Local Location:  ./${LOCAL_DATE_FOLDER}/${FINAL_BUNDLE_NAME}"
        echo -e "--------------------------------\n"
        decompress_bundle "./${LOCAL_DATE_FOLDER}/${FINAL_BUNDLE_NAME}"
    fi

# ==============================================================================
# --- ON-BOX EXECUTION MODE ---
# ==============================================================================
else
    echo "Running in On-Box Mode."
    HOSTNAME=$(hostname)
    TARGET_VERSION="4.26.1F"
    EOS_VERSION=$(FastCli -p 15 -c "show version" | grep "Software image version" | awk '{print $4}')
    echo "Detected EOS version: $EOS_VERSION"

    if version_ge "$EOS_VERSION" "$TARGET_VERSION"; then
        echo "Running on a modern EOS version. Creating support bundle locally..."
        
        local output
        output=$(FastCli -p 15 -c "send support-bundle flash: case-number ${CASE_NUMBER}")
        echo "$output"

        local bundle_filename
        bundle_filename=$(echo "$output" | awk -F' ' '/Support bundle .* successfully sent/ {print $3}')
        
        if [[ -n "$bundle_filename" ]]; then
            local bundle_path="/mnt/flash/${bundle_filename}"
            transfer_onbox_bundle "$bundle_path"
        else
            echo "Warning: Could not determine the bundle filename automatically."
            echo "Please check flash: for the support bundle."
        fi
    else
        echo "Running on an older EOS version. Manually collecting logs..."
        DATE_STAMP=$(date +%m_%d.%H%M)
        DATETIME_STAMP=$(date "+%F--%H%M")
        FINAL_BUNDLE="/mnt/flash/TAC-bundle-${CASE_NUMBER}-${HOSTNAME}-${DATETIME_STAMP}.tar"
        
        echo "Collecting logs..."
        bash -c "cd / && sudo tar --exclude lastlog -czvf /mnt/flash/${CASE_NUMBER}-${HOSTNAME}-var-log-${DATE_STAMP}.tar.gz var/log/"
        bash -c "cd /mnt/flash && sudo tar -cvf /mnt/flash/${CASE_NUMBER}-${HOSTNAME}-history-tech-${DATE_STAMP}.tar schedule/tech-support/"
        bash -c "cd /mnt/flash && sudo tar -czvf /mnt/flash/${CASE_NUMBER}-${HOSTNAME}-debug-folder-${DATE_STAMP}.tar.gz debug/"
        bash -c "cd /mnt/flash && sudo tar -czvf /mnt/flash/${CASE_NUMBER}-${HOSTNAME}-fossil-folder-${DATE_STAMP}.tar.gz Fossil/"
        bash -c "cd /var/ && sudo tar --dereference -czvf /mnt/flash/${CASE_NUMBER}-${HOSTNAME}-var-core-${DATE_STAMP}.tar.gz core/"
        FastCli -p 15 -c "show tech-support" | gzip > "/mnt/flash/${CASE_NUMBER}-${HOSTNAME}-show-tech-${DATE_STAMP}.log.gz"
        
        echo "Bundling all collected files..."
        bash -c "cd /mnt/flash && tar --remove-files -cf ${FINAL_BUNDLE} ${CASE_NUMBER}-*"

        transfer_onbox_bundle "$FINAL_BUNDLE"
    fi
fi

echo "--- Script Finished ---"
