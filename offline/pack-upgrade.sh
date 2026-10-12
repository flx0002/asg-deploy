#!/usr/bin/env bash
# ============================================================
# pack-upgrade.sh —— 【构建机】制作 ASG 版本升级包（精简版离线包）
# ------------------------------------------------------------
# 产物 : asg-upgrade-<NEWVER>.tar.gz（现场 upgrade.sh 消费）
# 依赖 : docker, kubectl(已连现网集群), go, tar, sha256sum
# 用法 : bash pack-upgrade.sh <NEWVER>          # 如 V100R001C01B011
# 前置 : 构建机已用新版本部署 —— 必须先执行：
#          IMAGE_TAG=<NEWVER> bash /home/wnt/ASG/asg-deploy/scripts/build-and-deploy.sh deploy
#        确保 docker 内存在 wntasg-console:<NEWVER>（版本化 tag，升级才能触发滚动更新）。
# 说明 : 相比 pack-offline.sh，本包【不含】kind-node/registry 镜像、WasmPlugin CR 模板、
#        mysql/kind-config（升级复用现有集群与现场配置）；额外产出 plugins.map + MANIFEST。
#        只读导出 + 编译，不改动现网。
# ============================================================
set -euo pipefail

NEWVER="${1:-}"
[ -n "$NEWVER" ] || { echo "!! 用法: bash pack-upgrade.sh <NEWVER>  (如 V100R001C01B011)"; exit 1; }
WORK="${WORK:-/tmp/asg-upgrade-build}"
PKG="$WORK/asg-upgrade"
NS=higress-system
REG_HOST=127.0.0.1:5000                 # 现网 registry 宿主机视图(push/pull)
DEPLOY_SRC=/home/wnt/ASG/asg-deploy     # helm/values 来源
BYPASS_SRC=/home/wnt/ASG/asg-deploy/bypass-guard  # 采集器源码权威
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONSOLE_IMAGE="wntasg-console:$NEWVER"

# 7 个自研插件的 WasmPlugin CR 名（url 版本从 CR 动态解析，不写死）
PLUGIN_CRS=(ai-agent-guard ai-pii-guard ai-prompt-guard ai-quota ai-shadow-detect ai-token-billing key-auth.internal)

echo "########## [0] 依赖与前置检查 ##########"
for c in docker kubectl go tar sha256sum; do
  command -v "$c" >/dev/null 2>&1 || { echo "!! 缺少命令: $c"; exit 1; }
done
kubectl get ns "$NS" >/dev/null 2>&1 || { echo "!! kubectl 未连接到含 $NS 命名空间的集群"; exit 1; }
[ -d "$DEPLOY_SRC/helm" ] || { echo "!! 未找到 $DEPLOY_SRC/helm"; exit 1; }
[ -f "$BYPASS_SRC/config.yaml.example" ] || { echo "!! 未找到 $BYPASS_SRC/config.yaml.example"; exit 1; }
[ -f "$SCRIPT_DIR/upgrade.sh" ] || { echo "!! 未找到同目录 upgrade.sh（升级包需内含）"; exit 1; }
# 关键前置：构建机必须已构建版本化 console 镜像，否则升级包无法触发滚动更新
docker image inspect "$CONSOLE_IMAGE" >/dev/null 2>&1 || {
  echo "!! 未找到镜像 $CONSOLE_IMAGE";
  echo "   请先执行: IMAGE_TAG=$NEWVER bash $DEPLOY_SRC/scripts/build-and-deploy.sh deploy";
  exit 1; }
RUN_CONSOLE=$(kubectl get deploy higress-console -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
echo "  目标 console 镜像 = $CONSOLE_IMAGE"
echo "  构建机当前运行    = ${RUN_CONSOLE:-未知}"
[ "$RUN_CONSOLE" = "$CONSOLE_IMAGE" ] || echo "  ! 注意：构建机运行的 console 非 $CONSOLE_IMAGE；pod-images.tar 会同时导出运行中镜像与 $CONSOLE_IMAGE"

echo "########## [1] 准备包目录 ##########"
rm -rf "$WORK"
mkdir -p "$PKG"/{images,bypass-guard,asg-deploy}

echo "########## [2] 导出集群 Pod 镜像(排除 kind 内置；确保含 $CONSOLE_IMAGE) ##########"
# registry.k8s.io/* 与 kindest/* 已随 kindest/node 内置，无需导出
mapfile -t POD_IMGS < <(kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sort -u | grep -vE '^registry\.k8s\.io/|/kindest/|^kindest/' || true)
# 即便运行中的是 latest，也强制带上目标版本化镜像（升级 --set tag=$NEWVER 需要它）
if ! printf '%s\n' "${POD_IMGS[@]}" | grep -qx "$CONSOLE_IMAGE"; then
  POD_IMGS+=("$CONSOLE_IMAGE")
fi
echo "待导出 pod 镜像 ${#POD_IMGS[@]} 个:"; printf '  - %s\n' "${POD_IMGS[@]}"
for img in "${POD_IMGS[@]}"; do
  docker image inspect "$img" >/dev/null 2>&1 || docker pull "$img" || { echo "!! 无法获取镜像 $img"; exit 1; }
done
docker save "${POD_IMGS[@]}" -o "$PKG/images/pod-images.tar"

echo "########## [3] 导出 7 个自研插件镜像 + 生成 plugins.map ##########"
# plugins.map 每行: <CR名> <repo:tag>；供现场 upgrade.sh 推镜像 + patch CR 的 spec.url
PLUGIN_REFS=(); : > "$PKG/plugins.map"
for cr in "${PLUGIN_CRS[@]}"; do
  url=$(kubectl get wasmplugin "$cr" -n "$NS" -o jsonpath='{.spec.url}')
  repo_tag="${url#oci://*/}"            # oci://IP:5000/plugins/x:t -> plugins/x:t（#最短前缀，剔到 host:port 后首个 /）
  ref="$REG_HOST/$repo_tag"             # 127.0.0.1:5000/plugins/x:t
  echo "  $cr -> $ref"
  docker image inspect "$ref" >/dev/null 2>&1 || docker pull "$ref" >/dev/null || { echo "!! 插件镜像缺失 $ref"; exit 1; }
  PLUGIN_REFS+=("$ref")
  echo "$cr $repo_tag" >> "$PKG/plugins.map"
done
docker save "${PLUGIN_REFS[@]}" -o "$PKG/images/plugins.tar"

echo "########## [4] 编译 bypass-guard 二进制(linux/amd64, 含 libpcap cgo) ##########"
cd "$BYPASS_SRC"
go build -o "$PKG/bypass-guard/asg-bypass-guard" .
echo "  二进制: $(du -h "$PKG/bypass-guard/asg-bypass-guard" | cut -f1)"

echo "########## [5] 复制 helm chart + values(注入版本化 console tag) ##########"
cp -r "$DEPLOY_SRC/helm"   "$PKG/asg-deploy/"
cp -r "$DEPLOY_SRC/values" "$PKG/asg-deploy/"
# 包内 values-prod.yaml 的 console tag 渲染为目标版本(自文档化 + 供 operator 手动 -f 全量重放时使用)；
# upgrade.sh 默认走 --reuse-values --set tag=$NEWVER，不 -f 此文件，避免重置站点其它运行配置。
sed -i -E "s/^([[:space:]]*)tag:[[:space:]]*latest[[:space:]]*$/\1tag: $NEWVER/" "$PKG/asg-deploy/values/values-prod.yaml" || true
echo "  values-prod.yaml console tag:"; grep -nE '^[[:space:]]*tag:' "$PKG/asg-deploy/values/values-prod.yaml" | sed 's/^/    /'

echo "########## [6] 放置 upgrade.sh + VERSION ##########"
cp "$SCRIPT_DIR/upgrade.sh" "$PKG/"
echo "$NEWVER" > "$PKG/VERSION"

echo "########## [7] 规范化包内文本行尾(CRLF→LF) ##########"
find "$PKG" -type f \( -name '*.sh' -o -name '*.yaml' -o -name '*.yml' -o -name '*.map' \) -exec sed -i 's/\r$//' {} +

echo "########## [8] 生成 MANIFEST(版本元数据 + 各文件 sha256) ##########"
cd "$PKG"
{
  echo "# ASG 升级包清单"
  echo "NEWVER=$NEWVER"
  echo "CONSOLE_IMAGE=$CONSOLE_IMAGE"
  echo "BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "BUILT_FROM_CLUSTER=$(kubectl config current-context 2>/dev/null || echo unknown)"
  echo "# --- sha256(供现场 VERIFY_CHECKSUM=1 校验传输完整性) ---"
  find . -type f ! -name MANIFEST -print0 | xargs -0 sha256sum | sort -k2
} > MANIFEST

echo "########## [9] 打包 ##########"
cd "$WORK"
tar czf "asg-upgrade-${NEWVER}.tar.gz" asg-upgrade
echo "=================================================="
echo "产出 : $WORK/asg-upgrade-${NEWVER}.tar.gz"
du -h "asg-upgrade-${NEWVER}.tar.gz"
echo "包内结构:"; find asg-upgrade -maxdepth 2 | sort | sed 's/^/  /'
echo "现场升级: tar xzf asg-upgrade-${NEWVER}.tar.gz && cd asg-upgrade && sudo bash upgrade.sh"
echo "DONE_PACK_UPGRADE"
