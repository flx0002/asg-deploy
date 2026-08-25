# asg-deploy（ASG 部署资产）

解耦开发阶段 4.7：部署资产独立仓库。**按本仓库可完整部署一套 ASG 环境**。

## 目录

| 路径 | 内容 |
|---|---|
| helm/console | ASG 自建 console chart（21 文件，version 2.2.2，含 asg env 注入块 + strategy 滚动更新段） |
| helm/core | 上游 higress core chart 2.2.4 + ASG 定制 3 文件（IR-076 HA：hostPort 仅单副本渲染、local/kind 多副本放开；configmap wasm 指标 stats_tags 打标） |
| helm/higress | 上游 higress chart 2.2.4 + 定制 2 文件（console 依赖指向本地 file://../console 2.2.2） |
| values/values-prod.yaml | 生产 values 模板（多副本/滚动更新/asg 配置） |
| dns-collector | DNS Shadow AI 采集器（collector.py + systemd 单元模板 + install.sh） |
| scripts/build-and-deploy.sh | console 镜像构建 + 部署（Dockerfile 在仓库根，构建上下文 = console 仓库） |
| scripts/deploy-all.sh | 一键完整部署（镜像 → helm → DNS → 冒烟回归） |
| Dockerfile | console 镜像多阶段构建（上下文 = AISecGw-console 仓库根，需先注入前端产物 frontend/build/） |

## 部署一套环境

```bash
# 前置：console 仓库已按 asg-console-extension/frontend 执行 inject.sh + brand-apply.sh 并完成 ice build
./scripts/deploy-all.sh
# 或分步：
./scripts/build-and-deploy.sh deploy
bash dns-collector/install.sh <collector-token>
```

## 与上游对齐（升级流程）

- helm/core、helm/higress 跟随上游 higress 2.2.4；升级时从上游重新同步整树后重放 ASG 定制：
  - core：`templates/_pod.tpl`（IR-076 HA）、`templates/configmap.yaml`（wasm stats 打标）、`templates/deployment.yaml`（多副本放开）
  - higress：`Chart.yaml` + `Chart.lock`（console 依赖指向本地 file://../console 2.2.2）
- helm/console 为 ASG 自建 chart（上游无），随 asg-console-extension 演进（asg env 注入块、strategy 段）。

## 品牌与前端注入

镜像构建前需在 console 仓库执行 asg-console-extension/frontend/inject.sh + brand-apply.sh 并完成前端构建（产出 frontend/build/）；不注入 = 纯上游 Higress 界面。
