#!/bin/bash
set -e

echo "===== Reality 一键稳定安装开始 ====="

# -------------------------------
# 获取 IP
# -------------------------------
IP=$(curl -s https://ipinfo.io/ip || hostname -I | awk '{print $1}')
echo "[INFO] IP: $IP"

# -------------------------------
# 安装基础
# -------------------------------
apt update -y
apt install -y curl unzip apache2 php php-cli vnstat ufw

# -------------------------------
# 防火墙
# -------------------------------
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw reload

# -------------------------------
# 检查 443 端口
# -------------------------------
if ss -tlnp | grep -q ":443"; then
    echo "[ERROR] 443端口被占用，请先释放（如关闭nginx/apache ssl）"
    exit 1
fi

# -------------------------------
# vnStat + 面板
# -------------------------------
systemctl enable vnstat
systemctl start vnstat

mkdir -p /var/www/html/vnstat
cat > /var/www/html/vnstat/index.php <<'EOF'
<?php
$iface = trim(shell_exec("ip route | grep default | awk '{print $5}'"));
echo "<h2>Traffic ($iface)</h2><pre>";
system("vnstat -i $iface");
echo "</pre>";
?>
EOF

chown -R www-data:www-data /var/www/html/vnstat
systemctl restart apache2
systemctl enable apache2

# -------------------------------
# 安装 Xray
# -------------------------------
bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install

# -------------------------------
# 生成 Reality 密钥
# -------------------------------
KEYPAIR=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYPAIR" | grep Private | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYPAIR" | grep Public | awk '{print $3}')

# -------------------------------
# UUID + shortId
# -------------------------------
UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(head /dev/urandom | tr -dc a-f0-9 | head -c8)

# -------------------------------
# 写配置（关键修复点）
# -------------------------------
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "$UUID",
        "flow": "xtls-rprx-vision"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "www.cloudflare.com:443",
        "serverNames": ["www.cloudflare.com"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

# -------------------------------
# 启动 Xray
# -------------------------------
systemctl enable xray
systemctl restart xray

# -------------------------------
# 输出节点
# -------------------------------
echo ""
echo "========= 🎉 安装完成 ========="
echo "vnStat 面板: http://$IP/vnstat/"
echo ""
echo "👇 v2rayNG / v2rayN 节点："
echo ""
echo "vless://$UUID@$IP:443?security=reality&flow=xtls-rprx-vision&type=tcp&reality-public-key=$PUBLIC_KEY&reality-short-id=$SHORT_ID&sni=www.cloudflare.com#$IP"
echo ""
echo "=============================="
