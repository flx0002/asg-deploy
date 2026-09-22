#!/bin/bash
# build-release.sh: 在 amd64 构建机(156)上一次性产出 amd64 + arm64 两个「静态、可移植、带版本」的发布包
#
# 背景/约束（实测确认）：
#   - gopacket/afpacket 在 arm64 依赖 cgo 的 pageSize，CGO_ENABLED=0 无法编译 → 必须 CGO=1。
#   - 156 glibc(2.35) 比目标 80.19(2.28) 新，动态交叉产物在 80.19 会 GLIBC not found → 必须 -static。
#   - 因此 arm64 交叉用 aarch64-linux-gnu-gcc + CGO=1 + extldflags -static。
#
# 用法:  ./build-release.sh                 # 版本自动取 git describe/commit/UTC 时间
#        VERSION=v1.0.3 ./build-release.sh  # 显式指定版本号
# 产物:  dist/asg-bypass-guard-amd64  dist/asg-bypass-guard-arm64
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export PATH=/usr/local/go/bin:$PATH
export GOTOOLCHAIN=auto

VERSION=${VERSION:-$(git describe --tags --always 2>/dev/null || echo dev)}
COMMIT=${COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || echo none)}
BDATE=${BDATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
LDFLAGS="-s -w -X main.version=$VERSION -X main.commit=$COMMIT -X main.buildDate=$BDATE -linkmode external -extldflags \"-static\""

command -v go >/dev/null || { echo "缺 go"; exit 3; }
command -v aarch64-linux-gnu-gcc >/dev/null || {
  echo "缺 arm64 交叉工具链，先安装： apt-get install -y gcc-aarch64-linux-gnu libc6-dev-arm64-cross"
  exit 3
}

mkdir -p dist
echo "==> 版本 version=$VERSION commit=$COMMIT date=$BDATE"

echo "==> 构建 amd64 (本机)"
CGO_ENABLED=1 GOOS=linux GOARCH=amd64 \
  go build -trimpath -ldflags "$LDFLAGS" -o dist/asg-bypass-guard-amd64 .

echo "==> 构建 arm64 (交叉)"
CGO_ENABLED=1 GOOS=linux GOARCH=arm64 CC=aarch64-linux-gnu-gcc \
  go build -trimpath -ldflags "$LDFLAGS" -o dist/asg-bypass-guard-arm64 .

echo "==> 完成，产物："
ls -la dist
for b in dist/asg-bypass-guard-amd64 dist/asg-bypass-guard-arm64; do
  printf '%s : ' "$b"; file "$b" | sed 's/^[^:]*: //'
done
dist/asg-bypass-guard-amd64 -version
