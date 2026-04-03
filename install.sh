#!/bin/bash

# ==============================================================================
# Purpose: Installs and configures Xray core with a PHP-based web panel, 
#          vnStat traffic monitoring, and auto-generated Reality configuration.
# Date:    2026-04-03
# Author:  Eminent Li
# ==============================================================================

# Exit immediately if a command exits with a non-zero status,
# treat unset variables as an error, and fail pipelines if any command fails.
set -euo pipefail

# ==========================================
# Variables Configuration
# ==========================================
# Define core directories and files for Xray and Panel states
STATE_DIR="/usr/local/etc/xray"
STATE_FILE="${STATE_DIR}/reality.env"
XRAY_CONFIG="${STATE_DIR}/config.json"
PANEL_DIR="/var/www/html"
SHARE_DIR="/root/xray-share"
HTPASSWD_FILE="/etc/apache2/.htpasswd-xray-panel"
APACHE_CONF="/etc/apache2/conf-available/xray-panel.conf"
SSL_SITE_CONF="/etc/apache2/sites-available/xray-panel-ssl.conf"
SSL_CERT_DIR="/etc/apache2/ssl"
SSL_CERT_FILE="${SSL_CERT_DIR}/panel.crt"
SSL_KEY_FILE="${SSL_CERT_DIR}/panel.key"

# Define panel settings
PANEL_SSL_PORT="8443"
PANEL_CACHE_DIR="/var/cache/xray-panel"

# Define Xray installation script URL
XRAY_INSTALL_URL="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"

# ==========================================
# Utility Functions
# ==========================================

# Helper function to print log messages
log() {
  printf '[*] %s\n' "$*"
}

# Helper function to print error messages and exit
die() {
  printf '[!] %s\n' "$*" >&2
  exit 1
}

# Ensure the script is run with root privileges
require_root() {
  if [ "${EUID}" -ne 0 ]; then
    die "Please run this script as root."
  fi
}

# Check if the system uses apt package manager (Debian/Ubuntu)
require_apt() {
  command -v apt >/dev/null 2>&1 || die "This script currently supports apt-based Debian/Ubuntu systems only."
}

# Generate a random hex string of a given byte length
random_hex() {
  local bytes="$1"
  od -An -N"${bytes}" -tx1 /dev/urandom | tr -d ' \n'
}

# Create a directory if it doesn't exist
ensure_dir() {
  mkdir -p "$1"
}

# Wrapper for curl with common options for reliability
curl_fetch() {
  curl -4fsS --retry 3 --retry-delay 2 --retry-connrefused --max-time 15 "$@"
}

# Retrieve the public IP address of the server
get_public_ip() {
  local ip
  local providers=(
    "https://ipinfo.io/ip"
    "https://ifconfig.me"
    "https://icanhazip.com"
  )

  for provider in "${providers[@]}"; do
    ip=$(curl_fetch "${provider}" 2>/dev/null | tr -d '[:space:]') || true
    if [ -n "${ip}" ]; then
      printf '%s\n' "${ip}"
      return 0
    fi
  done

  return 1
}

# Extract a specific value from Xray key generation output
extract_xray_value() {
  local content="$1"
  local label="$2"
  printf '%s\n' "${content}" | sed -n "s/.*${label}[^:]*:[[:space:]]*//p" | head -n 1 | tr -d '\r'
}

# Detect the installed PHP module for Apache
detect_php_module() {
  local version
  version=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
  if [ -n "${version}" ] && [ -f "/etc/apache2/mods-available/php${version}.load" ]; then
    printf 'php%s\n' "${version}"
    return 0
  fi

  local module
  module=$(find /etc/apache2/mods-available -maxdepth 1 -name 'php*.load' -printf '%f\n' 2>/dev/null | sed 's/\.load$//' | sort -V | tail -n 1)
  if [ -n "${module}" ]; then
    printf '%s\n' "${module}"
    return 0
  fi

  return 1
}

# Find the Xray binary executable path
detect_xray_bin() {
  local candidate
  for candidate in "$(command -v xray 2>/dev/null || true)" /usr/local/bin/xray /usr/bin/xray; do
    if [ -n "${candidate}" ] && [ -x "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

# Ensure a specific UFW firewall rule is applied
ensure_ufw_rule() {
  local rule="$1"
  if ! ufw status | grep -Fq "${rule}"; then
    ufw allow "${rule}"
  fi
}

# ==========================================
# Installation & Configuration Functions
# ==========================================

# Install necessary system packages and dependencies
install_dependencies() {
  log "Installing dependencies"
  export DEBIAN_FRONTEND=noninteractive
  apt update -y
  apt install -y \
    apache2 \
    apache2-utils \
    ca-certificates \
    curl \
    libapache2-mod-php \
    openssl \
    php-cli \
    php-gd \
    qrencode \
    ufw \
    unzip \
    vnstat
}

# Configure Apache web server, PHP, and generate SSL certificates
configure_apache() {
  log "Configuring Apache and PHP"

  local php_module
  php_module=$(detect_php_module) || die "Unable to detect an Apache PHP module."

  # Enable Apache and necessary modules
  systemctl enable --now apache2 >/dev/null
  a2enmod "${php_module}" >/dev/null
  a2enmod auth_basic authn_file >/dev/null
  a2enmod ssl headers >/dev/null

  ensure_dir "${SSL_CERT_DIR}"
  ensure_dir "${PANEL_CACHE_DIR}"

  # Generate a self-signed SSL certificate if it does not exist
  if [ ! -s "${SSL_CERT_FILE}" ] || [ ! -s "${SSL_KEY_FILE}" ]; then
    openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout "${SSL_KEY_FILE}" \
      -out "${SSL_CERT_FILE}" \
      -days 3650 \
      -subj "/CN=${IP}" >/dev/null 2>&1
  fi

  # Ensure Apache listens on the custom SSL port
  if ! grep -E -q "^\s*Listen\s+${PANEL_SSL_PORT}\b" /etc/apache2/ports.conf; then
    echo "Listen ${PANEL_SSL_PORT}" >> /etc/apache2/ports.conf
  fi

  # Create Apache configuration for the Xray panel authentication
  cat > "${APACHE_CONF}" <<EOF
<FilesMatch "^panel_[a-f0-9]+\\.php$">
    AuthType Basic
    AuthName "Restricted Panel"
    AuthUserFile ${HTPASSWD_FILE}
    Require valid-user
</FilesMatch>
EOF

  # Create Apache virtual host configuration for the SSL panel
  cat > "${SSL_SITE_CONF}" <<EOF
<IfModule mod_ssl.c>
<VirtualHost *:${PANEL_SSL_PORT}>
    ServerName ${IP}
    DocumentRoot ${PANEL_DIR}

    SSLEngine on
    SSLCertificateFile ${SSL_CERT_FILE}
    SSLCertificateKeyFile ${SSL_KEY_FILE}

    <Directory ${PANEL_DIR}>
        Options FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    Header always set Strict-Transport-Security "max-age=31536000"
    ErrorLog \${APACHE_LOG_DIR}/xray-panel-ssl-error.log
    CustomLog \${APACHE_LOG_DIR}/xray-panel-ssl-access.log combined
</VirtualHost>
</IfModule>
EOF

  # Enable new Apache configurations and reload service
  a2enconf xray-panel >/dev/null
  a2ensite xray-panel-ssl >/dev/null
  apache2ctl configtest >/dev/null
  systemctl reload apache2
}

# Configure firewall rules using UFW
configure_firewall() {
  log "Configuring firewall"
  ensure_ufw_rule "22/tcp"
  ensure_ufw_rule "80/tcp"
  ensure_ufw_rule "443/tcp"
  ensure_ufw_rule "${PANEL_SSL_PORT}/tcp"
  ufw --force enable >/dev/null
  ufw reload >/dev/null
}

# Download and install Xray core using the official script
install_xray() {
  log "Installing Xray"
  local installer
  installer=$(mktemp)
  curl_fetch "${XRAY_INSTALL_URL}" -o "${installer}"
  bash "${installer}" install
  rm -f "${installer}"
}

# Update Xray core to the latest release
update_xray() {
  log "Updating Xray"
  local installer
  installer=$(mktemp)
  curl_fetch "${XRAY_INSTALL_URL}" -o "${installer}"
  bash "${installer}" install
  rm -f "${installer}"

  XRAY_BIN=$(detect_xray_bin) || die "Unable to locate the xray binary after update."
  if [ -f "${XRAY_CONFIG}" ]; then
    # Validate the config and restart Xray
    "${XRAY_BIN}" -test -config "${XRAY_CONFIG}" >/dev/null
    systemctl restart xray
  fi

  printf 'Xray update completed.\n'
}

# Completely uninstall the stack, removing configurations and directories
uninstall_stack() {
  log "Removing panel and local configuration"

  systemctl stop apache2 >/dev/null 2>&1 || true

  # Disable Apache sites and configurations
  a2dissite xray-panel-ssl >/dev/null 2>&1 || true
  a2disconf xray-panel >/dev/null 2>&1 || true

  # Remove configuration files, certificates, and state directories
  rm -f "${SSL_SITE_CONF}" "${APACHE_CONF}" "${HTPASSWD_FILE}"
  rm -f "${SSL_CERT_FILE}" "${SSL_KEY_FILE}"
  rm -f /etc/logrotate.d/xray
  rm -f "${STATE_FILE}" "${XRAY_CONFIG}"
  rm -rf "${SHARE_DIR}" "${PANEL_CACHE_DIR}"

  # Clean up panel files in the web root
  if [ -d "${PANEL_DIR}" ]; then
    find "${PANEL_DIR}" -maxdepth 1 \( -name 'panel_*.php' -o -name 'index.html' \) -exec rm -f {} \;
  fi

  # Remove custom Listen port from Apache ports.conf
  if [ -f /etc/apache2/ports.conf ] && [ -n "${PANEL_SSL_PORT:-}" ]; then
    sed -i "/^\s*Listen\s\+${PANEL_SSL_PORT}\b/d" /etc/apache2/ports.conf
  fi

  # Remove custom UFW rule
  if command -v ufw >/dev/null 2>&1; then
    ufw --force delete allow "${PANEL_SSL_PORT}/tcp" >/dev/null 2>&1 || true
  fi

  # Restart Apache to apply changes
  apache2ctl configtest >/dev/null 2>&1 || true
  systemctl start apache2 >/dev/null 2>&1 || true
  systemctl reload apache2 >/dev/null 2>&1 || true

  printf 'Uninstall completed. Packages and vnStat database were left intact.\n'
}

# Load existing configuration state or create a new one
load_or_create_state() {
  ensure_dir "${STATE_DIR}"

  # Source the existing state file if present
  if [ -f "${STATE_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
  fi

  # Determine necessary parameters, generating new ones if missing
  IP="${IP:-$(get_public_ip || true)}"
  [ -n "${IP:-}" ] || die "Unable to determine the public IP address."

  UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"
  PANEL_FILE="${PANEL_FILE:-panel_$(random_hex 4).php}"
  PANEL_USER="${PANEL_USER:-paneladmin}"
  PANEL_PASSWORD="${PANEL_PASSWORD:-$(random_hex 9)}"

  XRAY_BIN=$(detect_xray_bin) || die "Unable to locate the xray binary after installation."

  # Generate Xray X25519 keypair for Reality if not set
  if [ -z "${PRIVATE_KEY:-}" ] || [ -z "${PUBLIC_KEY:-}" ]; then
    local keypair
    keypair=$("${XRAY_BIN}" x25519)
    PRIVATE_KEY=$(extract_xray_value "${keypair}" "Private")
    PUBLIC_KEY=$(extract_xray_value "${keypair}" "Public")
  fi

  [ -n "${PRIVATE_KEY:-}" ] || die "Failed to generate or parse Reality private key."
  [ -n "${PUBLIC_KEY:-}" ] || die "Failed to generate or parse Reality public key."

  SHORTID_1="${SHORTID_1:-$(random_hex 8)}"
  SHORTID_2="${SHORTID_2:-$(random_hex 8)}"
  SHORTID_3="${SHORTID_3:-$(random_hex 8)}"

  # Save the current state to the environment file
  cat > "${STATE_FILE}" <<EOF
IP=${IP}
UUID=${UUID}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORTID_1=${SHORTID_1}
SHORTID_2=${SHORTID_2}
SHORTID_3=${SHORTID_3}
PANEL_FILE=${PANEL_FILE}
PANEL_USER=${PANEL_USER}
PANEL_PASSWORD=${PANEL_PASSWORD}
PANEL_SSL_PORT=${PANEL_SSL_PORT}
EOF
  chmod 600 "${STATE_FILE}"
}

# Write the core configuration for Xray
write_xray_config() {
  log "Writing Xray config"

  cat > "${XRAY_CONFIG}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "www.cloudflare.com:443",
          "serverNames": [
            "www.cloudflare.com"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORTID_1}",
            "${SHORTID_2}",
            "${SHORTID_3}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

  # Test the configuration and start the Xray service
  "${XRAY_BIN}" -test -config "${XRAY_CONFIG}" >/dev/null
  systemctl enable --now xray
  systemctl restart xray
}

# Enable and start the vnStat network traffic monitor
configure_vnstat() {
  log "Starting vnStat"
  systemctl enable --now vnstat
}

# Configure Basic Authentication for the Apache web panel
configure_panel_auth() {
  log "Configuring panel authentication"
  htpasswd -bc "${HTPASSWD_FILE}" "${PANEL_USER}" "${PANEL_PASSWORD}" >/dev/null
  chown root:www-data "${HTPASSWD_FILE}"
  chmod 640 "${HTPASSWD_FILE}"
}

# Create the PHP monitoring dashboard and holding page
write_panel_files() {
  log "Writing panel files"

  ensure_dir "${PANEL_DIR}"
  ensure_dir "${PANEL_CACHE_DIR}"
  local panel_path="${PANEL_DIR}/${PANEL_FILE}"

  # Create the main dashboard PHP script
  cat > "${panel_path}" <<'PHP'
<?php
error_reporting(0);
ini_set('display_errors', '0');

$cacheDir = '/var/cache/xray-panel';
$cacheFile = $cacheDir . '/vnstat.json';
$cacheTtl = 15; // Cache vnStat output for 15 seconds

if (!is_dir($cacheDir)) {
    @mkdir($cacheDir, 0750, true);
}

$json = '';
if (is_file($cacheFile) && (time() - filemtime($cacheFile)) < $cacheTtl) {
    $json = (string)@file_get_contents($cacheFile);
}

// Fetch vnStat data if cache is missing or expired
if ($json === '') {
    $json = (string)shell_exec('vnstat --json 2>/dev/null');
    if ($json !== '') {
        @file_put_contents($cacheFile, $json, LOCK_EX);
    }
}

$data = json_decode($json, true);

// Select the primary network interface, ignoring local and docker interfaces
$ifaceData = null;
if (is_array($data) && isset($data['interfaces']) && is_array($data['interfaces'])) {
    foreach ($data['interfaces'] as $iface) {
        if (!isset($iface['name'])) {
            continue;
        }

        if ($iface['name'] === 'lo' || strpos($iface['name'], 'docker') === 0) {
            continue;
        }

        $ifaceData = $iface;
        break;
    }
}

// Initialize default variables
$todayRx = 0;
$todayTx = 0;
$dailyLabels = [];
$dailyValues = [];
$monthLabels = [];
$monthValues = [];
$ifaceName = 'N/A';
$statusMessage = 'vnStat data is not available yet. Wait a few minutes after first install.';

// Parse network traffic data
if ($ifaceData !== null) {
    $ifaceName = $ifaceData['name'] ?? 'N/A';
    $statusMessage = 'Traffic data loaded.';

    // Extract daily stats (last 14 days)
    if (isset($ifaceData['traffic']['day']) && is_array($ifaceData['traffic']['day'])) {
        $days = array_slice($ifaceData['traffic']['day'], -14);
        foreach ($days as $day) {
            if (!isset($day['date']['day'], $day['date']['month'])) {
                continue;
            }

            $rx = (float)($day['rx'] ?? 0);
            $tx = (float)($day['tx'] ?? 0);
            $dailyLabels[] = $day['date']['day'] . '/' . $day['date']['month'];
            $dailyValues[] = round(($rx + $tx) / 1024 / 1024, 2); // Convert KiB to MB
        }

        $latestDay = end($ifaceData['traffic']['day']);
        if (is_array($latestDay)) {
            $todayRx = round(((float)($latestDay['rx'] ?? 0)) / 1024 / 1024, 2);
            $todayTx = round(((float)($latestDay['tx'] ?? 0)) / 1024 / 1024, 2);
        }
    }

    // Extract monthly stats (last 6 months)
    if (isset($ifaceData['traffic']['month']) && is_array($ifaceData['traffic']['month'])) {
        $months = array_slice($ifaceData['traffic']['month'], -6);
        foreach ($months as $month) {
            if (!isset($month['date']['month'])) {
                continue;
            }

            $rx = (float)($month['rx'] ?? 0);
            $tx = (float)($month['tx'] ?? 0);
            $monthLabels[] = (string)$month['date']['month'];
            $monthValues[] = round(($rx + $tx) / 1024 / 1024 / 1024, 2); // Convert KiB to GB
        }
    }
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Traffic Dashboard</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<style>
body{margin:0;font-family:Tahoma,sans-serif;background:#0f172a;color:#e2e8f0;padding:20px;}
h1,h2{margin:0 0 12px;}
.container{max-width:1000px;margin:0 auto;}
.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:15px;}
.card{background:#1e293b;padding:18px;border-radius:12px;box-shadow:0 10px 30px rgba(15,23,42,.2);}
.big{font-size:24px;font-weight:700;margin-top:6px;}
.meta{margin-top:20px;font-size:14px;color:#94a3b8;}
canvas{margin-top:10px;}
@media(max-width:700px){.grid{grid-template-columns:1fr;}}
</style>
</head>
<body>
<div class="container">
  <h1>Traffic Dashboard</h1>
  <p class="meta"><?php echo htmlspecialchars($statusMessage, ENT_QUOTES, 'UTF-8'); ?></p>
  <div class="grid">
    <div class="card">
      <div>Today's Download</div>
      <div class="big"><?php echo htmlspecialchars(number_format($todayRx, 2), ENT_QUOTES, 'UTF-8'); ?> MB</div>
    </div>
    <div class="card">
      <div>Today's Upload</div>
      <div class="big"><?php echo htmlspecialchars(number_format($todayTx, 2), ENT_QUOTES, 'UTF-8'); ?> MB</div>
    </div>
    <div class="card">
      <h2>Interface</h2>
      <div class="big"><?php echo htmlspecialchars($ifaceName, ENT_QUOTES, 'UTF-8'); ?></div>
    </div>
    <div class="card">
      <h2>Panel Notes</h2>
      <div>Charts stay empty until vnStat collects data.</div>
    </div>
  </div>
  <div class="card" style="margin-top:15px;">
    <h2>Daily Traffic (MB)</h2>
    <canvas id="dailyChart"></canvas>
  </div>
  <div class="card" style="margin-top:15px;">
    <h2>Monthly Traffic (GB)</h2>
    <canvas id="monthChart"></canvas>
  </div>
</div>
<script>
// Render Daily Traffic Chart
new Chart(document.getElementById('dailyChart'), {
  type: 'line',
  data: {
    labels: <?php echo json_encode($dailyLabels, JSON_UNESCAPED_SLASHES); ?>,
    datasets: [{
      label: 'Daily MB',
      data: <?php echo json_encode($dailyValues, JSON_UNESCAPED_SLASHES); ?>,
      borderColor: '#38bdf8',
      backgroundColor: 'rgba(56,189,248,0.18)',
      tension: 0.25,
      fill: true
    }]
  },
  options: {
    responsive: true,
    maintainAspectRatio: false
  }
});

// Render Monthly Traffic Chart
new Chart(document.getElementById('monthChart'), {
  type: 'bar',
  data: {
    labels: <?php echo json_encode($monthLabels, JSON_UNESCAPED_SLASHES); ?>,
    datasets: [{
      label: 'Monthly GB',
      data: <?php echo json_encode($monthValues, JSON_UNESCAPED_SLASHES); ?>,
      backgroundColor: '#10b981'
    }]
  },
  options: {
    responsive: true,
    maintainAspectRatio: false
  }
});

document.getElementById('dailyChart').style.height = '300px';
document.getElementById('monthChart').style.height = '300px';
</script>
</body>
</html>
PHP

  # Create a generic landing page for the domain root
  cat > "${PANEL_DIR}/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Service Ready</title>
<style>
body{margin:0;display:grid;place-items:center;min-height:100vh;background:#0f172a;color:#e2e8f0;font-family:Tahoma,sans-serif;}
.card{padding:24px 28px;border-radius:14px;background:#1e293b;max-width:560px;text-align:center;}
</style>
</head>
<body>
<div class="card">
  <h1>Service Ready</h1>
  <p>This host is online. Panel access requires authentication.</p>
</div>
</body>
</html>
EOF
}

# Generate VLESS client sharing links and QR codes
generate_share_links() {
  log "Generating client links and QR codes"

  ensure_dir "${SHARE_DIR}"
  chmod 700 "${SHARE_DIR}"

  SHORTIDS=("${SHORTID_1}" "${SHORTID_2}" "${SHORTID_3}")
  LINKS=()

  local sid
  for sid in "${SHORTIDS[@]}"; do
    local link
    link="vless://${UUID}@${IP}:443?security=reality&encryption=none&pbk=${PUBLIC_KEY}&type=tcp&flow=xtls-rprx-vision&sni=www.cloudflare.com&sid=${sid}#${IP}"
    LINKS+=("${link}")
    qrencode -o "${SHARE_DIR}/v2rayng_${sid}.png" "${link}"
  done
}

# Configure log rotation for Xray log files
configure_logrotate() {
  log "Configuring Xray log rotation"
  cat > /etc/logrotate.d/xray <<'EOF'
/var/log/xray/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF
}

# Set proper ownership and permissions for web and cache directories
finalize_permissions() {
  log "Fixing web permissions"
  chown -R www-data:www-data "${PANEL_DIR}"
  find "${PANEL_DIR}" -type d -exec chmod 755 {} \;
  find "${PANEL_DIR}" -type f -exec chmod 644 {} \;
  chown -R www-data:www-data "${PANEL_CACHE_DIR}"
  find "${PANEL_CACHE_DIR}" -type d -exec chmod 750 {} \;
  find "${PANEL_CACHE_DIR}" -type f -exec chmod 640 {} \;
}

# Display a summary of the installation and access credentials
print_summary() {
  printf '\nInstallation complete.\n'
  printf 'Panel URL: https://%s:%s/%s\n' "${IP}" "${PANEL_SSL_PORT}" "${PANEL_FILE}"
  printf 'Panel user: %s\n' "${PANEL_USER}"
  printf 'Panel password: %s\n' "${PANEL_PASSWORD}"
  printf 'Certificate: self-signed (%s)\n' "${SSL_CERT_FILE}"
  printf 'QR directory: %s\n' "${SHARE_DIR}"
  printf 'UUID: %s\n' "${UUID}"
  printf 'Public key: %s\n' "${PUBLIC_KEY}"
  printf 'State file: %s\n' "${STATE_FILE}"
  printf 'Xray config: %s\n' "${XRAY_CONFIG}"

  local index=1
  local link
  for link in "${LINKS[@]}"; do
    printf 'Client link %d: %s\n' "${index}" "${link}"
    index=$((index + 1))
  done

  printf 'Note: QR images are no longer exposed in the web root.\n'
  printf 'Note: The panel uses a self-signed certificate, so a browser warning is expected unless you replace it with a trusted certificate.\n'
}

# Display script usage instructions
print_usage() {
  cat <<EOF
Usage: $0 [install|update|uninstall]

Commands:
  install      Install or re-apply the full stack. Default command.
  update       Update Xray and restart it after validating the current config.
  uninstall    Remove the panel, certificates, local state, generated QR files, and Xray config written by this script.
EOF
}

# Orchestrate the full installation process
install_stack() {
  require_root
  require_apt
  install_dependencies
  install_xray
  load_or_create_state
  configure_panel_auth
  write_xray_config
  configure_vnstat
  write_panel_files
  generate_share_links
  configure_apache
  configure_firewall
  configure_logrotate
  finalize_permissions
  print_summary
}

# ==========================================
# Main Execution
# ==========================================
main() {
  # Default to "install" command if none provided
  local command="${1:-install}"

  case "${command}" in
    install)
      install_stack
      ;;
    update)
      require_root
      require_apt
      update_xray
      ;;
    uninstall)
      require_root
      uninstall_stack
      ;;
    -h|--help|help)
      print_usage
      ;;
    *)
      print_usage
      exit 1
      ;;
  esac
}

main "$@"
