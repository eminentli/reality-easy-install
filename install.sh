#!/bin/bash

# =========================
# 🔧 只需要修改这 3 个变量
# =========================

SNI="www.cloudflare.com"   # 👉 可改：www.google.com / 自己域名
SHORT_ID="12345678"        # 👉 改成随机8位（字母数字都行）
LIMIT=1600                 # 👉 流量提醒阈值（GB），2TB建议1600

# =========================
# 🚀 自动执行部分（不用改）
# =========================

echo "更新系统..."
apt update -y && apt upgrade -y

echo "安装依赖..."
apt install -y curl git unzip php php-cli apache2 vnstat qrencode

echo "安装 Xray..."
bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)

echo "生成 UUID 和 Reality 密钥..."
UUID=$(cat /proc/sys/kernel/random/uuid)
KEY_PAIR=$(xray x25519)
PRIVATE_KEY=$(echo "$KEY_PAIR" | grep Private | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEY_PAIR" | grep Public | awk '{print $3}')

IP=$(curl -s ifconfig.me)
IFACE=$(ip route | grep default | awk '{print $5}')

echo "写入 Xray 配置..."
cat > /usr/local/etc/xray/config.json <<EOF
{
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{"id":"$UUID","flow":"xtls-rprx-vision"}],
      "decryption":"none"
    },
    "streamSettings": {
      "network":"tcp",
      "security":"reality",
      "realitySettings": {
        "dest":"$SNI:443",
        "serverNames":["$SNI"],
        "privateKey":"$PRIVATE_KEY",
        "shortIds":["$SHORT_ID"]
      }
    }
  }],
  "outbounds":[{"protocol":"freedom"}]
}
EOF

systemctl enable xray
systemctl restart xray

echo "部署 vnStat Web 面板..."
cd /var/www/html
rm -rf vnstat
git clone https://github.com/bjd/vnstat-php.git vnstat
echo "<?php \$iface='$IFACE'; ?>" > /var/www/html/vnstat/config.php
chown -R www-data:www-data vnstat

systemctl enable vnstat
systemctl start vnstat
systemctl restart apache2

echo "创建流量监控脚本..."
cat > /root/traffic_check.sh <<EOL
#!/bin/bash
LIMIT=$LIMIT
USED=\$(vnstat --json | grep -oP '"rx":\K[0-9]+' | head -1)
USED_GB=\$((USED / 1024 / 1024))
if [ "\$USED_GB" -gt "\$LIMIT" ]; then
    echo "⚠️ 流量已超过 ${LIMIT}GB，请考虑 Stop VPS"
fi
EOL

chmod +x /root/traffic_check.sh
(crontab -l 2>/dev/null; echo "0 * * * * /root/traffic_check.sh") | crontab -

echo ""
echo "=============================="
echo "🎉 部署完成"
echo "=============================="
echo "IP: $IP"
echo "端口: 443"
echo "UUID: $UUID"
echo "PublicKey: $PUBLIC_KEY"
echo "ShortID: $SHORT_ID"
echo "SNI: $SNI"
echo ""
echo "📊 流量面板:"
echo "http://$IP/vnstat/"
echo ""
echo "📱 v2rayN 配置链接："
echo ""
echo "vless://$UUID@$IP:443?security=reality&flow=xtls-rprx-vision&type=tcp&reality-public-key=$PUBLIC_KEY&reality-short-id=$SHORT_ID&sni=$SNI#$IP"
echo "=============================="
