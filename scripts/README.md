# Arista TAC Log Collection Script

This is a Bash script designed to **collect support bundles** from Arista EOS devices. It can be run:
- **Directly on the EOS switch** (on-box), or
- **Remotely from a laptop or server** (remote mode)

It supports **modern EOS versions** with the `send support-bundle` command as well as **older versions** where manual collection is required.

---

## 📦 Features

- Automatically detects if you're running on-box or remotely
- Works with EOS 4.26.1F and later using `send support-bundle`
- Supports manual log collection for older EOS versions
- Transfers bundle files using `scp` or `ftp`
- Offers optional local decompression of downloaded bundles
- Supports Linux, macOS, and Windows WSL

---

## 🖥 Requirements

To run this script from your laptop (remote mode), you'll need:
- `bash`
- `ssh` and `scp`
- `tar`, `gzip`, `unzip` (for decompressing)
- A user account on the Arista device with access to `FastCli`

To run on the **EOS device**, it must support Bash scripting and have access to `FastCli`.

---

## 🚀 Usage

### 🛠 Local Setup (macOS / Linux / WSL on Windows)

1. Clone this repository:

   ```bash
   git clone https://github.com/<your-org-or-user>/<repo-name>.git
   cd <repo-name>
