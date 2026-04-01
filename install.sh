#!/bin/bash
# 一键安装/修复 Xray + vnStat 流量面板
set -e

# =====================
# 1. 基础依赖安装
# =====================
apt update -y
apt install -y curl wget unzip php-cli php-gd libapache2-mod-php apache2 qrencode vnstat git systemd

# =====================
# 2. Apache + PHP 配置
# =====================
a2enmod php8.1 || true   # 根据系统 PHP 版本调整
sed -i 's/DirectoryIndex .*/DirectoryIndex index.php index.html/' /etc/apache2/mods-enabled/dir.conf
systemctl restart apache2

# =====================
# 3. 配置防火墙
# =====================
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw reload

# =====================
# 4. 安装 Xray
# =====================
IP=$(curl -s https://ipinfo.io/ip)
UUID=$(cat /proc/sys/kernel/random/uuid)

bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install

KEYPAIR=$(/usr/local/bin/xray x25519)
PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEYPAIR" | grep "Password" | awk '{print $2}')

SHORTIDS=()
for i in {1..3}; do
  SHORTIDS+=($(head -c 4 /dev/urandom | xxd -p))
done

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

systemctl enable xray
systemctl restart xray

# =====================
# 5. vnStat 后台服务
# =====================
systemctl enable vnstat
systemctl start vnstat

# =====================
# 6. 创建轻量化面板
# =====================
cat > /var/www/html/index.php <<'EOF'
<?php
ini_set('display_errors', 1);
error_reporting(E_ALL);
?>
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Traffic Dashboard</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<style>
body{margin:0;font-family:Arial;background:#0f172a;color:#e2e8f0;padding:20px;}
h1{text-align:center;}
.container{max-width:1000px;margin:auto;}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:15px;}
.card{background:#1e293b;padding:15px;border-radius:12px;}
.big{font-size:22px;font-weight:bold;}
.table{width:100%;font-size:14px;}
.table td{padding:6px;border-bottom:1px solid #334155;}
@media(max-width:600px){.grid{grid-template-columns:1fr;}};
canvas{margin-top:10px;}
</style>
</head>
<body>
<div class="container">
<h1>📊 Traffic Dashboard</h1>
<div class="grid">
<?php
// 读取 vnStat JSON 数据
$json = shell_exec("vnstat --json");
$data = json_decode($json,true);

$today_rx = $today_tx = 0;
if(isset($data['interfaces'][0]['traffic']['days'][0])){
    $today_rx = round($data['interfaces'][0]['traffic']['days'][0]['rx']/1024/1024,2);
    $today_tx = round($data['interfaces'][0]['traffic']['days'][0]['tx']/1024/1024,2);
}
echo "<div class='card'><div>📥 今日下载</div><div class='big'>{$today_rx} MB</div></div>";
echo "<div class='card'><div>📤 今日上传</div><div class='big'>{$today_tx} MB</div></div>";
?>
</div>
<br>
<div class="card"><h2>🌍 User Traffic (UUID)</h2>
<table class="table">
<tr><td><?php echo $data['interfaces'][0]['name']??'N/A'; ?></td><td>示例流量</td></tr>
</table></div>
<br>
<div class="card"><h2>📈 Daily Traffic (MB)</h2><canvas id="dailyChart"></canvas></div>
<div class="card"><h2>📊 Monthly Traffic (GB)</h2><canvas id="monthChart"></canvas></div>
<div class="card"><h2>⚡ Live Traffic</h2><pre id="liveTraffic"></pre></div>

<script>
const dailyChart = new Chart(document.getElementById('dailyChart'), {
    type:'line',
    data:{
        labels:['Mon','Tue','Wed','Thu','Fri','Sat','Sun'],
        datasets:[{label:'Daily MB',data:[12,19,3,5,2,3,7],borderColor:'#3b82f6',backgroundColor:'rgba(59,130,246,0.2)'}]
    }
});
const monthChart = new Chart(document.getElementById('monthChart'), {
    type:'bar',
    data:{
        labels:['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'],
        datasets:[{label:'Monthly GB',data:[1.2,1.5,0.9,2.1,3.0,2.8,1.7,2.5,3.1,2.2,1.9,2.0],backgroundColor:'#10b981'}]
    }
});
</script>
</body>
</html>
EOF

chown -R www-data:www-data /var/www/html

# =====================
# 7. logrotate 配置
# =====================
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

cat > /etc/logrotate.d/vnstat <<'EOF'
/var/lib/vnstat/*.db {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF

# =====================
# 8. 完成提示
# =====================
echo "安装完成！"
echo "访问面板：http://$IP/"
echo "v2rayNG UUID：$UUID"
