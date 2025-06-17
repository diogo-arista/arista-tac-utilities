# Arista TAC Log Collection Script

This repository contains a Bash script designed to simplify and automate the process of collecting support log bundles from Arista EOS devices for the Technical Assistance Center (TAC).

It intelligently detects the device's EOS version and runs the appropriate commands, saving time for both customers and TAC engineers and reducing the chance of incomplete or incorrect log collection.

## Features

-   **Automatic EOS Version Detection**: The script automatically checks the running version of EOS.
-   **Smart Command Selection**:
    -   On **EOS 4.26.1F or newer**, it uses the modern, all-in-one `send support-bundle` command.
    -   On **older EOS versions**, it executes the traditional, comprehensive set of legacy commands to manually create a log bundle.
-   **Flexible Execution**: Run the script from a local file or directly from this GitHub repository.
-   **Interactive & Non-Interactive Modes**: Run the script with the case number as a command-line argument for quick execution, or run it without arguments for a guided, interactive experience.
-   **Flexible Destination**: For modern EOS versions, the script prompts for a destination, allowing you to save the bundle locally to `flash:` or send it directly to a remote server via `scp`.
-   **Built-in Help**: A simple `--help` or `-h` flag provides usage instructions and examples.

## Installation (for Local Execution)

This step is only required if you want to keep a local copy of the script on your switch.

1.  Copy the `tac_log_collector.sh` script content from this repository.
2.  On the Arista switch, save the content to a file in `/mnt/flash`. You can use `vi` or any other text editor.

    ```bash
    [admin@AristaSW ~]$ vi /mnt/flash/tac_log_collector.sh
    # Paste the script content here and save the file
    ```

3.  Make the script executable (recommended):

    ```bash
    [admin@AristaSW ~]$ bash chmod +x /mnt/flash/tac_log_collector.sh
    ```

## Executing Directly from GitHub (No Installation Needed)

This is the recommended method for ensuring you are always running the latest version of the script without needing to copy it to the device first.

### Prerequisites for Direct Execution

For this method to work, the EOS device must be able to connect to the internet.
1.  **DNS Configuration**: The switch must have a DNS server configured to resolve `raw.githubusercontent.com`.
2.  **Network Access**: The switch needs a route to the internet, and any firewalls must allow outbound HTTPS (TCP port 443) traffic.

### Execution Command

This command uses "Process Substitution" (`<(...)`) to execute the script while keeping your keyboard connected for interactive input. From the EOS bash shell, run:

```bash
bash <(curl -sL [https://raw.githubusercontent.com/diogo-arista/arista-tac-utilities/main/eos-log-collection/tac_log_collector.sh](https://raw.githubusercontent.com/diogo-arista/arista-tac-utilities/main/eos-log-collection/tac_log_collector.sh))