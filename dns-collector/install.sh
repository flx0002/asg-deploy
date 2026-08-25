#!/bin/bash
# DNS Shadow AI 采集器安装脚本（systemd 服务化）
# 用法: ./install.sh [collector-token]   # 可选覆盖 token，默认 wnt-asg-collector-2026
# 环境: ASG_CONSOLE_BASE 可覆盖 console 地址，默认 http://172.22.0.2:30080
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST=/opt/dns-shadow-ai
TOKEN="${1:-wnt-asg-collector-2026}"
CONSOLE_BASE="${ASG_CONSOLE_BASE:-http://172.22.0.2:30080}"

mkdir -p "$DEST"
install -m 644 "$SRC/collector.py" "$DEST/collector.py"
sed -e "s|__ASG_CONSOLE_BASE__|$CONSOLE_BASE|" \
    -e "s|__ASG_COLLECTOR_TOKEN__|$TOKEN|" \
    "$SRC/dns-shadow-ai.service.tpl" > /etc/systemd/system/dns-shadow-ai.service
systemctl daemon-reload
systemctl enable dns-shadow-ai >/dev/null 2>&1 || true
systemctl restart dns-shadow-ai
sleep 2
systemctl is-active dns-shadow-ai
echo "dns-shadow-ai 已安装并启动 (token=$TOKEN)"
