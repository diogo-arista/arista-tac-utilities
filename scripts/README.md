# Arista TAC Log Collection Script

This script collects a support bundle from an Arista EOS device.

It can be run:
- Directly on the EOS switch (on-box)
- Remotely from a laptop or server (remote mode)

Supports both modern EOS versions using `send support-bundle` and older EOS versions using manual log collection.

---

## 📦 Features

- Detects if it's running on-box or remotely
- Uses `send support-bundle` for EOS 4.26.1F+
- Manual log collection for older EOS versions
- Transfers bundles using scp or ftp
- Optional local decompression after download
- Compatible with macOS, Linux, and Windows WSL

---

## 🖥 Requirements

To run remotely:
- bash
- ssh, scp
- tar, gzip, unzip
- Network access to EOS device
- FastCli access on the EOS device

---

## 🚀 Usage

### 🛠 Local Setup (macOS / Linux / WSL)

1. Clone the repository:

```
git clone https://github.com/diogo-arista/arista-tac-utilities.git
cd arista-tac-utilities/scripts
```

2. Make the script executable (optional):

```
chmod +x tac_log_collector.sh
```

3. Run the script:

```
./tac_log_collector.sh
```

Or specify a TAC case number:

```
./tac_log_collector.sh 01234567
```

---

### 🔧 On-Box (running directly on the EOS switch)

Copy the script to the switch and run:

```
bash tac_log_collector.sh 01234567
```

---

## 🧪 Running Directly from GitHub (Remote Only)

You can run the script without cloning the repo:

```
bash <(curl -s https://raw.githubusercontent.com/diogo-arista/arista-tac-utilities/main/scripts/tac_log_collector.sh)
```

Or with a case number:

```
bash <(curl -s https://raw.githubusercontent.com/diogo-arista/arista-tac-utilities/main/scripts/tac_log_collector.sh) 01234567
```

> Tip: Always inspect scripts before running them with curl|bash.

---

## 📂 Output

- On-box: bundles are saved to `/mnt/flash/`
- Remote: files are saved in a dated folder like `./2025-07-08/`
- You'll be prompted to optionally decompress the bundle locally

---

## 📡 Transfer Options

- SCP (default and recommended)
- FTP (user-defined destination)
  - FTP directory must exist before transfer

---

## 🆘 Help

To view the help message:

```
./tac_log_collector.sh --help
```

---

## 👨‍💻 Author

Maintained by [Diogo Mendes](https://www.linkedin.com/in/diogomendes/) – Arista Networks TAC
