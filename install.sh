#!/bin/bash

# =========================
# 🔧 可选修改参数
# =========================
SNI="www.cloudflare.com"     # 伪装域名
LIMIT=1600                    # 流量阈值 (GB)
VNSTAT_BRANCH="master"        # vnStat PHP 仓库分支

# =========================
# 系统更新
# =========================
echo "更新系统..."
DEBIAN_FRONTEND=noninteractive apt update -y && apt upgrade -y

echo "安装依赖..."
DEBIAN_FRONTEND=noninteractive apt install -y curl git unzip php php-cli apache2 vnstat qrencode openssl

# =========================
# 安装 Xray
# =========================
echo "安装 Xray..."
bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh) <<< "n"

# =========================
# 生成 UUID
# =========================
UUID=$(cat /proc/sys/kernel/random/uuid)

# =========================
# 生成 Reality 密钥
# =========================
KEY_PAIR=$(xray x25519)
PRIVATE_KEY=$(echo "$KEY_PAIR" | grep Private | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEY_PAIR" | grep Public | awk '{print $3}')

# =========================
# 生成多个 shortId
# =========================
SHORT_ID1=$(openssl rand -hex 4)
SHORT_ID2=$(openssl rand -hex 4)
SHORT_ID3=$(openssl rand -hex 4)

IP=$(curl -s ifconfig.me)
IFACE=$(ip route | grep default | awk '{print $5}')

# =========================
# 写入 Xray 配置
# =========================
cat > /usr/local/etc/xray/config.json <<EOF
{
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
        "dest": "$SNI:443",
        "serverNames": ["$SNI"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID1","$SHORT_ID2","$SHORT_ID3"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

systemctl enable xray
systemctl restart xray

# =========================
# 安装 vnStat 面板（无需认证）
# =========================
echo "部署 vnStat 面板..."
cd /var/www/html
rm -rf vnstat

# 公共 URL 下载 zip 并解压
wget https://github.com/bjd/vnstat-php/archive/refs/heads/$VNSTAT_BRANCH.zip -O vnstat.zip
unzip -o vnstat.zip
mv vnstat-php-$VNSTAT_BRANCH vnstat
rm vnstat.zip
echo "<?php \$iface='$IFACE'; ?>" > /var/www/html/vnstat/config.php
chown -R www-data:www-data vnstat

systemctl enable vnstat
systemctl start vnstat
systemctl restart apache2

# =========================
# 设置流量监控
# =========================
cat > /root/traffic_check.sh <<EOL
#!/bin/bash
LIMIT=$LIMIT
USED=\$(vnstat --json | grep -oP '"rx":\K[0-9]+' | head -1)
USED_GB=\$((USED / 1024 / 1024))
if [ "\$USED_GB" -gt "\$LIMIT" ]; then
    echo "⚠️ 流量超过 ${LIMIT}GB"
fi
EOL

chmod +x /root/traffic_check.sh
(crontab -l 2>/dev/null; echo "0 * * * * /root/traffic_check.sh") | crontab -

# =========================
# 生成 v2rayN 导入链接
# =========================
LINK1="vless://$UUID@$IP:443?security=reality&flow=xtls-rprx-vision&type=tcp&reality-public-key=$PUBLIC_KEY&reality-short-id=$SHORT_ID1&sni=$SNI#$IP-1"
LINK2="vless://$UUID@$IP:443?security=reality&flow=xtls-rprx-vision&type=tcp&reality-public-key=$PUBLIC_KEY&reality-short-id=$SHORT_ID2&sni=$SNI#$IP-2"
LINK3="vless://$UUID@$IP:443?security=reality&flow=xtls-rprx-vision&type=tcp&reality-public-key=$PUBLIC_KEY&reality-short-id=$SHORT_ID3&sni=$SNI#$IP-3"

# =========================
# 完成提示
# =========================
echo ""
echo "=============================="
echo "🎉 安装完成（安全无人值守版）"
echo "=============================="
echo "IP: $IP"
echo "UUID: $UUID"
echo "PublicKey: $PUBLIC_KEY"
echo ""
echo "🔑 ShortIDs:"
echo "$SHORT_ID1"
echo "$SHORT_ID2"
echo "$SHORT_ID3"
echo ""
echo "📊 流量面板: http://$IP/vnstat/"
echo ""
echo "📱 v2rayN 导入链接（任选一个）："
echo "$LINK1"
echo "$LINK2"
echo "$LINK3"
echo "=============================="

echo "二维码（终端显示）:"
qrencode -t ansiutf8 "$LINK1"
