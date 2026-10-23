#!/usr/bin/env bash
# WntASG Console - Build and Deploy Script（asg-deploy 版, 4.7）
# 用法: ./build-and-deploy.sh [command]
#   build   - 构建 Docker 镜像（默认；Dockerfile = asg-deploy/Dockerfile，构建上下文 = console 仓库）
#   deploy  - 构建镜像 + kind load + helm upgrade + 按镜像内容滚动（chart = asg-deploy/helm/higress）
#   clean   - 删除本地镜像
# 环境变量: CONSOLE_DIR（console 仓库路径，默认 /home/wnt/ASG/AISecGw-console）
#           IMAGE_NAME / IMAGE_TAG / NAMESPACE
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONSOLE_DIR="${CONSOLE_DIR:-/home/wnt/ASG/AISecGw-console}"
IMAGE_NAME="${IMAGE_NAME:-wntasg-console}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
NAMESPACE="${NAMESPACE:-higress-system}"

build_image() {
    echo "=== Building WntASG Console image: ${FULL_IMAGE} ==="
    echo "    Dockerfile : ${DEPLOY_DIR}/Dockerfile"
    echo "    Build ctx  : ${CONSOLE_DIR}（.dockerignore 取自该目录）"
    # 注入 maven 镜像源 settings + ASG 扩展 jar（构建上下文 = console 仓库根，临时复制、用后即删）
    EXT_JAR="${EXT_JAR:-/root/.m2/repository/com/asg/asg-console-extension/0.0.1-SNAPSHOT/asg-console-extension-0.0.1-SNAPSHOT.jar}"
    EXT_POM="$(dirname "${EXT_JAR}")/asg-console-extension-0.0.1-SNAPSHOT.pom"
    [ -f "${EXT_JAR}" ] && [ -f "${EXT_POM}" ] || { echo "!! 缺少 asg-console-extension jar/pom（需先构建安装 asg-console-extension 仓库）"; exit 1; }
    cp "${DEPLOY_DIR}/maven/settings.xml" "${CONSOLE_DIR}/.asg-settings.xml"
    cp "${EXT_JAR}" "${CONSOLE_DIR}/.asg-console-extension.jar"
    cp "${EXT_POM}" "${CONSOLE_DIR}/.asg-console-extension.pom"
    trap 'rm -f "${CONSOLE_DIR}/.asg-settings.xml" "${CONSOLE_DIR}/.asg-console-extension.jar" "${CONSOLE_DIR}/.asg-console-extension.pom"' EXIT
    export DOCKER_BUILDKIT=1
    docker build -t "${FULL_IMAGE}" -f "${DEPLOY_DIR}/Dockerfile" "${CONSOLE_DIR}"
    echo "=== Build complete: ${FULL_IMAGE} ==="
}

print_live_image_ids() {
    # 只打印未在删除中的 pod（<none> = 没有 deletionTimestamp）
    kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=higress-console \
        -o custom-columns=NAME:.metadata.name,DELETING:.metadata.deletionTimestamp,IMAGE:.status.containerStatuses[0].imageID \
        --no-headers | awk '$2 == "<none>" { printf "%s -> %s\n", $1, $3 }'
}

deploy_to_k8s() {
    build_image
    local cluster_name
    cluster_name=$(kubectl config current-context 2>/dev/null | sed 's/kind-//' || echo "")
    if [ -n "${cluster_name}" ] && kind get clusters 2>/dev/null | grep -q "${cluster_name}"; then
        echo "=== Loading image into kind cluster: ${cluster_name} ==="
        kind load docker-image "${FULL_IMAGE}" --name "${cluster_name}"
    fi
    echo "=== Updating Helm release (chart: ${DEPLOY_DIR}/helm/higress) ==="
    # 把镜像内容 ID 写进 pod 模板 annotation：镜像内容变则模板变、自动滚动；
    # 镜像没变则模板不变、不重启。tag 恒 latest + pullPolicy=Never 时，
    # 不这样做 pod 模板永远不变，helm 会判"无更新"，容器一直跑旧镜像。
    local image_id
    image_id="$(docker image inspect --format '{{.Id}}' "${FULL_IMAGE}")"
    echo "    image content id: ${image_id}"
    helm dependency build "${DEPLOY_DIR}/helm/higress" >/dev/null
    helm upgrade higress "${DEPLOY_DIR}/helm/higress" \
        -n "${NAMESPACE}" \
        --set higress-console.image.repository="${IMAGE_NAME}" \
        --set higress-console.image.tag="${IMAGE_TAG}" \
        --set higress-console.image.pullPolicy=Never \
        --set-string higress-console.podAnnotations.asg-image-checksum="${image_id}" \
        --reuse-values
    # 只有 annotation 变化才会触发滚动；未变化时这里立即返回成功，不动 pod。
    echo "=== Waiting for rollout (仅镜像内容变化时才会滚动) ==="
    if ! kubectl rollout status deployment/higress-console -n "${NAMESPACE}" --timeout=180s; then
        echo "!! Rollout 未在 180s 内完成，当前仍在运行的镜像:"
        print_live_image_ids
        exit 1
    fi
    echo "=== Effective imageID: 判断是否真上线的唯一依据 ==="
    print_live_image_ids
    echo "=== Deploy complete ==="
    echo "Access console: kubectl port-forward -n ${NAMESPACE} svc/higress-console 8080:8080"
}

clean_image() {
    echo "=== Removing image: ${FULL_IMAGE} ==="
    docker rmi "${FULL_IMAGE}" 2>/dev/null || echo "Image not found locally"
}

case "${1:-build}" in
    build)      build_image ;;
    deploy|all) deploy_to_k8s ;;
    clean)      clean_image ;;
    *)          echo "Usage: $0 {build|deploy|all|clean}"; exit 1 ;;
esac
