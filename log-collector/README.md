# Arista Log Collector Script

## Overview

This script automates the collection of logs from Arista EOS devices. It supports both:

- **Remote execution**: From a Linux/macOS system using SSH to connect to a target Arista device
- **Local on-device execution**: When the script is run directly on an EOS device (e.g., via Bash or FastCli)

The script intelligently determines the EOS version and uses the appropriate method for log collection (`send support-bundle` or legacy commands). It also supports transferring the resulting log bundle to your local machine or uploading it to Arista's FTP server.

---

## Features

- SSH master connection for faster and cleaner remote execution
- EOS version detection and context-aware log collection
- Generates and collects:
  - `support-bundle` ZIP file (for EOS ≥ 4.26.1F)
  - `show tech-support` output and compressed logs (for older EOS versions)
- File transfer options:
  - Download log bundle to local machine
  - Upload via `scp` or `ftp` (e.g., to Arista FTP)
- Supports both remote and on-device modes

---

## Requirements

### On your local (remote) machine:
- Bash (Linux/macOS)
- `ssh` and `scp` (OpenSSH)
- Internet access (for FTP uploads to Arista)

### On the target EOS device:
- EOS version ≥ 4.18 recommended
- For FTP upload: network reachability to `ftp.arista.com`

---

## Usage

### Remote execution (from your workstation)

```bash
./log_collector.sh
```

You will be prompted to:

1. Enter the Arista device IP or hostname  
2. Enter your username (default: `admin`)  
3. Enter the TAC case number (optional, defaults to `000000`)  
4. Authenticate via SSH  
5. Choose how to transfer the collected logs  

### On-device execution (locally on an EOS device)

```bash
bash log_collector.sh
```

The script will:

- Automatically detect it's running on an EOS device  
- Collect logs locally and store them on `/mnt/flash/`  
- Offer to upload them to a remote server or Arista FTP  

---

## Example Output

```
-----------------------------------------------------
  Arista Log Collector
-----------------------------------------------------
Enter target Arista device hostname or IP: 10.10.10.10
Enter username [admin]:
Enter TAC case number [000000]: 123456
-----------------------------------------------------
  Establishing Remote Connection
-----------------------------------------------------
You will be prompted for the password for 'admin@10.10.10.10'.
Connection successful. Proceeding...
...
Log bundle created on device: /mnt/flash/support-bundle-123456.zip
```

---

## File Transfer Options

After the logs are collected, you can choose:

1. **Download** the file from the device to your current directory  
2. **Upload** from the device to another system via `scp` or `ftp`  
3. **Do nothing** and handle the logs manually later  

If uploading to Arista FTP, you'll be asked to provide an email address for authentication.

---

## Notes

- EOS versions **≥ 4.26.1F** support the `send support-bundle` command  
- For older versions, the script falls back to traditional `show tech-support` collection and archiving of system logs  
- Temporary files may be stored in `/tmp` or `/mnt/flash/` depending on the execution context  

---

## Limitations

- The script does not support EOS devices behind jump hosts or proxy  
- Limited support for non-EOS (e.g., SONiC) platforms  
- Requires interactive access (not fully non-interactive)  

---

## Troubleshooting

- **SSH connection fails:** Ensure device is reachable and correct credentials are used  
- **Support bundle not created:** Older EOS versions may not support `send support-bundle`  
- **File transfer issues:** Verify SCP/FTP connectivity and credentials  

