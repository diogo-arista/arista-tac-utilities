# Arista TAC Log Collection Script

This script is a comprehensive utility designed to simplify and automate the process of collecting support log bundles from Arista EOS devices. It intelligently adapts its behavior whether it's run directly on a switch or remotely from an engineer's workstation, ensuring a consistent and reliable process for gathering troubleshooting information for the Arista Technical Assistance Center (TAC).

## Features

-   **Dual Execution Modes**: The script automatically detects if it's running on an Arista switch (**On-Box Mode**) or a user's computer (**Remote Mode**).
-   **Smart Version Detection**: Automatically checks the EOS version to run the correct log collection commands (`send support-bundle` for modern versions, legacy `tar` commands for older ones).
-   **Dependency-Free Remote Control**: Securely runs commands on a remote switch using a built-in SSH feature (**Connection Sharing**), requiring no special software like `sshpass` and only asking for a password once.
-   **Automated Log Download**: When run in remote mode, the script automatically downloads the final log bundle to your local computer via SCP.
-   **Organized Local Storage**: Automatically creates a date-stamped folder (e.g., `2025-07-08`) on your local machine to store downloaded logs neatly.
-   **Optional On-Box File Transfer**: When run directly on a switch, it provides an option to transfer the generated bundle to a remote server using **SCP** or **FTP**.
-   **Optional Decompression**: After downloading a bundle, it offers to decompress the `.zip` or `.tar` file into a subfolder for immediate analysis.
-   **User-Friendly Defaults**: Provides sensible defaults for usernames (`admin`), FTP servers (`ftp.arista.com`), and placeholder case numbers (`0000`) to speed up the workflow.
-   **Command-Line Arguments**: Supports passing a case number directly as an argument and includes a `--help` menu for usage instructions.

---
## How to Use

There are three primary ways to use this script, depending on your workflow.

### Method 1: Running Remotely from Your Computer (Recommended)

This is the most powerful and common method. You can run the script from any **Linux**, **macOS**, or **Windows (WSL)** terminal to connect to an Arista device and collect its logs.

#### ▶️ Execute Directly from GitHub (Easiest Way)
This command downloads and runs the script in one step. It's the best way to ensure you're always using the latest version.

```bash
bash <(curl -sL [https://raw.githubusercontent.com/diogo-arista/arista-tac-utilities/main/eos-log-collection/tac_log_collector.sh](https://raw.githubusercontent.com/diogo-arista/arista-tac-utilities/main/eos-log-collection/tac_log_collector.sh))
