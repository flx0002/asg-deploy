#!/usr/bin/env bash
# ============================================================
# install.sh —— 【现场设备】ASG 一键离线部署
# ------------------------------------------------------------
# 前置 : 已解压离线包并 cd 进 asg-offline/；已装 docker/kind/kubectl/helm(见手册第二章)
# 用法 : sudo bash install.sh            # 正式部署
#        sudo bash install.sh --dry-run  # 只打印将执行的动作，不改动系统(用于评审/预演)
# 特性 : registry 地址 / 节点IP / 抓包网卡 全部运行时自动探测渲染，适配任意现场网段
# ============================================================
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 所有部署标识均可用环境变量覆盖；默认值 = 生产真实值，保证 `sudo bash install.sh`(无参)行为完全不变。
# 隔离验证场景(如现网已有同名生产集群)可传入独立值避开冲突。
# ⚠️ 硬性要求：隔离验证必须【同时】改 REG_NAME + REG_PORT。只改端口不改 REG_NAME，
#    [3] 的 `docker ps | grep -qx $REG_NAME` 会判定"已存在"而复用生产 registry，
#    [4] 随即把离线包插件镜像 push 进生产 registry(版本不同即覆盖生产镜像)。
#    独立 CLUSTER 自带独立 apiserver/etcd，NS 与集群内资源天然隔离，无需改 NS。
# 例(完整隔离)：
#   sudo env CLUSTER=asg-verify REG_NAME=local-registry-verify REG_PORT=5001 \
#        GW_HTTP_PORT=8080 GW_HTTPS_PORT=8443 CONSOLE_PORT=30081 \
#        BYPASS_RUN=/opt/verify-bypass-guard BYPASS_SVC=asg-bypass-guard-verify \
#        BYPASS_LOG=/var/log/verify-bypass-guard.log bash install.sh
NS="${NS:-higress-system}"
CLUSTER="${CLUSTER:-higress}"
REG_NAME="${REG_NAME:-local-registry}"
# registry 宿主机映射端口(容器端口固定 5000)：默认生产值；隔离验证须连同 REG_NAME 一起改
REG_PORT="${REG_PORT:-5000}"
# 宿主机端口映射(kind extraPortMappings)：默认生产值；隔离验证时改空闲端口避免与既有集群冲突
GW_HTTP_PORT="${GW_HTTP_PORT:-80}"
GW_HTTPS_PORT="${GW_HTTPS_PORT:-443}"
CONSOLE_PORT="${CONSOLE_PORT:-30080}"
# bypass-guard 运行目录/服务名/日志：默认生产值；隔离验证时改独立值避免覆盖生产采集器
BYPASS_RUN="${BYPASS_RUN:-/opt/asg-bypass-guard}"
BYPASS_SVC="${BYPASS_SVC:-asg-bypass-guard}"
BYPASS_LOG="${BYPASS_LOG:-/var/log/bypass-guard.log}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log(){ echo -e "\n\033[1;32m==>\033[0m $*"; }
run(){ if [ "$DRY_RUN" = 1 ]; then echo "  [dry-run] $*"; else eval "$@"; fi; }

# ---------- [0] 前置检查 ----------
log "[0/11] 前置检查(root/工具链/离线包完整性)"
[ "$(id -u)" = 0 ] || { echo "!! 需 root 执行: sudo bash install.sh"; exit 1; }
for c in docker kind kubectl helm curl; do
  command -v "$c" >/dev/null 2>&1 || { echo "!! 缺少命令 $c，请先安装工具链(手册第二章)"; exit 1; }
done
for f in images/kind-node.tar images/registry.tar images/pod-images.tar images/plugins.tar \
         manifests/kind-config.yaml manifests/asg-mysql.yaml manifests/secret-mysql.json \
         manifests/mcpbridge-redis.yaml \
         asg-deploy/helm/higress/Chart.yaml asg-deploy/values/values-prod.yaml \
         bypass-guard/asg-bypass-guard bypass-guard/config.yaml.tpl bypass-guard/asg-bypass-guard.service; do
  [ -e "$PKG_DIR/$f" ] || { echo "!! 离线包缺少 $f(请用 pack-offline.sh 重新打包)"; exit 1; }
done
ldconfig -p 2>/dev/null | grep -q libpcap || echo "  ! 警告: 未检测到 libpcap，bypass-guard 可能无法启动(Debian/Ubuntu: apt install libpcap0.8；RHEL/银河麒麟: yum install libpcap)"
# cgroup v2 前置检查：kind + kindest/node v1.31(systemd cgroup driver) 要求宿主机 cgroup v2(unified)。
# cgroup v1 下 kubelet 建不出 kubelet.slice/kubelet-kubepods.slice 而崩溃 → [2] "API server is not healthy" 超时(约4m)后才失败，
# 极难定位。银河麒麟 Kylin V10/内核4.19 默认 cgroup v1；amd64 生产基线(内核6.x)默认已是 v2，故本检查对 amd64 零影响。
CGTYPE="$(stat -fc %T /sys/fs/cgroup/ 2>/dev/null || echo unknown)"
if [ "$CGTYPE" != "cgroup2fs" ]; then
  if [ "${ASG_SKIP_CGROUP_CHECK:-0}" = 1 ]; then
    echo "  ! 警告: 宿主机 cgroup=$CGTYPE(非 v2)，已按 ASG_SKIP_CGROUP_CHECK=1 跳过检查，[2] 建集群可能失败"
  else
    echo "!! 宿主机 cgroup 为 v1/hybrid($CGTYPE)，kind 建集群会失败(kubelet cgroup 崩溃 → API server 超时约4m)。"
    echo "   需切换 cgroup v2 后重试：在 /etc/default/grub 的 GRUB_CMDLINE_LINUX 追加 systemd.unified_cgroup_hierarchy=1，"
    echo "   再 grub2-mkconfig -o /boot/efi/EFI/<发行版>/grub.cfg (或 /boot/grub2/grub.cfg) 并 reboot。详见手册《arm64/银河麒麟》与 FAQ。"
    echo "   (确知环境无此问题可设 ASG_SKIP_CGROUP_CHECK=1 跳过本检查)"
    exit 1
  fi
else
  echo "  cgroup v2(unified) ✓"
fi
echo "  离线包完整，版本: $(cat "$PKG_DIR/VERSION" 2>/dev/null || echo unknown)"

# ---------- [1] 导入基础镜像到宿主机 docker ----------
log "[1/11] docker load 基础镜像(kind节点/registry/插件)"
for t in kind-node registry plugins; do
  run "docker load -i '$PKG_DIR/images/$t.tar' >/dev/null"
done

# ---------- [2] 创建 kind 集群 ----------
log "[2/11] 创建 kind 集群 ($CLUSTER)"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "  集群 $CLUSTER 已存在，跳过创建"
elif [ "$DRY_RUN" = 1 ]; then
  echo "  [dry-run] kind create cluster --name $CLUSTER (渲染 kind-config: name=$CLUSTER, hostPort 80->$GW_HTTP_PORT/443->$GW_HTTPS_PORT/30080->$CONSOLE_PORT)"
else
  # 渲染 kind-config：集群名 + 宿主机端口映射参数化(避免与既有集群端口冲突)；containerPort 不变
  # ⚠️ 首个 -e 必须先去 CRLF 的 \r：kind-config.yaml 在仓库里可能是 CRLF，行尾锚点 $ 在 CRLF 下
  #    匹配的是 \r → hostPort: NN$ 全部静默不匹配(不报错)，只有 name 行因 .* 吞掉 \r 而生效。
  #    (pack-offline.sh [8b] 会把包内文件转 LF，但手工拼包/直接复用仓库 manifests 仍是 CRLF)
  KC="$(mktemp)"
  sed -e "s/\r$//" \
      -e "s/^name: .*/name: $CLUSTER/" \
      -e "s/hostPort: 80$/hostPort: $GW_HTTP_PORT/" \
      -e "s/hostPort: 443$/hostPort: $GW_HTTPS_PORT/" \
      -e "s/hostPort: 30080$/hostPort: $CONSOLE_PORT/" \
      "$PKG_DIR/manifests/kind-config.yaml" > "$KC"
  kind create cluster --name "$CLUSTER" --config "$KC"
  rm -f "$KC"
fi

# ---------- [3] 启动私有 registry + 探测 REG_IP ----------
log "[3/11] 启动私有 registry(供网关拉取 wasm 插件)"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$REG_NAME"; then
  echo "  registry 容器已存在，复用"
else
  run "docker run -d --restart=always --network kind -p 127.0.0.1:$REG_PORT:5000 --name $REG_NAME registry:2 >/dev/null"
fi
if [ "$DRY_RUN" = 0 ]; then
  sleep 2
  REG_IP=$(docker inspect "$REG_NAME" --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}')
  [ -n "$REG_IP" ] || { echo "!! 无法获取 registry 的 kind 网络 IP"; exit 1; }
else REG_IP="__REG_IP__"; fi
echo "  registry 集群内地址 = $REG_IP:5000 (将渲染进 WasmPlugin CR)"

# ---------- [4] 推送插件镜像到 registry(精确按 CR 引用) ----------
log "[4/11] 推送 7 个自研插件镜像到 registry"
for f in "$PKG_DIR"/manifests/wasmplugins/*.json; do
  repo_tag=$(grep -o 'oci://__REGISTRY__:5000/[^"]*' "$f" | head -1 | sed 's#oci://__REGISTRY__:5000/##')
  [ -n "$repo_tag" ] || continue
  # plugins.tar 内镜像 tag 由 pack-offline.sh 按 REG_HOST=127.0.0.1:5000 写死(容器端口恒 5000)；
  # docker push 只推本地已存在的 tag，REG_PORT≠5000 时本地无 127.0.0.1:$REG_PORT/* → push 必报
  # image does not exist locally。故 REG_PORT≠5000 时先从 :5000 re-tag 到 :$REG_PORT 再推
  # (REG_PORT=5000 默认路径不 re-tag，与改动前完全一致，零回归)。
  if [ "$REG_PORT" != "5000" ]; then
    run "docker tag '127.0.0.1:5000/$repo_tag' '127.0.0.1:$REG_PORT/$repo_tag'"
  fi
  run "docker push '127.0.0.1:$REG_PORT/$repo_tag' >/dev/null && echo \"  pushed $repo_tag\""
done

# ---------- [5] 导入并 kind load 业务镜像进节点 ----------
log "[5/11] kind load 业务镜像(higress栈/mysql/console)进集群节点"
if [ "$DRY_RUN" = 0 ]; then
  LOADED=$(docker load -i "$PKG_DIR/images/pod-images.tar" 2>/dev/null | sed -E 's/^Loaded image: //' || true)
  for img in $LOADED; do
    kind load docker-image "$img" --name "$CLUSTER" >/dev/null 2>&1 && echo "  loaded $img" || echo "  skip $img"
  done
else echo "  [dry-run] docker load pod-images.tar + kind load 进节点"; fi

# ---------- [6] 部署 MySQL 数据层 + Console Secret ----------
log "[6/11] 部署 MySQL + Console 数据库 Secret"
# 先确保 namespace 存在：asg-mysql.yaml / secret-mysql.json 均写死 namespace=$NS，
# 而 $NS 要到第7步 helm --create-namespace 才创建；全新机器此处不先建，apply 必报 NotFound 并被 set -e 中断
run "kubectl create namespace '$NS' --dry-run=client -o yaml | kubectl apply -f -"
run "kubectl apply -f '$PKG_DIR/manifests/asg-mysql.yaml'"
run "kubectl apply -f '$PKG_DIR/manifests/secret-mysql.json'"
run "kubectl -n '$NS' rollout status deployment/asg-mysql --timeout=180s"

# ---------- [7] helm 部署 higress(console+core+gateway) ----------
log "[7/11] helm 部署 higress 网关栈"
run "helm upgrade --install higress '$PKG_DIR/asg-deploy/helm/higress' -n '$NS' --create-namespace -f '$PKG_DIR/asg-deploy/values/values-prod.yaml'"

# ---------- [8] 等待核心 pod 就绪 + 初始化 Console admin ----------
log "[8/11] 等待核心 pod 就绪"
run "kubectl -n '$NS' rollout status deployment/higress-console --timeout=240s"
run "kubectl -n '$NS' rollout status deployment/higress-gateway --timeout=240s"
# Console 首次初始化(幂等)：全新安装的 higress-console secret 无 admin 配置，
# 未初始化时 /session/login 报 "No valid admin config is available"。此处设 admin/admin123。
# 已初始化(重装/复用集群)时 /system/init 返回非 2xx，脚本不中断(set -e 下用 || true 兜底)。
if [ "$DRY_RUN" = 0 ]; then
  sleep 3
  INIT_RESP=$(curl -s -m 20 -X POST "http://127.0.0.1:$CONSOLE_PORT/system/init" \
    -H 'Content-Type: application/json' \
    -d '{"adminUser":{"name":"admin","displayName":"Admin","password":"admin123"}}' \
    -w '\n%{http_code}' 2>/dev/null || true)
  INIT_CODE=$(printf '%s' "$INIT_RESP" | tail -1)
  case "$INIT_CODE" in
    200|201) echo "  Console admin 初始化成功(账号 admin / admin123)" ;;
    *)       echo "  Console 初始化返回 HTTP ${INIT_CODE:-000}(通常表示已初始化，跳过)" ;;
  esac
else
  echo "  [dry-run] POST http://127.0.0.1:$CONSOLE_PORT/system/init 设置 admin/admin123(幂等)"
fi

# ---------- [9] 渲染 + apply 自研 WasmPlugin CR ----------
log "[9/11] 部署 7 个自研 WasmPlugin(动态渲染 registry 地址)"
# 先注册集群内 redis 服务源(McpBridge)：ai-quota/ai-token-billing/ai-agent-guard 依赖
# redis-stack-server.internal.dns，缺失则网关插件反复报 "failed to init redis: bad argument"。
run "sed 's/higress-system/$NS/g' '$PKG_DIR/manifests/mcpbridge-redis.yaml' | kubectl apply -f -"
if [ "$DRY_RUN" = 0 ]; then
  TMP=$(mktemp -d)
  for f in "$PKG_DIR"/manifests/wasmplugins/*.json; do
    b=$(basename "$f")
    sed "s/__REGISTRY__/$REG_IP/g" "$f" > "$TMP/$b"
    kubectl apply -f "$TMP/$b" && echo "  applied $b"
  done
  rm -rf "$TMP"
else echo "  [dry-run] sed __REGISTRY__->$REG_IP 渲染 7 个 CR 并 kubectl apply"; fi

# ---------- [10] 部署 bypass-guard 旁路采集器(数据面) ----------
log "[10/11] 部署 bypass-guard 旁路采集器"
if [ "$DRY_RUN" = 0 ]; then
  NODE_IP=$(docker inspect "$CLUSTER-control-plane" --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}')
  IFACE=$(ip route show default | awk '/default/{print $5; exit}')
  mkdir -p "$BYPASS_RUN"
  cp "$PKG_DIR/bypass-guard/asg-bypass-guard" "$BYPASS_RUN/"
  chmod +x "$BYPASS_RUN/asg-bypass-guard"
  sed -e "s/__NODE_IP__/$NODE_IP/g" -e "s/__IFACE__/$IFACE/g" \
      "$PKG_DIR/bypass-guard/config.yaml.tpl" > "$BYPASS_RUN/config.yaml"
  # 渲染 service：运行目录/日志路径参数化(模板内写死的即生产默认路径)
  sed -e "s#/opt/asg-bypass-guard#$BYPASS_RUN#g" -e "s#/var/log/bypass-guard.log#$BYPASS_LOG#g" \
      "$PKG_DIR/bypass-guard/asg-bypass-guard.service" > "/etc/systemd/system/$BYPASS_SVC.service"
  systemctl daemon-reload && systemctl enable "$BYPASS_SVC" >/dev/null 2>&1 && systemctl restart "$BYPASS_SVC"
  echo "  节点IP=$NODE_IP  抓包网卡=$IFACE  Console(集群内NodePort)=http://$NODE_IP:30080  运行目录=$BYPASS_RUN  服务=$BYPASS_SVC"
  echo "  ! 若旁路镜像口非 $IFACE，请改 $BYPASS_RUN/config.yaml 的 interface 后 systemctl restart $BYPASS_SVC"
else echo "  [dry-run] 探测 NODE_IP/IFACE -> 渲染 config -> $BYPASS_RUN + systemd($BYPASS_SVC)"; fi

# ---------- [11] 冒烟验证 ----------
log "[11/11] 冒烟验证"
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ "$DRY_RUN" = 0 ]; then
  sleep 5
  echo "  --- Pod ---"; kubectl get pods -n "$NS" --no-headers | awk '{print "    "$1"  "$2"  "$3}'
  echo "  --- WasmPlugin ---"; kubectl get wasmplugin -n "$NS" --no-headers | awk '{print "    "$1}' | head -20
  c1=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$CONSOLE_PORT/" || true)
  c2=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$GW_HTTP_PORT/" || true)
  echo "  Console http://$HOST_IP:$CONSOLE_PORT -> HTTP $c1 (期望 200)"
  echo "  网关    http://$HOST_IP:$GW_HTTP_PORT       -> HTTP $c2"
fi
echo -e "\n\033[1;32m========== ASG 部署完成 ==========\033[0m"
echo "  Console 管理台 : http://$HOST_IP:$CONSOLE_PORT   (账号 admin / admin123)"
echo "  网关入口       : http://$HOST_IP:$GW_HTTP_PORT  |  https://$HOST_IP:$GW_HTTPS_PORT"
echo "  私有 registry  : $REG_IP:5000 (集群内插件拉取)"
echo "  旁路采集器     : systemctl status $BYPASS_SVC"

