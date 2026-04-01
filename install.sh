#!/bin/bash
# reality-easy-install.sh
# 终极全自动 Xray Reality + vnStat 面板安装脚本

set -e

IP=$(curl -s https://ipinfo.io/ip)
UUID=$(cat /proc/sys/kernel/random/uuid)

# 安装基础依赖
apt update -y
apt install -y curl wget unzip php-cli php-gd apache2 qrencode vnstat

# 配置防火墙
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw reload

# 安装 Xray 最新版本
bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install

# 生成 Reality keypair
KEYPAIR=$(/usr/local/bin/xray x25519)
PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEYPAIR" | grep "Password" | awk '{print $2}')

# 生成短 ID 列表
SHORTIDS=()
for i in {1..3}; do
  SHORTIDS+=($(head -c 4 /dev/urandom | xxd -p))
done

# 生成 config.json
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "www.cloudflare.com:443",
          "serverNames": ["www.cloudflare.com"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["${SHORTIDS[0]}","${SHORTIDS[1]}","${SHORTIDS[2]}"]
        }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# 启用并启动 Xray
systemctl enable xray
systemctl restart xray

# 安装 vnStat 面板
wget -O /var/www/html/vnstat.zip https://github.com/vergoh/vnstat-php/archive/refs/heads/main.zip
unzip /var/www/html/vnstat.zip -d /var/www/html/
mv /var/www/html/vnstat-php-main /var/www/html/vnstat
chown -R www-data:www-data /var/www/html/vnstat

# 启动 Apache2
systemctl enable apache2
systemctl restart apache2

# 输出 v2rayNG 链接并生成二维码
echo "v2rayNG 链接列表："
for sid in "${SHORTIDS[@]}"; do
  LINK="vless://$UUID@$IP:443?security=reality&encryption=none&pbk=$PUBLIC_KEY&type=tcp&flow=xtls-rprx-vision&sni=www.cloudflare.com&sid=$sid#$IP"
  echo "$LINK"
  qrencode -o /var/www/html/v2rayng_$sid.png "$LINK"
done

echo "vnStat 面板地址：http://$IP/vnstat/"
echo "二维码 PNG 已生成在 /var/www/html/"
