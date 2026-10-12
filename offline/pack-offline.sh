#!/usr/bin/env bash
# ============================================================
# pack-offline.sh —— 【构建机】从当前已部署环境制作 ASG 离线部署包
# ------------------------------------------------------------
# 产物 : asg-offline-<VERSION>-<ARCH>.tar.gz（ARCH=amd64/arm64，按构建机 uname -m；现场只需此包，无需源码/公网）
# 依赖 : docker, kubectl(已连现网集群), go, python3, tar
# 用法 : bash pack-offline.sh [VERSION]
# 说明 : 本脚本在"构建机"(即当前已跑通的环境)执行一次，只读导出+编译，
#        不改动现网。产出的离线包拷到现场新硬件，执行 install.sh 即可。
# ============================================================
set -euo pipefail

VERSION="${1:-V100R001C01B010}"
# 架构后缀：产物包名区分 amd64/arm64，避免跨架构误用（在 arm64 构建机跑天然产 arm64 包）
ARCH="$(uname -m)"; case "$ARCH" in x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; esac
PKGNAME="asg-offline-${VERSION}-${ARCH}.tar.gz"
WORK="${WORK:-/tmp/asg-offline-build}"
PKG="$WORK/asg-offline"
NS=higress-system
REG_HOST=127.0.0.1:5000                 # 现网 registry 宿主机视图(push/pull)
# helm/values 来源；默认=生产权威路径，可用 env 覆盖指向 GitHub 克隆(源码构建验证场景)
DEPLOY_SRC="${DEPLOY_SRC:-/home/wnt/ASG/asg-deploy}"
# 源码权威(asg-deploy 内)；config 模板为 config.yaml.example
BYPASS_SRC="${BYPASS_SRC:-$DEPLOY_SRC/bypass-guard}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 7 个自研插件的 WasmPlugin CR 名（url 版本从 CR 动态解析，不写死）
PLUGIN_CRS=(ai-agent-guard ai-pii-guard ai-prompt-guard ai-quota ai-shadow-detect ai-token-billing key-auth.internal)

echo "########## [0] 依赖与环境检查 ##########"
for c in docker kubectl go python3 tar; do
  command -v "$c" >/dev/null 2>&1 || { echo "!! 缺少命令: $c"; exit 1; }
done
kubectl get ns "$NS" >/dev/null 2>&1 || { echo "!! kubectl 未连接到含 $NS 命名空间的集群"; exit 1; }
[ -d "$DEPLOY_SRC/helm" ] || { echo "!! 未找到 $DEPLOY_SRC/helm"; exit 1; }
[ -f "$BYPASS_SRC/config.yaml.example" ] || { echo "!! 未找到 $BYPASS_SRC/config.yaml.example"; exit 1; }

echo "########## [1] 准备包目录 ##########"
rm -rf "$WORK"
mkdir -p "$PKG"/{images,manifests/wasmplugins,bypass-guard,asg-deploy}

echo "########## [2] 导出集群 Pod 镜像(排除 kind 内置) ##########"
# registry.k8s.io/* 与 kindest/* 已随 kindest/node 镜像内置，无需单独导出
mapfile -t POD_IMGS < <(kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sort -u | grep -vE '^registry\.k8s\.io/|/kindest/|^kindest/' || true)
echo "待导出 pod 镜像 ${#POD_IMGS[@]} 个:"; printf '  - %s\n' "${POD_IMGS[@]}"
for img in "${POD_IMGS[@]}"; do
  docker image inspect "$img" >/dev/null 2>&1 || docker pull "$img"
done
docker save "${POD_IMGS[@]}" -o "$PKG/images/pod-images.tar"

echo "########## [3] 导出 kind 节点镜像 + registry:2 ##########"
docker image inspect kindest/node:v1.31.0 >/dev/null 2>&1 || docker pull kindest/node:v1.31.0
docker save kindest/node:v1.31.0 -o "$PKG/images/kind-node.tar"
docker image inspect registry:2 >/dev/null 2>&1 || docker pull registry:2
docker save registry:2 -o "$PKG/images/registry.tar"

echo "########## [4] 从现网 registry 导出 7 个自研插件镜像 ##########"
PLUGIN_REFS=()
for cr in "${PLUGIN_CRS[@]}"; do
  url=$(kubectl get wasmplugin "$cr" -n "$NS" -o jsonpath='{.spec.url}')
  repo_tag="${url#oci://*/}"            # oci://IP:5000/plugins/x:t -> plugins/x:t（#最短前缀，剔到 host:port 后首个 /）
  ref="$REG_HOST/$repo_tag"             # 127.0.0.1:5000/plugins/x:t
  echo "  $cr -> $ref"
  docker pull "$ref" >/dev/null
  PLUGIN_REFS+=("$ref")
done
docker save "${PLUGIN_REFS[@]}" -o "$PKG/images/plugins.tar"

echo "########## [5] 导出 7 个自研 WasmPlugin CR 模板(url 占位符化) ##########"
# 清理 metadata 冗余(creationTimestamp/uid/managedFields/last-applied...)，
# 并把 oci://<IP>:5000 替换为 oci://__REGISTRY__:5000，install.sh 现场再渲染为实际 IP
# 自研插件按 custom 归一化(见下 python 块)：强制 wasm-plugin-built-in=false 且
# wasm-plugin-name=CR 名，防止源集群 CR 标签漂移(如被误标 built-in=true/旧名)被固化进离线包，
# 导致目标环境 console 走内置目录查不到插件而 createEmptyInstance 抛 "Plugin not found"。
# 注意：判据用显式自研集合，不能用 ai- 前缀——ai-quota 是 Higress 官方内置插件(仅镜像到本地
# registry)，key-auth.internal 是官方内置实例，二者必须保持原样不被改成 custom。
for cr in "${PLUGIN_CRS[@]}"; do
  kubectl get wasmplugin "$cr" -n "$NS" -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
cr=sys.argv[1]
m=d.get("metadata",{})
for k in ("creationTimestamp","resourceVersion","uid","generation","managedFields","selfLink"):
    m.pop(k,None)
ann=m.get("annotations") or {}
ann.pop("kubectl.kubernetes.io/last-applied-configuration",None)
if ann: m["annotations"]=ann
else: m.pop("annotations",None)
d.pop("status",None)
# 仅对显式自研集合归一化为 custom；ai-quota / key-auth.internal 等 Higress 官方内置保持原样
ASG_SELF_DEV={"ai-agent-guard","ai-pii-guard","ai-prompt-guard","ai-shadow-detect","ai-token-billing"}
if cr in ASG_SELF_DEV:
    labels=m.setdefault("labels",{})
    labels["higress.io/wasm-plugin-built-in"]="false"
    labels["higress.io/wasm-plugin-name"]=cr
sys.stdout.write(json.dumps(d,ensure_ascii=False))
' "$cr" | sed -E 's#oci://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:5000/#oci://__REGISTRY__:5000/#g' \
    > "$PKG/manifests/wasmplugins/${cr}.json"
  printf '  %-22s %s\n' "${cr}.json" "$(grep -o 'oci://__REGISTRY__:5000/[^"]*' "$PKG/manifests/wasmplugins/${cr}.json" | head -1)"
done

echo "########## [5b] 导出 Console 的 MySQL Secret(asg-console-mysql) ##########"
# values-prod.yaml 的 asg.mysql.secretName 引用它；忠实导出结构(data 含演示口令，生产应改 Secret)
kubectl get secret asg-console-mysql -n "$NS" -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
m=d.get("metadata",{})
for k in ("creationTimestamp","resourceVersion","uid","managedFields","selfLink","ownerReferences"):
    m.pop(k,None)
ann=m.get("annotations") or {}
ann.pop("kubectl.kubernetes.io/last-applied-configuration",None)
if ann: m["annotations"]=ann
else: m.pop("annotations",None)
sys.stdout.write(json.dumps(d,ensure_ascii=False))
' > "$PKG/manifests/secret-mysql.json"
echo "  data keys: $(python3 -c "import json;print(' '.join(json.load(open('$PKG/manifests/secret-mysql.json')).get('data',{}).keys()))")"

echo "########## [6] 编译 bypass-guard 二进制 + 模板化配置 ##########"
cd "$BYPASS_SRC"
# 本机(与构建机同架构)编译，含 libpcap(cgo)；注入 version/commit/buildDate 与 deploy.sh 一致，便于部署后核验产物来源
_BCOMMIT=$(git -C "$BYPASS_SRC" rev-parse --short HEAD 2>/dev/null || echo dev)
_BDATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
go build -trimpath -ldflags "-s -w -X main.version=$_BCOMMIT -X main.commit=$_BCOMMIT -X main.buildDate=$_BDATE" -o "$PKG/bypass-guard/asg-bypass-guard" .
# service 已指向 /opt/asg-bypass-guard(源码权威 B 内)，直接复制
cp asg-bypass-guard.service "$PKG/bypass-guard/asg-bypass-guard.service"
# config.yaml.example 已是占位符模板(__NODE_IP__/__IFACE__)，直接作 tpl；install.sh 现场渲染
cp config.yaml.example "$PKG/bypass-guard/config.yaml.tpl"
echo "  二进制: $(du -h "$PKG/bypass-guard/asg-bypass-guard" | cut -f1)"

echo "########## [7] 复制 asg-deploy(仅 helm+values) ##########"
# 不含 dns-collector(已下线)、不含 bypass-guard 源码(改用预编译二进制)、不含构建脚本
cp -r "$DEPLOY_SRC/helm"   "$PKG/asg-deploy/"
cp -r "$DEPLOY_SRC/values" "$PKG/asg-deploy/"
# 补齐父 chart 的子依赖：higress 的 Chart.yaml 以 file://../core、file://../console 声明子图，
# 而打包产物 helm/higress/charts/*.tgz 被 .gitignore 排除(源码克隆后 charts/ 为空)。
# 若不在此处 build，现场 install.sh 的 `helm upgrade --install` 会报
# "found in Chart.yaml, but missing in charts/ directory: higress-core, higress-console" 而失败。
# file:// 为本地相对依赖，helm dependency build 全程离线，无需公网仓库。
if command -v helm >/dev/null 2>&1; then
  ( cd "$PKG/asg-deploy/helm/higress" && helm dependency build >/dev/null ) \
    && echo "  helm dependency build OK: $(ls "$PKG/asg-deploy/helm/higress/charts"/*.tgz 2>/dev/null | xargs -n1 basename | tr '\n' ' ')" \
    || echo "  ! helm dependency build 失败：若源已有 charts/*.tgz 可忽略，否则现场安装会缺子图"
else
  echo "  ! 构建机未装 helm，跳过 dependency build；请确保 $DEPLOY_SRC/helm/higress/charts/*.tgz 已预先存在"
fi

echo "########## [8] 放置 install.sh + manifests + VERSION ##########"
cp "$SCRIPT_DIR/install.sh"                    "$PKG/"
cp "$SCRIPT_DIR/manifests/kind-config.yaml"    "$PKG/manifests/"
cp "$SCRIPT_DIR/manifests/asg-mysql.yaml"      "$PKG/manifests/"
cp "$SCRIPT_DIR/manifests/mcpbridge-redis.yaml" "$PKG/manifests/"
echo "$VERSION" > "$PKG/VERSION"

echo "########## [8b] 规范化包内文本行尾(源文件可能含 Windows CRLF) ##########"
# 关键: install.sh/manifests 若在 Windows 编辑会带 \r，现场 bash/kubectl 会报错，统一转 LF
find "$PKG" -type f \( -name '*.sh' -o -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.tpl' -o -name '*.service' \) -exec sed -i 's/\r$//' {} +

echo "########## [9] 打包 ##########"
cd "$WORK"
tar czf "$PKGNAME" asg-offline
echo "=================================================="
echo "产出 : $WORK/$PKGNAME"
du -h "$PKGNAME"
echo "包内结构:"; find asg-offline -maxdepth 2 -type d | sort | sed 's/^/  /'
echo "现场部署: tar xzf $PKGNAME && cd asg-offline && sudo bash install.sh"
echo "DONE_PACK"

