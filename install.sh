#!/bin/bash
# ===============================================
# 完整无人值守 Reality + vnStat + Apache + 防火墙 + Telegram 流量预警 + VPS 定时关机
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
apt install -y curl unzip gnupg2 ca-certificates lsb-release apache2 php php-cli vnstat python3-pip

# -------------------------------
# 安装 Telegram 依赖
# -------------------------------
pip3 install requests

# -------------------------------
# 配置防火墙
# -------------------------------
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw reload
echo "[INFO] 防火墙配置完成"

# -------------------------------
# 安装并启动 vnStat
# -------------------------------
systemctl enable vnstat
systemctl start vnstat

# -------------------------------
# 创建 PHP 面板
# -------------------------------
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
# 安装 Xray Reality
# -------------------------------
echo "[INFO] 安装 Xray Reality 节点"

REALITY_UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT_IDS=()
for i in {1..3}; do
  SHORT_IDS+=($(head /dev/urandom | tr -dc a-f0-9 | head -c8))
done
REALITY_SNI="www.cloudflare.com"

bash <(curl -Ls https://raw.githubusercontent.com/eminentli/reality-easy-install/main/install.sh) <<EOF
$REALITY_UUID
${SHORT_IDS[0]}
${SHORT_IDS[1]}
${SHORT_IDS[2]}
$REALITY_SNI
EOF

systemctl enable xray
systemctl restart xray
echo "[INFO] Xray Reality 安装完成"

# -------------------------------
# 输出节点信息
# -------------------------------
echo ""
echo "=============================="
echo "🎉 安装完成！"
echo "vnStat 面板访问链接: http://$IP/vnstat/"
echo "Reality VLESS 节点链接:"
for i in {0..2}; do
  echo "vless://$REALITY_UUID@$IP:443?security=reality&flow=xtls-rprx-vision&type=tcp&reality-short-id=${SHORT_IDS[i]}&sni=$REALITY_SNI#$IP-$((i+1))"
done
echo "=============================="
echo ""

# -------------------------------
# 可选：配置 Telegram 流量预警
# -------------------------------
read -p "是否配置 Telegram 流量预警? (y/n): " CONFIG_TG
if [[ "$CONFIG_TG" == "y" ]]; then
    read -p "输入 Telegram Bot Token: " TG_BOT
    read -p "输入 Telegram Chat ID: " TG_CHAT
    read -p "流量阈值(MB): " TRAFFIC_LIMIT

    cat > /usr/local/bin/telegram_vnstat_alert.py <<EOF
#!/usr/bin/env python3
import requests, os
iface = os.popen("ip route | grep default | awk '{print \$5}'").read().strip()
vnstat = os.popen(f"vnstat -i {iface} --oneline").read().split(";")
today_mb = float(vnstat[2])/1024
if today_mb > float($TRAFFIC_LIMIT):
    requests.get(f"https://api.telegram.org/bot$TG_BOT/sendMessage?chat_id=$TG_CHAT&text=VPS {IP} 流量达到 {today_mb:.2f} MB")
EOF
    chmod +x /usr/local/bin/telegram_vnstat_alert.py

    # 配置 crontab 每小时检查一次
    (crontab -l 2>/dev/null; echo "0 * * * * /usr/bin/python3 /usr/local/bin/telegram_vnstat_alert.py") | crontab -
    echo "[INFO] Telegram 流量预警已配置"
fi

# -------------------------------
# 可选：自动按小时关机节省费用
# -------------------------------
read -p "是否设置定时关机(按小时)? (y/n): " AUTO_SHUTDOWN
if [[ "$AUTO_SHUTDOWN" == "y" ]]; then
    read -p "输入开机后多少小时自动关机? " HOURS
    echo "shutdown -h +$((HOURS*60))" > /etc/rc.local
    chmod +x /etc/rc.local
    /etc/rc.local
    echo "[INFO] 自动关机已设置"
fi

echo "[INFO] 全部安装和配置完成 🎉"
