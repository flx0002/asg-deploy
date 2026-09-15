#!/bin/bash
# deploy.sh: asg-bypass-guard 一键部署/更新
#   源码目录 = 本脚本所在目录（asg-deploy/bypass-guard，唯一权威）
#   运行目录 = /opt/asg-bypass-guard（二进制 + config.yaml + 日志），与离线 install.sh 统一
set -e
export PATH=/usr/local/go/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN=/opt/asg-bypass-guard

echo "=== 1. 准备运行目录 $RUN ==="
mkdir -p "$RUN"

echo "=== 2. 编译（源码 $SRC → $RUN）==="
cd "$SRC"
go build -o "$RUN/asg-bypass-guard" . 2>&1 | tail -5
echo "BUILD OK"

echo "=== 3. config.yaml ==="
if [ -f "$RUN/config.yaml" ]; then
  echo "  保留已有 $RUN/config.yaml（不覆盖现网配置）"
else
  IFACE=$(ip route show default | awk '/default/{print $5; exit}')
  NODE_IP=$(docker inspect higress-control-plane --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}' 2>/dev/null || hostname -I | awk '{print $1}')
  sed -e "s/__IFACE__/$IFACE/g" -e "s/__NODE_IP__/$NODE_IP/g" config.yaml.example > "$RUN/config.yaml"
  echo "  首次部署：从 config.yaml.example 渲染（interface=$IFACE node_ip=$NODE_IP）"
fi

echo "=== 4. 停止旧服务 + 清理游离进程 ==="
systemctl stop asg-bypass-guard 2>/dev/null || true
pkill -f "asg-bypass-guard -config" 2>/dev/null || true
sleep 1

echo "=== 5. 安装 systemd 服务 ==="
cp -f asg-bypass-guard.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable asg-bypass-guard >/dev/null 2>&1
systemctl restart asg-bypass-guard
sleep 2

echo "=== 6. 服务状态 ==="
systemctl --no-pager -l status asg-bypass-guard | sed -n '1,8p'

echo "=== 7. 启动日志 ==="
tail -3 /var/log/bypass-guard.log 2>/dev/null || journalctl -u asg-bypass-guard --no-pager -n 3
echo "DEPLOY DONE"
