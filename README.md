# Xray Reality Auto-Installer

**Author:** Eminent Li
**Date:** 2026-04-03

## Purpose

This script automates the installation and configuration of [Xray-core](https://github.com/XTLS/Xray-core) with a VLESS-XTLS-uTLS-REALITY setup on Debian/Ubuntu systems. It also deploys a lightweight PHP-based web panel secured by Basic Authentication to monitor network traffic using `vnStat`, and generates client share links/QR codes for easy connection.

## Features

- **Automated Xray Installation**: Fetches and installs the latest Xray core using the official release script.
- **VLESS-Reality Configuration**: Automatically generates UUID, X25519 keypair, and configures a secure Reality inbound.
- **Traffic Monitoring Dashboard**: Deploys a PHP web dashboard backed by `vnStat` to track daily and monthly traffic.
- **Apache Integration**: Configures Apache with SSL (self-signed) on a custom port (8443) to avoid conflict with Xray, and sets up Basic Authentication for the dashboard.
- **Auto-generated Credentials & Links**: Creates shareable VLESS links and QR codes.
- **Log Management**: Automatically sets up log rotation for Xray logs to prevent disk space issues.

## Requirements

- **Operating System**: A clean installation of **Debian** (10, 11, 12+) or **Ubuntu** (20.04, 22.04, 24.04+). The script specifically requires `apt` package manager and `systemd`.
- **Privileges**: Root access (`sudo` or running as `root`).
- **Network**: A public IPv4 address and active internet connection.
- **Dependencies**: The script will automatically install required system packages (such as `apache2`, `php`, `ufw`, `vnstat`, `qrencode`, etc.) if they are missing.

## Usage

### Quick Install

You can install the complete stack directly using the following command (requires root privileges):

```bash
bash <(curl -Ls https://raw.githubusercontent.com/eminentli/reality-easy-install/main/install.sh)
```

### Manual Installation

Download the `install.sh` script to your server, make it executable, and run it with root privileges.

```bash
wget https://raw.githubusercontent.com/eminentli/reality-easy-install/main/install.sh -O install.sh
```

#### 1. Install the Stack

To install or re-apply the full stack, simply run the script. This is the default command.

```bash
chmod +x install.sh
sudo ./install.sh install
# Or just:
# sudo ./install.sh
```

Upon successful installation, the script will output the Panel URL, login credentials, server UUID, public key, and client connection links.

### 2. Update Xray Core

To update the installed Xray core to the latest release and restart the service while keeping your configuration intact:

```bash
sudo ./install.sh update
```

### 3. Uninstall

To completely remove the panel, certificates, local state, generated QR files, and the Xray configuration written by this script:

```bash
sudo ./install.sh uninstall
```
*(Note: System packages like Apache and vnStat, along with the vnStat database, are left intact for your convenience.)*
