#!/bin/bash
# ultimate-xray-vnstat-panel.sh
# 一键安装 Xray + vnStat + Web 流量面板

set -e

IP=$(curl -s https://ipinfo.io/ip)
UUID=$(cat /proc/sys/kernel/random/uuid)

echo "更新系统并安装基础依赖..."
apt update -y
apt install -y curl wget unzip php-cli php-gd apache2 qrencode vnstat logrotate

echo "配置防火墙..."
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw reload

echo "安装 Xray 最新版本..."
bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install

echo "生成 Reality keypair..."
KEYPAIR=$(/usr/local/bin/xray x25519)
PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEYPAIR" | grep "Password" | awk '{print $2}')


# 生成短 ID 列表
SHORTIDS=()
for i in {1..3}; do
  SHORTIDS+=($(head -c 4 /dev/urandom | xxd -p))
done

# 生成 Xray config.json
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { 
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID", "flow": "xtls-rprx-vision", "email": "user1" }
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

echo "初始化 vnStat..."
IFACE=$(ip route | grep default | awk '{print $5}')
vnstat -u -i $IFACE
systemctl restart vnstat

echo "安装 Apache2 + PHP..."
systemctl enable apache2
systemctl restart apache2

echo "创建轻量化流量面板页面..."
cat > /var/www/html/index.php <<'EOF'
<?php
header('Content-Type: text/html; charset=utf-8');

// 1. vnStat JSON 数据
$data = json_decode(shell_exec("vnstat --json"), true);

$today_rx = 0; $today_tx = 0;
$today = date("Y-n-j");
foreach ($data['interfaces'][0]['traffic']['day'] as $d) {
    $date = $d['date']['year']."-".$d['date']['month']."-".$d['date']['day'];
    if ($date == $today) {
        $today_rx = round($d['rx']/1024/1024,2);
        $today_tx = round($d['tx']/1024/1024,2);
    }
}

// 2. Xray 日志解析 UUID 流量
$log_file = "/var/log/xray/access.log";
$users = [];
if (file_exists($log_file)) {
    $lines = file($log_file);
    foreach ($lines as $line) {
        if (preg_match('/email: (.*?) /', $line, $u)) {
            $uuid = $u[1];
            preg_match('/(\d+) bytes/', $line, $b);
            $bytes = isset($b[1]) ? (int)$b[1] : 0;
            if (!isset($users[$uuid])) $users[$uuid] = 0;
            $users[$uuid] += $bytes;
        }
    }
}
foreach ($users as $k=>$v) $users[$k] = round($v/1024/1024,2);

// 3. 日/月流量折线/柱状图
$days=[]; $rx=[]; $tx=[];
foreach ($data['interfaces'][0]['traffic']['day'] as $d) {
    $days[]=$d['date']['year']."-".$d['date']['month']."-".$d['date']['day'];
    $rx[]=round($d['rx']/1024/1024,2);
    $tx[]=round($d['tx']/1024/1024,2);
}
$months=[]; $m_rx=[]; $m_tx=[];
foreach ($data['interfaces'][0]['traffic']['month'] as $m) {
    $months[]=$m['date']['year']."-".$m['date']['month'];
    $m_rx[]=round($m['rx']/1024/1024/1024,2);
    $m_tx[]=round($m['tx']/1024/1024/1024,2);
}
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
<div class="card"><div>📥 今日下载</div><div class="big"><?php echo $today_rx; ?> MB</div></div>
<div class="card"><div>📤 今日上传</div><div class="big"><?php echo $today_tx; ?> MB</div></div>
</div>
<br>
<div class="card"><h2>🌍 User Traffic (UUID)</h2>
<table class="table">
<?php foreach($users as $uuid=>$mb):?><tr><td><?php echo substr($uuid,0,8).'...';?></td><td><?php echo $mb;?> MB</td></tr><?php endforeach;?>
</table></div>
<br>
<div class="card"><h2>📈 Daily Traffic (MB)</h2><canvas id="dailyChart"></canvas></div>
<div class="card"><h2>📊 Monthly Traffic (GB)</h2><canvas id="monthChart"></canvas></div>
<div class="card"><h2>⚡ Live Traffic</h2><pre><?php echo shell_exec("vnstat -l --style 1 -tr 3");?></pre></div>
</div>

<script>
const days=<?php echo json_encode($days); ?>;
const rx=<?php echo json_encode($rx); ?>;
const tx=<?php echo json_encode($tx); ?>;
new Chart(document.getElementById('dailyChart'),{type:'line',data:{labels:days,datasets:[{label:'Download (MB)',data:rx},{label:'Upload (MB)',data:tx}]}});

const months=<?php echo json_encode($months); ?>;
const m_rx=<?php echo json_encode($m_rx); ?>;
const m_tx=<?php echo json_encode($m_tx); ?>;
new Chart(document.getElementById('monthChart'),{type:'bar',data:{labels:months,datasets:[{label:'Download (GB)',data:m_rx},{label:'Upload (GB)',data:m_tx}]}});

setTimeout(()=>location.reload(),30000);
</script>
</body>
</html>
EOF

echo "配置 logrotate 管理 Xray 日志..."
cat > /etc/logrotate.d/xray <<'EOF'
/var/log/xray/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 644 root root
    sharedscripts
    postrotate
        systemctl restart xray > /dev/null 2>&1 || true
    endscript
}
EOF

echo "安装完成！"
echo "访问流量面板：http://$IP/"
