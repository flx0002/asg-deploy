#!/usr/bin/env bash
# ============================================================
# upgrade.sh —— 【现场设备】ASG 版本升级（helm/k8s 标准升级，保留现场配置）
# ------------------------------------------------------------
# 前置 : 已解压升级包 asg-upgrade-<NEWVER>/ 并 cd 进入；ASG 集群已部署且健康
# 用法 : sudo bash upgrade.sh              # 正式升级
#        sudo bash upgrade.sh --dry-run    # 只打印动作 + helm --dry-run 预演，不改动系统
# 环境变量(默认=生产真实值，与 install.sh 一致)：
#        NS CLUSTER REG_NAME REG_PORT CONSOLE_PORT BYPASS_RUN BYPASS_SVC BYPASS_LOG
#        BACKUP_DIR(备份目录)  VERIFY_CHECKSUM=1(校验包 sha256)  CONSOLE_TOKEN(自动导出 .asgbak)
# ------------------------------------------------------------
# 设计原则：不自造升级引擎，全部复用 helm/k8s 标准件——
#   · helm upgrade --reuse-values  → 保留站点全部运行配置(gateway/redis/资源/console asg)，只 --set 版本
#   · --atomic --wait --cleanup-on-fail → 健康门禁 + 失败自动回滚
#   · Deployment RollingUpdate(25%/25%) → 零停机滚动
#   · WasmPlugin CR 仅 patch spec.url → 保留 Console 已配策略(绝不整表 apply 覆盖)
#   · Hibernate ddl-auto:update → schema 自动迁移
#   · 采集器只换二进制、保留现场 config.yaml
# ============================================================
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-higress-system}"
CLUSTER="${CLUSTER:-higress}"
REG_NAME="${REG_NAME:-local-registry}"
REG_PORT="${REG_PORT:-5000}"            # registry 宿主机映射端口(容器端口固定 5000)
CONSOLE_PORT="${CONSOLE_PORT:-30080}"
BYPASS_RUN="${BYPASS_RUN:-/opt/asg-bypass-guard}"
BYPASS_SVC="${BYPASS_SVC:-asg-bypass-guard}"
BYPASS_LOG="${BYPASS_LOG:-/var/log/bypass-guard.log}"
BACKUP_DIR="${BACKUP_DIR:-/opt/asg-upgrade-backup/$(date +%Y%m%d-%H%M%S)}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log(){ echo -e "\n\033[1;32m==>\033[0m $*"; }
warn(){ echo -e "  \033[1;33m! $*\033[0m"; }
run(){ if [ "$DRY_RUN" = 1 ]; then echo "  [dry-run] $*"; else eval "$@"; fi; }

# 读 Console /system/info 的版本号(公共端点，无需鉴权)；失败返回空
get_console_version(){
  curl -s --max-time 8 "http://127.0.0.1:$CONSOLE_PORT/system/info" 2>/dev/null \
    | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
    | sed -E 's/.*"([^"]*)"$/\1/'
}
# 当前 helm revision(helm v3/v4 通用，无需 python)
get_helm_rev(){
  helm history higress -n "$NS" -o json 2>/dev/null \
    | grep -oE '"revision"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | tail -1
}

OLDREV=""
on_err(){
  local code=$?
  echo -e "\n\033[1;31m========== 升级中断(exit=$code) ==========\033[0m"
  echo "  · helm 阶段失败：--atomic 已自动回滚到升级前 revision，无需手工干预"
  echo "  · 手工回滚 helm ：helm rollback higress ${OLDREV:-<上一revision>} -n $NS"
  echo "  · 备份目录      ：$BACKUP_DIR (wasmplugins.yaml / asg_security.sql / helm-values-all.yaml / OLDREV)"
  echo "  · 采集器异常    ：systemctl status $BYPASS_SVC ；旧二进制在 $BYPASS_RUN/asg-bypass-guard.bak"
  echo "  · Console 配置  ：如已导出 .asgbak，可在 Console「配置版本」页导入恢复"
}
trap on_err ERR

# ---------- [1/7] 预检 ----------
log "[1/7] 升级前预检(root/工具链/升级包/集群与 release/registry/版本)"
[ "$(id -u)" = 0 ] || { echo "!! 需 root 执行: sudo bash upgrade.sh"; exit 1; }
for c in docker kind kubectl helm curl; do
  command -v "$c" >/dev/null 2>&1 || { echo "!! 缺少命令 $c"; exit 1; }
done
# 升级包完整性(比全量离线包精简：无 kind-node/registry/CR 模板/mysql/kind-config)
for f in VERSION MANIFEST plugins.map images/pod-images.tar images/plugins.tar \
         asg-deploy/helm/higress/Chart.yaml asg-deploy/values/values-prod.yaml \
         bypass-guard/asg-bypass-guard upgrade.sh; do
  [ -e "$PKG_DIR/$f" ] || { echo "!! 升级包缺少 $f(请用 pack-upgrade.sh 重新制作)"; exit 1; }
done
NEWVER="$(cat "$PKG_DIR/VERSION")"
[ -n "$NEWVER" ] || { echo "!! VERSION 为空"; exit 1; }
# 可选：校验传输完整性(MANIFEST 内含各文件 sha256)
if [ "${VERIFY_CHECKSUM:-0}" = 1 ]; then
  ( cd "$PKG_DIR" && grep -vE '^#' MANIFEST | grep -E '^[0-9a-f]{64}  ' | sha256sum -c - ) \
    && echo "  sha256 校验通过" || { echo "!! sha256 校验失败(升级包可能在传输中损坏)"; exit 1; }
fi
# 集群与 release 必须已存在(升级而非首装)
kubectl config current-context >/dev/null 2>&1 || { echo "!! kubectl 未连接集群"; exit 1; }
kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || { echo "!! kind 集群 $CLUSTER 不存在(首装请用 install.sh)"; exit 1; }
helm status higress -n "$NS" >/dev/null 2>&1 || { echo "!! 未找到 helm release higress(首装请用 install.sh)"; exit 1; }
kubectl get ns "$NS" >/dev/null 2>&1 || { echo "!! 命名空间 $NS 不存在"; exit 1; }
# registry 探测(升级复用现有 registry 容器)
docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$REG_NAME" || { echo "!! registry 容器 $REG_NAME 不存在(升级复用现有 registry，请确认部署完整)"; exit 1; }
REG_IP=$(docker inspect "$REG_NAME" --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}')
[ -n "$REG_IP" ] || { echo "!! 无法获取 registry($REG_NAME) 的 kind 网络 IP"; exit 1; }
CURVER="$(get_console_version || true)"; [ -n "$CURVER" ] || CURVER="unknown"
OLDREV="$(get_helm_rev || true)"; [ -n "$OLDREV" ] || OLDREV="?"
echo "  当前 Console 版本 = $CURVER   helm revision = $OLDREV"
echo "  目标升级版本      = $NEWVER"
echo "  registry 集群内地址 = $REG_IP:$REG_PORT (插件镜像推送/CR url 渲染)"
[ "$CURVER" = "$NEWVER" ] && warn "目标版本与当前一致，仍将执行(可用于修复/重放)"
# helm 升级参数(真实升级与 dry-run 预演同参)：--reuse-values 保留站点配置 + --set 版本化 console tag
HELM_ARGS=(upgrade higress "$PKG_DIR/asg-deploy/helm/higress" -n "$NS"
  --reuse-values
  --set higress-console.image.repository=wntasg-console
  --set "higress-console.image.tag=$NEWVER"
  --set higress-console.image.pullPolicy=Never)
helm lint "$PKG_DIR/asg-deploy/helm/higress" >/dev/null 2>&1 && echo "  helm lint OK" || warn "helm lint 有告警(不阻断，以 --dry-run 为准)"
if [ "$DRY_RUN" = 0 ]; then
  echo "  执行 helm --dry-run 渲染预检..."
  helm "${HELM_ARGS[@]}" --dry-run >/dev/null || { echo "!! helm --dry-run 渲染失败，请检查 chart/依赖"; exit 1; }
  echo "  helm --dry-run 渲染 OK"
else
  echo "  [dry-run] helm ${HELM_ARGS[*]} --atomic --wait --cleanup-on-fail --timeout 10m"
fi

# ---------- [2/7] 备份(升级前安全网) ----------
log "[2/7] 升级前备份 → $BACKUP_DIR"
if [ "$DRY_RUN" = 0 ]; then
  mkdir -p "$BACKUP_DIR"
  helm history higress -n "$NS" > "$BACKUP_DIR/helm-history.txt" 2>&1 || true
  echo "$OLDREV" > "$BACKUP_DIR/OLDREV"
  # helm 全部运行配置(含站点 gateway/redis/资源/console asg)，回滚/审计依据
  helm get values higress -n "$NS" -a > "$BACKUP_DIR/helm-values-all.yaml" 2>/dev/null && echo "  已备份 helm values(-a) → helm-values-all.yaml" || warn "helm values 备份失败"
  # WasmPlugin CR 全量(含 Console 已配策略)
  kubectl get wasmplugin -n "$NS" -o yaml > "$BACKUP_DIR/wasmplugins.yaml" 2>/dev/null && echo "  已备份 WasmPlugin CR → wasmplugins.yaml" || warn "WasmPlugin CR 备份失败"
  # MySQL 全量 dump(用容器内 MYSQL_ROOT_PASSWORD 环境变量，无需外提 Secret)
  # 必须 -h127.0.0.1 强制 TCP：容器内 mysqld 不监听默认 unix socket(/var/run/mysqld/mysqld.sock)，
  # 否则报 error 2002 Can't connect ... through socket(与 asg-mysql.yaml readinessProbe 用 -h127.0.0.1 一致)
  if kubectl exec -n "$NS" deploy/asg-mysql -- sh -c 'mysqldump -h127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" --databases asg_security' \
       > "$BACKUP_DIR/asg_security.sql" 2>"$BACKUP_DIR/mysqldump.err"; then
    echo "  已备份 MySQL asg_security → asg_security.sql ($(du -h "$BACKUP_DIR/asg_security.sql" | cut -f1))"
  else
    warn "MySQL dump 失败(不阻断升级；详见 $BACKUP_DIR/mysqldump.err，可稍后手工备份)"
  fi
  # IR-028 整机配置 .asgbak：提供 CONSOLE_TOKEN 则自动导出，否则提示手工在 Console 导出
  if [ -n "${CONSOLE_TOKEN:-}" ]; then
    curl -s --max-time 20 -X POST "http://127.0.0.1:$CONSOLE_PORT/v1/config-version/backup/export" \
      -H "Authorization: Bearer $CONSOLE_TOKEN" -o "$BACKUP_DIR/console-config.asgbak" \
      && echo "  已调用 Console API 导出 .asgbak → console-config.asgbak" || warn ".asgbak API 导出失败(可在 Console UI 手动导出)"
  else
    echo "  ℹ️ 建议同时在 Console「配置版本」页导出整机 .asgbak 作为额外安全网(或设 CONSOLE_TOKEN 自动导出)"
  fi
  echo "  备份完成：$BACKUP_DIR   helm 回滚基准 revision=$OLDREV"
else
  echo "  [dry-run] 备份到 $BACKUP_DIR：helm-history/OLDREV + helm-values-all.yaml + wasmplugins.yaml + asg_security.sql(mysqldump) + .asgbak(提示/CONSOLE_TOKEN)"
fi

# ---------- [3/7] 离线镜像投递(气隙 glue 1) ----------
log "[3/7] 离线镜像投递(pod 镜像 kind load 进节点 + 插件镜像 push registry)"
if [ "$DRY_RUN" = 0 ]; then
  # 3a. 业务镜像(console/core/gateway 等) → docker load → kind load 进节点
  LOADED=$(docker load -i "$PKG_DIR/images/pod-images.tar" 2>/dev/null | sed -E 's/^Loaded image: //' || true)
  for img in $LOADED; do
    kind load docker-image "$img" --name "$CLUSTER" >/dev/null 2>&1 && echo "  loaded $img" || echo "  skip $img"
  done
  # 3b. 插件镜像 → docker load(保留打包时 127.0.0.1:5000 tag)
  docker load -i "$PKG_DIR/images/plugins.tar" >/dev/null 2>&1 || warn "plugins.tar load 异常"
else
  echo "  [dry-run] docker load pod-images.tar + kind load 进 $CLUSTER ；docker load plugins.tar"
fi
# 3c. 按 plugins.map 推插件镜像到 registry(与 install.sh [4] 同逻辑：REG_PORT≠5000 先 re-tag)
while read -r cr repo_tag; do
  [ -n "${repo_tag:-}" ] || continue
  if [ "$DRY_RUN" = 0 ]; then
    if [ "$REG_PORT" != "5000" ]; then
      docker tag "127.0.0.1:5000/$repo_tag" "127.0.0.1:$REG_PORT/$repo_tag"
    fi
    docker push "127.0.0.1:$REG_PORT/$repo_tag" >/dev/null 2>&1 && echo "  pushed $repo_tag" || warn "push $repo_tag 失败"
  else
    echo "  [dry-run] docker push 127.0.0.1:$REG_PORT/$repo_tag"
  fi
done < "$PKG_DIR/plugins.map"

# ---------- [4/7] helm 标准升级(核心) ----------
log "[4/7] helm 标准升级(--reuse-values 保留站点配置 + --atomic 失败自动回滚 + 滚动零停机)"
if [ "$DRY_RUN" = 0 ]; then
  helm "${HELM_ARGS[@]}" --atomic --wait --cleanup-on-fail --timeout 10m
  echo "  helm 升级完成：console → wntasg-console:$NEWVER (revision $(get_helm_rev || echo '?'))"
else
  echo "  [dry-run] helm ${HELM_ARGS[*]} --atomic --wait --cleanup-on-fail --timeout 10m"
fi

# ---------- [5/7] WasmPlugin CR spec.url 更新(保留 Console 策略) ----------
log "[5/7] 更新 WasmPlugin CR 的 spec.url(仅 url 字段，保留 Console 已配策略)"
while read -r cr repo_tag; do
  [ -n "${cr:-}" ] || continue
  new_url="oci://$REG_IP:5000/$repo_tag"   # CR url 用集群内 registry 端口 5000(非宿主机 REG_PORT)
  if [ "$DRY_RUN" = 0 ]; then
    kubectl get wasmplugin "$cr" -n "$NS" >/dev/null 2>&1 || { warn "CR $cr 不存在，跳过"; continue; }
    cur_url=$(kubectl get wasmplugin "$cr" -n "$NS" -o jsonpath='{.spec.url}')
    if [ "$cur_url" = "$new_url" ]; then
      echo "  = $cr url 未变($repo_tag)，跳过"
    else
      kubectl patch wasmplugin "$cr" -n "$NS" --type=merge -p "{\"spec\":{\"url\":\"$new_url\"}}" >/dev/null \
        && echo "  ↑ $cr: $cur_url → $new_url"
    fi
  else
    echo "  [dry-run] patch wasmplugin $cr spec.url → $new_url"
  fi
done < "$PKG_DIR/plugins.map"

# ---------- [6/7] 采集器二进制替换(气隙 glue 2，保留 config.yaml) ----------
log "[6/7] 升级旁路采集器二进制(保留现场 config.yaml)"
if [ "$DRY_RUN" = 0 ]; then
  if systemctl list-unit-files 2>/dev/null | grep -q "^$BYPASS_SVC\.service"; then
    systemctl stop "$BYPASS_SVC" 2>/dev/null || true
    if [ -f "$BYPASS_RUN/asg-bypass-guard" ]; then
      cp -f "$BYPASS_RUN/asg-bypass-guard" "$BYPASS_RUN/asg-bypass-guard.bak" && echo "  已备份旧二进制 → asg-bypass-guard.bak"
    fi
    cp -f "$PKG_DIR/bypass-guard/asg-bypass-guard" "$BYPASS_RUN/asg-bypass-guard"
    chmod +x "$BYPASS_RUN/asg-bypass-guard"
    # 保留现场 config.yaml(网卡/token/node_ip/本地策略)，不重渲染
    systemctl start "$BYPASS_SVC"
    sleep 3
    if systemctl is-active --quiet "$BYPASS_SVC"; then
      echo "  采集器已升级并运行(config.yaml 保留)  日志: $BYPASS_LOG"
    else
      warn "新采集器启动失败，自动回退旧二进制"
      if [ -f "$BYPASS_RUN/asg-bypass-guard.bak" ]; then
        cp -f "$BYPASS_RUN/asg-bypass-guard.bak" "$BYPASS_RUN/asg-bypass-guard" && chmod +x "$BYPASS_RUN/asg-bypass-guard"
        systemctl start "$BYPASS_SVC" 2>/dev/null || true
        systemctl is-active --quiet "$BYPASS_SVC" && echo "  已回退旧二进制并运行" || warn "回退后仍未运行，请 journalctl -u $BYPASS_SVC 排查"
      else
        warn "无旧二进制可回退，请手工处理"
      fi
    fi
  else
    warn "未找到采集器服务 $BYPASS_SVC(该站点可能未部署采集器)，跳过"
  fi
else
  echo "  [dry-run] stop $BYPASS_SVC → 备份旧二进制 → 换新二进制(保留 config.yaml) → start → 验证 active(失败自动回退 .bak)"
fi

# ---------- [7/7] 升级后校验 ----------
log "[7/7] 升级后校验(rollout / 版本 / 接口 / revision)"
if [ "$DRY_RUN" = 0 ]; then
  kubectl -n "$NS" rollout status deployment/higress-console --timeout=240s || warn "console rollout 超时(请 kubectl get pods -n $NS 排查)"
  kubectl -n "$NS" rollout status deployment/higress-gateway --timeout=240s || warn "gateway rollout 超时"
  sleep 3
  NEWRUNVER="$(get_console_version || true)"; [ -n "$NEWRUNVER" ] || NEWRUNVER="unknown"
  c1=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:$CONSOLE_PORT/" || true)
  echo "  Console /system/info version = $NEWRUNVER (期望 $NEWVER)"
  echo "  Console http://127.0.0.1:$CONSOLE_PORT/ → HTTP $c1 (期望 200)"
  [ "$NEWRUNVER" = "$NEWVER" ] && echo "  ✓ 版本已更新到 $NEWVER" || warn "运行版本($NEWRUNVER)与目标($NEWVER)不一致，请核查"
  echo "  当前 helm revision = $(get_helm_rev || echo '?')  (升级前=$OLDREV)"
  echo "  采集器状态：systemctl status $BYPASS_SVC"
fi

echo -e "\n\033[1;32m========== ASG 升级完成 → $NEWVER ==========\033[0m"
echo "  Console 管理台 : http://$(hostname -I 2>/dev/null | awk '{print $1}'):$CONSOLE_PORT"
echo "  备份目录       : $BACKUP_DIR (如需回滚)"
echo "  回滚 helm      : helm rollback higress ${OLDREV} -n $NS"
