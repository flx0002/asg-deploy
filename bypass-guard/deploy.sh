#!/bin/bash
# deploy.sh: asg-bypass-guard 一键部署/更新（编译 → systemd 服务接管）
set -e
export PATH=/usr/local/go/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH
DIR=/home/wnt/ASG/asg-bypass-guard
cd "$DIR"

echo "=== 1. 编译 ==="
go build -o asg-bypass-guard . 2>&1 | tail -5
echo "BUILD OK"

echo "=== 2. 清理旧进程（nohup 残留） ==="
pkill -f "asg-bypass-guard -config" 2>/dev/null || true
sleep 1

echo "=== 3. 安装 systemd 服务 ==="
cp -f asg-bypass-guard.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable asg-bypass-guard >/dev/null 2>&1
systemctl restart asg-bypass-guard
sleep 2

echo "=== 4. 服务状态 ==="
systemctl --no-pager -l status asg-bypass-guard | sed -n '1,8p'

echo "=== 5. 启动日志 ==="
tail -3 /var/log/bypass-guard.log 2>/dev/null || journalctl -u asg-bypass-guard --no-pager -n 3
echo "DEPLOY DONE"
