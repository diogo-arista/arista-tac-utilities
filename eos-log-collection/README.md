# Arista TAC Log Collection Script

This repository contains a Bash script designed to simplify and automate the process of collecting support log bundles from Arista EOS devices for the Technical Assistance Center (TAC).

It intelligently detects the device's EOS version and runs the appropriate commands, saving time for both customers and TAC engineers and reducing the chance of incomplete or incorrect log collection.

## Features

-   **Automatic EOS Version Detection**: The script automatically checks the running version of EOS.
-   **Smart Command Selection**:
    -   On **EOS 4.26.1F or newer**, it uses the modern, all-in-one `send support-bundle` command.
    -   On **older EOS versions**, it executes the traditional, comprehensive set of legacy commands to manually create a log bundle.
-   **Interactive & Non-Interactive Modes**: Run the script with the case number as a command-line argument for quick execution, or run it without arguments for a guided, interactive experience.
-   **Flexible Destination**: For modern EOS versions, the script prompts for a destination, allowing you to save the bundle locally to `flash:` or send it directly to a remote server via `scp`.
-   **Built-in Help**: A simple `--help` or `-h` flag provides usage instructions and examples.

## How It Works

The script follows a clear logical flow:

1.  **Argument Parsing**: It first checks if the user has requested `--help` or provided a case number as a command-line argument.
2.  **Case Number Input**: If a case number was not provided as an argument, the script interactively prompts the user to enter one.
3.  **Version Check**: It executes `show version` on the device to determine the software version.
4.  **Conditional Execution**:
    -   **If the EOS version is 4.26.1F or newer**:
        -   The script prompts the user to enter a destination URL (e.g., `flash:/` or `scp://user@host/path`). It defaults to `flash:/` for simplicity.
        -   It then executes the `send support-bundle` command, passing the destination and case number to generate a `.zip` file.
    -   **If the EOS version is older than 4.26.1F**:
        -   The script executes a sequence of five `tar` commands to archive critical logs and directories (`/var/log`, `debug`, `Fossil`, `schedule/tech-support`, `core` files).
        -   It runs `show tech-support` and compresses the output.
        -   Finally, it bundles all the generated archives and logs into a single `.tar` file, cleaning up the intermediate files.
5.  **Completion Message**: The script concludes by displaying a confirmation message, pointing the user to the exact file that needs to be collected and uploaded to the Arista support portal.

## Prerequisites

-   An Arista EOS device.
-   Access to the Bash shell on the device.
-   User privileges sufficient to run `sudo` and `FastCli` commands.

## Installation

No complex installation is needed. Simply get the script onto your Arista switch's flash storage.

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

## Usage

You can run the script in several ways from the EOS command line.

#### Displaying the Help Menu
To see the available options and examples, use the `-h` or `--help` flag.

```bash
bash /mnt/flash/tac_log_collector.sh --help