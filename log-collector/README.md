# Arista Log Collector

A single-script utility to collect and transfer support logs from Arista EOS devices. It works remotely (from your laptop or jump host over SSH) or locally on the device.

---

## Overview

This script automates the collection of logs from Arista EOS devices. It supports both:

- **Remote execution**: From a Linux/macOS system using SSH to connect to a target Arista device  
- **Local on-device execution**: When the script is run directly on an EOS device (e.g., via Bash or FastCli)  

The script intelligently determines the EOS version and uses the appropriate method for log collection (`send support-bundle` or legacy commands). It also supports transferring the resulting log bundle to your local machine or uploading it to Arista's FTP server.

---

## 🖥️ Running from GitHub (no clone required)

You can run the script directly without cloning the repository:

### Using `curl`:
```bash
bash <(curl -s https://raw.githubusercontent.com/diogo-arista/arista-tac-utilities/main/log-collector/log-collector.sh)
```

### Using `wget`:
```bash
bash <(wget -qO- https://raw.githubusercontent.com/diogo-arista/arista-tac-utilities/main/log-collector/log-collector.sh)
```

> ⚠️ Only use this method with trusted scripts. To inspect before running:
```bash
curl -O https://raw.githubusercontent.com/diogo-arista/arista-tac-utilities/main/log-collector/log-collector.sh
chmod +x log-collector.sh
./log-collector.sh
```

---

## Features

- **Remote or on-device execution**
  - Remote mode uses SSH ControlMaster for a persistent connection.
  - On-device mode is detected via `/etc/Eos-release` and uses `FastCli`.
- **Automatic collection per EOS version**
  - EOS ≥ 4.26.1F: `send support-bundle flash:/ case-number <CASE>`.
  - Older EOS: legacy TAC bundle (show tech plus misc logs) archived on `/mnt/flash`.
- **Smart bundle discovery**
  - Finds the latest `support-bundle-*<CASE>*.zip` or `TAC-bundle-<CASE>-*.tar` on `/mnt/flash`.
- **Flexible transfer options**
  - Download to your machine via SCP.
  - Device-side upload via SCP or FTP.
  - VRF-aware transfers using `run cli vrf <vrf>`.
  - Default FTP target: `ftp.arista.com/support/<CASE>/` with anonymous login (email as password).
- **Interactive menus or non-interactive flags** for automation.

---

## Requirements

### Remote (workstation or jump host)
- `bash`, `ssh`, `scp`
- `grep`, `awk`, `sort`, `tar`, `gzip`
- GNU `sort -V` for version comparison  
  On macOS, install coreutils or run the script from Linux.

### On the EOS device
- `FastCli` available on EOS
- Privileges to run `enable` commands and access `/mnt/flash`
- For legacy bundling the script may call `sudo` inside EOS bash for `tar` and `gzip`

---

## Install

```bash
chmod +x log-collector.sh
```

No further installation is needed.

---

## Usage

```
./log-collector.sh [-d <device>] [-u <user>] [-c <case>] [-t <proto>] [-r <host>] [-v <vrf>] [-h]
```

**Options**
- `-d <device>`  Target device hostname or IP (remote mode)
- `-u <user>`    Username for login (remote mode)
- `-c <case>`    TAC case number used in filenames and FTP path
- `-t <proto>`   Initial transfer protocol: `scp` or `ftp`
- `-r <host>`    Destination host for the initial transfer  
  Required when `-t scp`. Optional for `-t ftp` (defaults to `ftp.arista.com`).
- `-v <vrf>`     VRF to use for device-side copy (for example `management`)
- `-h`           Show help and exit

**Behavior notes**
- If `-t scp` is used, `-r` is required.
- If `-t ftp` is used without `-r`, the script defaults to `ftp.arista.com/support/<CASE>/`.
- Without flags the script runs fully interactive.

---

## Quick starts

### Remote interactive
```bash
./log-collector.sh
# Prompts for device, username (default admin), and case number
# Collects logs and then shows a transfer menu
```

### Remote with immediate FTP to Arista
```bash
./log-collector.sh -d sw1.example.net -u admin -c 123456 -t ftp
# Defaults to ftp.arista.com/support/123456/
# You will be prompted for your email which is used as the FTP password for anonymous login
```

### Remote with immediate SCP upload via a VRF
```bash
./log-collector.sh -d 10.10.10.10 -u admin -c 123456 -t scp -r files.example.net -v management
# You will be prompted for destination user and destination path
```

### On the EOS device
```bash
bash ./log-collector.sh -c 123456
# Detects on-device mode, collects logs, then offers SCP/FTP upload menu
```

---

## What it does

1. **Determines execution mode**
   - Presence of `/etc/Eos-release` means on-device.
   - Otherwise remote and uses SSH ControlMaster.
2. **Detects EOS version** with `show version`.
3. **Collects logs**
   - New method (≥ 4.26.1F): `send support-bundle flash:/ case-number <CASE>`.
   - Legacy method: `show tech-support` to gzip plus tar of `/var/log/`, `/mnt/flash/debug/`, `/mnt/flash/Fossil/` if present, then packs a single bundle.
4. **Finds the most recent bundle** on `/mnt/flash`.
5. **Transfers the file**
   - Remote menu: download to your machine, or instruct the device to upload via SCP or FTP.
   - On-device menu: upload via SCP or FTP.
   - If `-t ftp|scp` was specified, the initial transfer runs automatically before showing the menu.

---

## File locations and names

- Support bundle (new):  
  `/mnt/flash/support-bundle-*<CASE>*.zip`
- Legacy bundle (older EOS):  
  `/mnt/flash/TAC-bundle-<CASE>-<HOST>-<YYYY-MM-DD--HHMM>.tar`

The case number is included in filenames and in the default FTP destination path.

---

## Security notes

- `StrictHostKeyChecking=no` is set for convenience. Adjust if you require stricter SSH host key verification.
- For Arista FTP the script uses anonymous login and your email address as the password. Avoid sensitive credentials over plain FTP. Prefer SCP for end-to-end encryption.
- Device-side copy commands run under EOS `enable`. Your role must have sufficient privileges.

---

## Troubleshooting

- **SSH master connection failed**  
  Check reachability, username, credentials, and that SSH is allowed from your host.

- **Prompts or menus not visible**  
  Do not redirect or suppress stderr. The script prints menu and status messages to stderr so you can still see device output on stdout.

- **Could not find the generated support bundle**  
  Check free space on `/mnt/flash` and that the device supports `send support-bundle` on EOS ≥ 4.26.1F. Otherwise the script falls back to legacy.

- **Version comparison on macOS**  
  Ensure GNU `sort -V` is available. Install coreutils or run from Linux.

- **SCP or FTP issues with VRFs**  
  Use `-v management` or the appropriate VRF so the device copies out via the correct egress interface.

