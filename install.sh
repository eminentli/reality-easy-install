#!/bin/bash
# 一键安装 Xray + Reality + vnStat 流量面板
set -e

# =====================
# 1. 安装基础依赖
# =====================
apt update -y
apt install -y curl wget unzip php-cli php-gd libapache2-mod-php apache2 qrencode vnstat git systemd

# =====================
# 2. Apache + PHP 配置
# =====================
a2enmod php8.1 || true  # 根据系统 PHP 版本调整
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

# 生成 Reality keypair
KEYPAIR=$(/usr/local/bin/xray x25519)

# 提取 PrivateKey
PRIVATE_KEY=$(echo "$KEYPAIR" | grep -oP '(?<=PrivateKey: )[^ ]+')

# 提取 PublicKey
PUBLIC_KEY=$(echo "$KEYPAIR" | grep -oP '(?<=PublicKey\): )[^ ]+')

echo "PRIVATE_KEY=$PRIVATE_KEY"
echo "PUBLIC_KEY=$PUBLIC_KEY"


if [ -z "$PUBLIC_KEY" ]; then
  echo "ERROR: PUBLIC_KEY is empty! Reality keypair generation failed."
  exit 1
fi

# 生成短 ID
SHORTIDS=()
for i in {1..3}; do
  SHORTIDS+=($(head -c 4 /dev/urandom | xxd -p))
done

# 生成 Xray config.json
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
ini_set('display_errors',1);
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
@media(max-width:600px){.grid{grid-template-columns:1fr;}}
canvas{margin-top:10px;}
</style>
</head>
<body>
<div class="container">
<h1>📊 Traffic Dashboard</h1>
<div class="grid">
<?php
$json = shell_exec("vnstat --json");
$data = json_decode($json,true);

// 自动找到正确网卡（非 lo / docker）
$ifaceData = null;
foreach ($data['interfaces'] as $iface) {
    if ($iface['name'] != 'lo') {
        $ifaceData = $iface;
        break;
    }
}

if (!$ifaceData) {
    echo "No valid interface found";
    exit;
}


// 今日上传/下载
$today_rx = $today_tx = 0;
if(isset($ifaceData['traffic']['day'][0])){
    $today_rx = round($ifaceData['traffic']['day'][0]['rx']/1024/1024,2);
    $today_tx = round($ifaceData['traffic']['day'][0]['tx']/1024/1024,2);
}
echo "<div class='card'><div>📥 今日下载</div><div class='big'>{$today_rx} MB</div></div>";
echo "<div class='card'><div>📤 今日上传</div><div class='big'>{$today_tx} MB</div></div>";
?>
</div>

<br>
<div class="card"><h2>🌍 User Traffic (UUID)</h2>
<table class="table">
<tr><td><?php echo $ifaceData['name']??'N/A'; ?></td><td>示例流量</td></tr>
</table></div>

<br>
<div class="card"><h2>📈 Daily Traffic (MB)</h2><canvas id="dailyChart"></canvas></div>
<div class="card"><h2>📊 Monthly Traffic (GB)</h2><canvas id="monthChart"></canvas></div>
<div class="card"><h2>⚡ Live Traffic</h2><pre id="liveTraffic"></pre></div>

<script>
// 日流量图表
const dailyChart = new Chart(document.getElementById('dailyChart'), {
    type:'line',
    data:{
        labels: <?php
        $daily_labels=[];
        $daily_values=[];
        if(isset($ifaceData['traffic']['day'])){
            foreach($ifaceData['traffic']['day'] as $day){
                $daily_labels[] = $day['date']['day'].'/'.$day['date']['month'];
                $daily_values[] = round(($day['rx']+$day['tx'])/1024/1024,2);
            }
        }
        echo json_encode($daily_labels);
        ?>,
        datasets:[{label:'Daily MB', data: <?php echo json_encode($daily_values); ?>, borderColor:'#3b82f6', backgroundColor:'rgba(59,130,246,0.2)'}]
    }
});

// 月流量图表
const monthChart = new Chart(document.getElementById('monthChart'), {
    type:'bar',
    data:{
        labels: <?php
        $month_labels=[];
        $month_values=[];
        if(isset($ifaceData['traffic']['month'])){
            foreach($ifaceData['traffic']['month'] as $month){
                $month_labels[] = $month['date']['month'];
                $month_values[] = round(($month['rx']+$month['tx'])/1024/1024/1024,2);
            }
        }
        echo json_encode($month_labels);
        ?>,
        datasets:[{label:'Monthly GB', data: <?php echo json_encode($month_values); ?>, backgroundColor:'#10b981'}]
    }
});
</script>
</body>
</html>
EOF

chown -R www-data:www-data /var/www/html

# =====================
# 7. 生成 v2rayNG 链接和二维码
# =====================
echo "v2rayNG UUID: $UUID"
for sid in "${SHORTIDS[@]}"; do
  LINK="vless://$UUID@$IP:443?security=reality&encryption=none&pbk=$PUBLIC_KEY&type=tcp&flow=xtls-rprx-vision&sni=www.cloudflare.com&sid=$sid#$IP"
  echo "$LINK"
  qrencode -o /var/www/html/v2rayng_$sid.png "$LINK"
done

# =====================
# 8. logrotate 配置
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
# 9. 完成提示
# =====================
echo "安装完成！"
echo "访问面板：http://$IP/"
echo "v2rayNG QR 已生成在 /var/www/html/"
