#!/bin/bash
# ===============================================
# 终极 Reality 一键安装脚本
# 支持 VLESS+Reality + vnStat + Apache + 防火墙
# 完全无人值守，自动生成密钥和节点
# ===============================================

set -e
echo "===== 开始安装 ====="

# -------------------------------
# VPS IP
# -------------------------------
IP=$(curl -s https://ipinfo.io/ip || hostname -I | awk '{print $1}')
echo "[INFO] VPS IP: $IP"

# -------------------------------
# 安装基础软件
# -------------------------------
apt update -y
apt upgrade -y
apt install -y curl unzip gnupg2 ca-certificates lsb-release apache2 php php-cli vnstat openssl socat

# -------------------------------
# 防火墙配置
# -------------------------------
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw reload
echo "[INFO] 防火墙配置完成"

# -------------------------------
# vnStat 安装与面板
# -------------------------------
systemctl enable vnstat
systemctl start vnstat

mkdir -p /var/www/html/vnstat
cat > /var/www/html/vnstat/index.php <<'EOF'
<?php
$iface = trim(shell_exec("ip route | grep default | awk '{print $5}'"));
echo "<h2>vnStat Traffic for $iface</h2>";
echo "<pre>";
system("vnstat -i $iface");
echo "</pre>";
?>
EOF

chown -R www-data:www-data /var/www/html/vnstat
systemctl enable apache2
systemctl restart apache2
echo "[INFO] vnStat 面板已配置: http://$IP/vnstat/"

# -------------------------------
# 安装 Xray
# -------------------------------
echo "[INFO] 安装 Xray"
bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install

# -------------------------------
# 生成 Reality x25519 密钥
# -------------------------------
echo "[INFO] 生成 Reality x25519 密钥"
REALITY_PRIVATE_KEY=$(xray x25519 | awk '/Private/{print $3}')
REALITY_PUBLIC_KEY=$(xray x25519 | awk '/Public/{print $3}')

# -------------------------------
# 生成 UUID + 3 shortId
# -------------------------------
REALITY_UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT_IDS=()
for i in {1..3}; do
  SHORT_IDS+=($(head /dev/urandom | tr -dc a-f0-9 | head -c8))
done

REALITY_SNI="www.cloudflare.com"

# -------------------------------
# 写入 Xray config.json
# -------------------------------
XRAY_CONF="/usr/local/etc/xray/config.json"
cat > $XRAY_CONF <<EOF
{
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "$REALITY_UUID",
        "flow": "xtls-rprx-vision"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "$IP:443",
        "publicKey": "$REALITY_PUBLIC_KEY",
        "privateKey": "$REALITY_PRIVATE_KEY",
        "shortIds": ["${SHORT_IDS[0]}","${SHORT_IDS[1]}","${SHORT_IDS[2]}"],
        "serverNames": ["$REALITY_SNI"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom","settings":{}}]
}
EOF

systemctl enable xray
systemctl restart xray
echo "[INFO] Xray Reality 安装完成"

# -------------------------------
# 输出 v2rayN / v2rayNG 节点
# -------------------------------
echo ""
echo "=============================="
echo "🎉 安装完成！"
echo "vnStat 面板: http://$IP/vnstat/"
echo ""
echo "Reality VLESS 节点链接:"
for i in {0..2}; do
  echo "vless://$REALITY_UUID@$IP:443?security=reality&flow=xtls-rprx-vision&type=tcp&reality-public-key=$REALITY_PUBLIC_KEY&reality-short-id=${SHORT_IDS[i]}&sni=$REALITY_SNI#$IP-$((i+1))"
done
echo "=============================="
