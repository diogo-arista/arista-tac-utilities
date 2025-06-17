#!/bin/bash

# #############################################################################
# Arista TAC Log Collection Script (v6)
#
# This script collects a support bundle from an Arista EOS device.
# It can be run directly on the EOS device or remotely from a client machine
# (Linux, macOS, Windows WSL).
#
# Changelog:
# v6: Added remote execution capability using SSH Connection Sharing. No new
#     dependencies are required. Script now detects if it's on EOS or a client.
# v5: Added -h/--help option and ability to pass case number as an argument.
#
# #############################################################################

# --- Functions ---

# Displays the help message for the script.
display_help() {
    echo "Arista TAC Log Collection Script"
    echo "Automates log collection. Can be run on-box or remotely."
    echo ""
    echo "USAGE:"
    echo "  bash $(basename "$0") [CASE_NUMBER] [OPTIONS]"
    echo ""
    echo "ARGUMENTS:"
    echo "  [CASE_NUMBER]    (Optional) The TAC case number. If not provided,"
    echo "                   the script will prompt for it."
    echo ""
    echo "OPTIONS:"
    echo "  -h, --help       Display this help message and exit."
}

# Compares two EOS version strings.
version_ge() {
    test "$(printf '%s\n' "$1" "$2" | sort -V | head -n 1)" = "$2"
}

# --- Argument Parsing ---

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    display_help
    exit 0
fi

# --- Main Script ---

echo "--- Arista TAC Log Collection Script (v6) ---"

# Determine run mode: "on-box" or "remote"
RUN_MODE="remote"
if [ -f /usr/bin/FastCli ]; then
    RUN_MODE="on-box"
fi

# Get Case Number
CASE_NUMBER="$1"
if [[ -z "$CASE_NUMBER" ]]; then
    read -p "Please enter the TAC case number: " CASE_NUMBER
fi
if [[ -z "$CASE_NUMBER" ]]; then
    echo "Error: A TAC case number is required."
    display_help
    exit 1
fi
echo "Using Case Number: $CASE_NUMBER"

# ==============================================================================
# --- REMOTE EXECUTION MODE ---
# ==============================================================================
if [[ "$RUN_MODE" == "remote" ]]; then
    echo "Running in Remote Mode."
    
    # Get connection details
    read -p "Enter target EOS device address: " REMOTE_HOST
    read -p "Enter username for ${REMOTE_HOST}: " REMOTE_USER

    if [[ -z "$REMOTE_HOST" || -z "$REMOTE_USER" ]]; then
        echo "Error: Hostname and username are required for remote execution."
        exit 1
    fi

    # Setup SSH Connection Sharing
    CONTROL_PATH="/tmp/ssh-mux-%r@%h:%p"
    echo "Establishing master SSH connection to ${REMOTE_HOST}..."
    echo "You will be prompted for the password once."

    # Establish the master connection in the background, prompting for a password once.
    # It will persist for 120 seconds of inactivity.
    ssh -o ControlMaster=auto -o ControlPath="$CONTROL_PATH" -o ControlPersist=120s -Nf "${REMOTE_USER}@${REMOTE_HOST}"
    SSH_STATUS=$?

    if [ $SSH_STATUS -ne 0 ]; then
        echo "Error: SSH connection failed. Please check host, credentials, or network connectivity."
        exit $SSH_STATUS
    fi

    # Ensure we clean up the connection when the script exits
    function cleanup {
        echo "Closing master SSH connection..."
        ssh -o ControlPath="$CONTROL_PATH" -O exit "${REMOTE_USER}@${REMOTE_HOST}" 2>/dev/null
    }
    trap cleanup EXIT

    # Helper functions for remote operations
    run_remote_cmd() {
        ssh -o ControlPath="$CONTROL_PATH" "${REMOTE_USER}@${REMOTE_HOST}" "$@"
    }
    scp_remote_file() {
        scp -o ControlPath="$CONTROL_PATH" "${REMOTE_USER}@${REMOTE_HOST}:$1" "$2"
    }

    # --- Start remote log collection ---
    echo "Checking remote EOS version..."
    REMOTE_HOSTNAME=$(run_remote_cmd "hostname")
    # Note the escaped dollar sign in awk for remote execution
    REMOTE_EOS_VERSION=$(run_remote_cmd 'FastCli -p 15 -c "show version" | grep "Software image version" | awk "{print \$4}"')
    
    if [[ -z "$REMOTE_EOS_VERSION" ]]; then
        echo "Error: Could not determine remote EOS version. Exiting."
        exit 1
    fi
    echo "Detected Remote EOS version: $REMOTE_EOS_VERSION on host ${REMOTE_HOSTNAME}"

    TARGET_VERSION="4.26.1F"
    if version_ge "$REMOTE_EOS_VERSION" "$TARGET_VERSION"; then
        echo "Running on a modern EOS version. Using 'send support-bundle' remotely..."
        
        echo "Please specify a destination ON THE REMOTE SWITCH for the support bundle."
        read -p "Enter destination URL [default: flash:/]: " DESTINATION_URL
        if [[ -z "$DESTINATION_URL" ]]; then
            DESTINATION_URL="flash:/"
        fi

        run_remote_cmd "FastCli -p 15 -c 'send support-bundle ${DESTINATION_URL} case-number ${CASE_NUMBER}'"
        
        echo "Finding generated bundle on remote device..."
        # This is a best-effort guess at the filename.
        BUNDLE_PATH=$(run_remote_cmd "ls -t /mnt/flash/support-bundle-SR${CASE_NUMBER}-* 2>/dev/null | head -1")

        if [[ -z "$BUNDLE_PATH" ]]; then
             echo "Warning: Could not automatically find the bundle. Please check 'flash:' on the remote device."
             exit 0
        fi

        echo "Downloading ${BUNDLE_PATH} to your local machine..."
        scp_remote_file "${BUNDLE_PATH}" "."
        echo -e "\n-----------\n\nCompleted. Bundle downloaded to your current directory: $(basename ${BUNDLE_PATH})\n"

    else
        echo "Running on an older EOS version. Manually collecting logs remotely..."
        DATE_STAMP=$(run_remote_cmd "date +%m_%d.%H%M")
        DATETIME_STAMP=$(run_remote_cmd "date \"+%F--%H%M\"")

        # Execute all commands remotely
        echo "Step 1/7: Collecting /var/log/..."
        run_remote_cmd "cd / && sudo tar --exclude lastlog -czvf /mnt/flash/${CASE_NUMBER}-${REMOTE_HOSTNAME}-var-log-${DATE_STAMP}.tar.gz var/log/"
        echo "Step 2/7: Collecting scheduled tech-support history..."
        run_remote_cmd "cd /mnt/flash && sudo tar -cvf /mnt/flash/${CASE_NUMBER}-${REMOTE_HOSTNAME}-history-tech-${DATE_STAMP}.tar schedule/tech-support/"
        echo "Step 3/7: Collecting debug folder..."
        run_remote_cmd "cd /mnt/flash && sudo tar -czvf /mnt/flash/${CASE_NUMBER}-${REMOTE_HOSTNAME}-debug-folder-${DATE_STAMP}.tar.gz debug/"
        echo "Step 4/7: Collecting Fossil folder..."
        run_remote_cmd "cd /mnt/flash && sudo tar -czvf /mnt/flash/${CASE_NUMBER}-${REMOTE_HOSTNAME}-fossil-folder-${DATE_STAMP}.tar.gz Fossil/"
        echo "Step 5/7: Collecting core files..."
        run_remote_cmd "cd /var/ && sudo tar --dereference -czvf /mnt/flash/${CASE_NUMBER}-${REMOTE_HOSTNAME}-var-core-${DATE_STAMP}.tar.gz core/"
        echo "Step 6/7: Generating show tech-support..."
        run_remote_cmd "FastCli -p 15 -c 'show tech-support' | gzip > /mnt/flash/${CASE_NUMBER}-${REMOTE_HOSTNAME}-show-tech-${DATE_STAMP}.log.gz"
        echo "Step 7/7: Bundling all collected files..."
        FINAL_BUNDLE_NAME="TAC-bundle-${CASE_NUMBER}-${REMOTE_HOSTNAME}-${DATETIME_STAMP}.tar"
        run_remote_cmd "cd /mnt/flash && tar --remove-files -cf ${FINAL_BUNDLE_NAME} ${CASE_NUMBER}-*"
        
        BUNDLE_PATH="/mnt/flash/${FINAL_BUNDLE_NAME}"
        echo "Downloading ${BUNDLE_PATH} to your local machine..."
        scp_remote_file "${BUNDLE_PATH}" "."
        echo -e "\n-----------\n\nCompleted. Bundle downloaded to your current directory: ${FINAL_BUNDLE_NAME}\n"
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
        echo "Running on a modern EOS version. Using 'send support-bundle'..."
        read -p "Enter destination URL [default: flash:/]: " DESTINATION_URL
        if [[ -z "$DESTINATION_URL" ]]; then
            DESTINATION_URL="flash:/"
        fi
        FastCli -p 15 -c "send support-bundle ${DESTINATION_URL} case-number ${CASE_NUMBER}"
        echo -e "\n-----------\n\nCompleted. Bundle created on device at ${DESTINATION_URL}\n"
    else
        echo "Running on an older EOS version. Manually collecting logs..."
        DATE_STAMP=$(date +%m_%d.%H%M)
        DATETIME_STAMP=$(date "+%F--%H%M")
        FINAL_BUNDLE="/mnt/flash/TAC-bundle-${CASE_NUMBER}-${HOSTNAME}-${DATETIME_STAMP}.tar"
        
        echo "Step 1/7: Collecting /var/log/..."
        bash -c "cd / && sudo tar --exclude lastlog -czvf /mnt/flash/${CASE_NUMBER}-${HOSTNAME}-var-log-${DATE_STAMP}.tar.gz var/log/" &> /dev/null
        echo "Step 2/7: ..." # Other steps follow
        bash -c "cd /mnt/flash && sudo tar -cvf /mnt/flash/${CASE_NUMBER}-${HOSTNAME}-history-tech-${DATE_STAMP}.tar schedule/tech-support/" &> /dev/null
        bash -c "cd /mnt/flash && sudo tar -czvf /mnt/flash/${CASE_NUMBER}-${HOSTNAME}-debug-folder-${DATE_STAMP}.tar.gz debug/" &> /dev/null
        bash -c "cd /mnt/flash && sudo tar -czvf /mnt/flash/${CASE_NUMBER}-${HOSTNAME}-fossil-folder-${DATE_STAMP}.tar.gz Fossil/" &> /dev/null
        bash -c "cd /var/ && sudo tar --dereference -czvf /mnt/flash/${CASE_NUMBER}-${HOSTNAME}-var-core-${DATE_STAMP}.tar.gz core/" &> /dev/null
        FastCli -p 15 -c "show tech-support" | gzip > "/mnt/flash/${CASE_NUMBER}-${HOSTNAME}-show-tech-${DATE_STAMP}.log.gz"
        echo "Step 7/7: Bundling all collected files..."
        bash -c "cd /mnt/flash && tar --remove-files -cf ${FINAL_BUNDLE} ${CASE_NUMBER}-*" &> /dev/null

        echo -e "\n-----------\n\nCompleted. Please find your bundle on the switch at: \n\n ${FINAL_BUNDLE} \n"
    fi
fi

echo "--- Script Finished ---"