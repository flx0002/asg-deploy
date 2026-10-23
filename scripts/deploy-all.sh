#!/usr/bin/env bash
# ASG 一键完整部署（asg-deploy, 4.7）
# 流程: ① console 镜像构建（需先执行 asg-console-extension inject.sh+brand-apply.sh 并 ice build）
#       ② kind load ③ helm upgrade（values-prod 模板） ④ DNS 采集器安装 ⑤ 冒烟回归
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="${NAMESPACE:-higress-system}"
TOKEN="${COLLECTOR_TOKEN:-wnt-asg-collector-2026}"
# 与 build-and-deploy.sh 保持同一镜像名/标签（export 以便子进程沿用）
export IMAGE_NAME="${IMAGE_NAME:-wntasg-console}"
export IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

echo "=== [1/5] 构建 console 镜像 ==="
bash "$SCRIPT_DIR/build-and-deploy.sh" build

echo "=== [2/5] kind load ==="
cluster_name=$(kubectl config current-context 2>/dev/null | sed 's/kind-//' || echo "")
if [ -n "${cluster_name}" ] && kind get clusters 2>/dev/null | grep -q "${cluster_name}"; then
    kind load docker-image "${FULL_IMAGE}" --name "${cluster_name}"
fi

echo "=== [3/5] helm upgrade（values-prod 模板，保留现网 values）==="
# 与 build-and-deploy.sh 同一机制：镜像内容 ID 写进 pod 模板 annotation，内容变才滚动。
# tag 恒 latest + pullPolicy=Never 时若不这样做，pod 模板永远不变，镜像换了也不滚动
# （同时 rollout status 会立刻判绿，看起来"部署成功"）。
image_id="$(docker image inspect --format '{{.Id}}' "${FULL_IMAGE}")"
echo "    image content id: ${image_id}"
helm dependency build "${DEPLOY_DIR}/helm/higress" >/dev/null
helm upgrade higress "${DEPLOY_DIR}/helm/higress" -n "${NAMESPACE}" \
    -f "${DEPLOY_DIR}/values/values-prod.yaml" \
    --set higress-console.image.repository="${IMAGE_NAME}" \
    --set higress-console.image.tag="${IMAGE_TAG}" \
    --set higress-console.image.pullPolicy=Never \
    --set-string higress-console.podAnnotations.asg-image-checksum="${image_id}" \
    --reuse-values
kubectl rollout status deployment/higress-console -n "${NAMESPACE}" --timeout=120s

echo "=== [4/5] DNS 采集器安装 ==="
bash "${DEPLOY_DIR}/dns-collector/install.sh" "${TOKEN}"

echo "=== [5/5] 冒烟回归 ==="
sleep 3
svc_ip=$(kubectl get svc higress-console -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}')
code=$(curl -s -o /dev/null -w '%{http_code}' "http://${svc_ip}:8080/" || true)
echo "首页 HTTP ${code}（期望 200）"
echo "=== deploy-all 完成 ==="
