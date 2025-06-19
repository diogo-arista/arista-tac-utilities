#!/bin/bash

# #############################################################################
# Arista TAC Log Collection Script (v5)
#
# This script collects a support bundle from an Arista EOS device.
# - For EOS 4.26.1F and later, it uses 'send support-bundle' and prompts for a
#   destination.
# - For older versions, it uses the legacy log collection commands.
#
# #############################################################################

# --- Functions ---

# Displays the help message for the script.
display_help() {
    echo "Arista TAC Log Collection Script"
    echo "Automates the collection of support bundles from Arista EOS devices."
    echo ""
    echo "USAGE:"
    echo "  bash $(basename "$0") [CASE_NUMBER] [OPTIONS]"
    echo ""
    echo "ARGUMENTS:"
    echo "  [CASE_NUMBER]    (Optional) The TAC case number. If not provided,"
    echo "                   the script will prompt for it interactively."
    echo ""
    echo "OPTIONS:"
    echo "  -h, --help       Display this help message and exit."
    echo ""
    echo "EXAMPLES:"
    echo "  # Run with a case number argument:"
    echo "  bash $(basename "$0") 123456"
    echo ""
    echo "  # Run in interactive mode (will ask for the case number):"
    echo "  bash $(basename "$0")"
    echo ""
    echo "  # Display help:"
    echo "  bash $(basename "$0") --help"
}

# Function to compare two EOS version strings.
version_ge() {
    test "$(printf '%s\n' "$1" "$2" | sort -V | head -n 1)" = "$2"
}

# --- Argument Parsing ---

# Check for help flag first.
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    display_help
    exit 0
fi

# --- Main Script ---

echo "--- Arista TAC Log Collection Script (v5) ---"

# Use the first command-line argument as the case number.
CASE_NUMBER="$1"

# If no case number was provided as an argument, prompt the user.
if [[ -z "$CASE_NUMBER" ]]; then
    read -p "Please enter the TAC case number: " CASE_NUMBER
fi

# Validate that we have a case number, either from argument or prompt.
if [[ -z "$CASE_NUMBER" ]]; then
    echo "Error: A TAC case number is required."
    display_help
    exit 1
fi

echo "Using Case Number: $CASE_NUMBER"
echo "Checking EOS version..."

# Get the EOS version using grep/awk for maximum compatibility.
EOS_VERSION=$(FastCli -p 15 -c "show version" | grep "Software image version" | awk '{print $4}')
HOSTNAME=$(hostname)
TARGET_VERSION="4.26.1F"

if [[ -z "$EOS_VERSION" ]]; then
    echo "Error: Could not determine EOS version. Exiting."
    exit 1
fi

echo "Detected EOS version: $EOS_VERSION"
echo "Device Hostname: $HOSTNAME"

if version_ge "$EOS_VERSION" "$TARGET_VERSION"; then
    # --- Modern EOS Version (>= 4.26.1F) ---
    echo "Running on a modern EOS version."

    # Prompt for destination
    echo "Please specify a destination for the support bundle."
    echo "Examples: flash:/, scp://user@host/path/"
    read -p "Enter destination URL [default: flash:/]: " DESTINATION_URL

    # If the user enters nothing, use the default.
    if [[ -z "$DESTINATION_URL" ]]; then
        DESTINATION_URL="flash:/"
        echo "Using default destination: ${DESTINATION_URL}"
    fi

    echo "Attempting to send support bundle to '${DESTINATION_URL}'..."
    FastCli -p 15 -c "send support-bundle ${DESTINATION_URL} case-number ${CASE_NUMBER}"

    echo -e "\n-----------\n"
    echo "Command executed. The support bundle is being generated and sent to '${DESTINATION_URL}'."
    echo "Please monitor the output of 'show send support-bundle status' for progress."
    echo -e "\nIf saved locally, a .zip file with the case number will be in 'flash:'."
    echo "Attach the file to your TAC case via the customer portal."
    echo "https://www.arista.com/support/customer-portal \n"

else
    # --- Older EOS Version (< 4.26.1F) ---
    echo "Running on an older EOS version. Manually collecting logs to flash..."
    DATE_STAMP=$(date +%m_%d.%H%M)
    DATETIME_STAMP=$(date "+%F--%H%M")

    echo "Step 1/7: Collecting /var/log/..."
    bash -c "cd / && sudo tar --exclude lastlog -czvf /mnt/flash/${CASE_NUMBER}-${HOSTNAME}-var-log-${DATE_STAMP}.tar.gz var/log/" &> /dev/null

    echo "Step 2/7: Collecting scheduled tech-support history..."
    bash -c "cd /mnt/flash && sudo tar -cvf /mnt/flash/${CASE_NUMBER}-${HOSTNAME}-history-tech-${DATE_STAMP}.tar schedule/tech-support/" &> /dev/null

    echo "Step 3/7: Collecting debug folder..."
    bash -c "cd /mnt/flash && sudo tar -czvf /mnt/flash/${CASE_NUMBER}-${HOSTNAME}-debug-folder-${DATE_STAMP}.tar.gz debug/" &> /dev/null

    echo "Step 4/7: Collecting Fossil folder..."
    bash -c "cd /mnt/flash && sudo tar -czvf /mnt/flash/${CASE_NUMBER}-${HOSTNAME}-fossil-folder-${DATE_STAMP}.tar.gz Fossil/" &> /dev/null

    echo "Step 5/7: Collecting core files..."
    bash -c "cd /var/ && sudo tar --dereference -czvf /mnt/flash/${CASE_NUMBER}-${HOSTNAME}-var-core-${DATE_STAMP}.tar.gz core/" &> /dev/null

    echo "Step 6/7: Generating show tech-support..."
    FastCli -p 15 -c "show tech-support" | gzip > "/mnt/flash/${CASE_NUMBER}-${HOSTNAME}-show-tech-${DATE_STAMP}.log.gz"

    echo "Step 7/7: Bundling all collected files..."
    FINAL_BUNDLE="/mnt/flash/TAC-bundle-${CASE_NUMBER}-${HOSTNAME}-${DATETIME_STAMP}.tar"
    bash -c "cd /mnt/flash && tar --remove-files -cf ${FINAL_BUNDLE} ${CASE_NUMBER}-* &> /dev/null"

    echo -e "\n-----------\n\nCompleted. Please download the following file from the switch: \n\n ${FINAL_BUNDLE} \n\n Attach to TAC case number ${CASE_NUMBER} via the customer portal.\n https://www.arista.com/support/customer-portal \n\n"

fi

echo "--- Script Finished ---"