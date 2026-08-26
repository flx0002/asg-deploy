# console 上游升级手册（ASG 解耦 4.8）

> 适用范围：AISecGw-console（higress-console fork）的上游同步/版本升级全流程。
> 配套仓库：asg-console-extension（后端扩展 + 前端注入/品牌重放）、asg-deploy（构建/部署资产）。
> 目标：按本手册完成一次模拟升级 ≤ 1 人日；升级全程遵守 merge-only 纪律（详见 fork 内 `UPSTREAM_MERGE.md`）。

---

## 1. 仓库拓扑与工具环境

| 项 | 位置 | 角色 |
| --- | --- | --- |
| AISecGw-console | `/home/wnt/ASG/AISecGw-console`（分支 main） | higress-console fork，定制面收敛（见 §3），**merge-only** |
| asg-console-extension | `/home/wnt/ASG/asg-console-extension` | 后端扩展（AutoConfiguration）+ 前端注入（inject.sh）+ 品牌重放（brand-apply.sh） |
| asg-deploy | `/home/wnt/ASG/asg-deploy` | helm chart（console/core/higress）+ Dockerfile + scripts（build-and-deploy.sh / deploy-all.sh） |
| mirror | `/home/wnt/higress-console` | 本地上游镜像仓库（GitHub 网络不稳时降级用） |
| upstream/main | fork 内 git remote | higress-group/higress-console 官方上游 |

工具版本（已验证）：JDK 11（宿主编译）、node 22（前端 ice build）、docker buildx（BUILDKIT）、kind/kubectl/helm、mvn 3（宿主）、python3。

---

## 2. 升级流程总览（Step 0-9）

```
0. 升级前检查 → 1. 备份 → 2. 获取上游 → 3. 冲突处置 → 4. 定制面核对
→ 5. 兼容性检查 → 6. 验证链（编译/前端/镜像） → 7. 部署 → 8. 集群回归 → 9. 收尾登记
```

---

## 3. 定制面清单与冲突处置对照表（升级时唯一保留/重放依据）

> 基准：`git diff --stat upstream/main...HEAD` 应恰好等于下表文件集（**18 文件**，2026-08-26 核验）。
> 规则：merge 冲突时按本表逐项处置；**禁止借冲突解决之机引入新的上游侵入**。

| # | 文件 | 处置规则 |
| --- | --- | --- |
| 1 | `backend/sdk/.../service/WasmPluginServiceImpl.java`（1 行 NPE 防御） | 保留 fork 侧 |
| 2 | `backend/console/.../resources/plugins/plugins.properties`（+3 行） | 保留 fork 侧（classloader 单资源限制，不可外置） |
| 3-8 | `plugins/ai-pii-guard/`（README×2 + spec.yaml）、`ai-prompt-guard/`（README×2 + spec.yaml）、`shadow-ai-detect/spec.yaml`、`key-auth/spec.yaml` | 保留 fork 侧（ASG 插件数据） |
| 9 | `backend/Dockerfile`（daocloud 镜像源 1 行 + 注释） | 冲突时取 fork 侧 FROM 行 + 上游其余内容（国内拉取必需） |
| 10 | `backend/console/pom.xml`（扩展依赖块 + node 22.22.2 / app.build.* / skip.frontend / caniuse / git 参数） | 冲突时逐块核对：扩展依赖 + 构建参数保留，其余随上游 |
| 11 | `.gitignore`（+1 行 i18n-check-results） | 保留 fork 侧 |
| 12 | `frontend/src/services/request.tsx`（401 修复 + 弹窗去重） | 保留 fork 侧；**上游若修复 401 需核对后回退** |
| 13 | `frontend/src/components/Footer/index.tsx`（版本号去 v 前缀，1 行） | 保留 fork 侧 |
| 14 | `frontend/ice.config.mts`（开发代理 1 行，仅开发模式） | 保留 fork 侧 |
| 15 | `UPSTREAM_MERGE.md`（本清单文档） | 随 fork 更新 |
| 16 | `.dockerignore`（fork 构建工具附属） | 随 fork 保留 |

> 品牌面（不在此清单，见 §5）：前端 20 文件 + `backend/console/src/main/resources/landing/index.html` + 6 资源 + locales 15 key×2，由 brand-apply.sh 重放，fork 内为上游原貌。

---

## 4. 升级流程细则

### Step 0 升级前检查

```bash
cd /home/wnt/ASG/AISecGw-console
git status --short                      # 必须干净
git fetch upstream                      # 网络可用性检查
# 若 GitHub fetch 失败（HTTP2 framing error 等）→ 用本地 mirror 降级：
git fetch mirror                        # mirror 需先更新：cd /home/wnt/higress-console && git fetch upstream
helm list -n higress-system             # 记录当前 REVISION（回滚基准）
kubectl get pods -n higress-system -l app.kubernetes.io/name=higress-console   # 记录当前镜像 ID
```

### Step 1 备份

```bash
git branch backup-pre-merge-$(date +%Y%m%d)
```

### Step 2 获取上游

```bash
git merge upstream/main                 # 或目标 tag：git merge upstream/<tag>
# merge 完成后记录：git log --oneline -3
```

### Step 3 冲突处置

按 §3 对照表逐项处理；处理完 `git add` 对应文件后继续 merge。
典型冲突场景与处置：
- `backend/Dockerfile`：上游改基础镜像版本 → 保留 daocloud FROM 行前缀，其余取上游；
- `backend/console/pom.xml`：上游改依赖版本 → 扩展依赖块（asg-console-extension）与构建参数行保留，其余取上游；
- `plugins/*/spec.yaml`：上游改内置插件 → ASG 插件整文件取 fork 侧。

### Step 4 定制面核对（硬断言）

```bash
git diff --stat upstream/main...HEAD | tail -22
# 期望：18 files changed（文件集合 = §3 表）；行数变化与登记一致
git status --short                      # 必须干净
```

### Step 5 上游兼容性检查

```bash
grep -n "ApiClient client" backend/sdk/src/main/java/com/alibaba/higress/sdk/service/kubernetes/KubernetesClientService.java
# UpstreamApiClientAccessor 依赖该字段（反射，实际声明 `private ApiClient client;`，见演练证据 s3e_e3_drill_out.txt 第 104 行），缺失则启动期报异常
```

### Step 6 验证链（必须全绿才可提交）

```bash
# 前置：切 JDK11（宿主默认 java 为 1.8，不切会报 InternalErrorException）
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
export PATH=$JAVA_HOME/bin:$PATH
M2SET=/home/wnt/ASG/asg-deploy/maven/settings.xml   # 阿里云镜像，依赖下载必需

# 6a. 扩展模块测试（含 UpstreamApiClientAccessor 反射兼容性单测）
cd /home/wnt/ASG/asg-console-extension && mvn -q test -s $M2SET

# 6b. console 后端全量编译（JDK11，约 23 分钟）
cd /home/wnt/ASG/AISecGw-console/backend
mvn -q compile -s $M2SET -Dpmd.skip=true -Dcheckstyle.skip=true -Dgpg.sign.skip=true -Dmaven.javadoc.skip=true

# 6c. 前端注入 + 品牌重放 + 前端构建（见 §5）
# 6d. 镜像构建（见 §5）
```

### Step 7 部署

```bash
cd /home/wnt/ASG/asg-deploy
IMAGE_TAG=V100R001C01B010 bash scripts/build-and-deploy.sh deploy
# = docker build（buildx 缓存）→ kind load → helm upgrade（chart=helm/higress）
# 镜像 tag 未变时 Deployment 不滚动 → 需显式重启：
kubectl rollout restart deployment/higress-console -n higress-system
kubectl rollout status deployment/higress-console -n higress-system --timeout=300s
```

### Step 8 集群回归清单

```bash
# 端口：28080（systemd asg-console-pf 常驻 port-forward；防火墙规则 asg-console-fw 开机自恢复）
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:28080/          # 期望 200
curl -s http://127.0.0.1:28080/system/info                                 # 期望 {"version":"V100R001C01B010",...}
# 登录（username 字段）：POST /session/login → 期望 201
# 接口回归：/v1/shadow-ai/status、/v1/agent-guard/sessions、/v1/behavior-analysis/stats、/v1/shadow-ai/detect-mode → 全部 200
# 品牌面：浏览器检查 footer 版本号无 v 前缀、logo/title 为 WntASG、登录页品牌、landing 页（/landing）品牌
# 错误日志：kubectl logs <pod> | grep -i error（无新增 ERROR）
```

### Step 9 收尾登记

```bash
# 1. UPSTREAM_MERGE.md：定制面清单变化（文件数/行数增减）必须更新
# 2. 验收台账登记（步骤→验收方法→验收结论→证据）
# 3. git push origin main（推送 fork 基线）
```

---

## 5. 品牌重放脚本（前端注入 + 品牌切换）

> 构建前置：镜像构建前必须执行注入+品牌+前端构建；**不执行 = 纯上游 Higress 界面**。

```bash
EXT=/home/wnt/ASG/asg-console-extension/frontend
CON=/home/wnt/ASG/AISecGw-console

# 1. 功能注入（扩展页面/菜单/services，幂等可重复）
bash $EXT/inject.sh $CON

# 2. 品牌重放（资源 6 + 补丁 21 文件[前端 20 + backend landing] + locales 15 key×2，幂等可重复）
bash $EXT/brand-apply.sh $CON

# 3. 前端构建（产物 frontend/build/，Dockerfile COPY 该目录）
cd $CON/frontend && npm run build        # ice build，约 10 分钟

# 4. 镜像构建（asg-deploy Dockerfile，自动检查扩展 jar/pom 与 maven settings）
cd /home/wnt/ASG/asg-deploy
IMAGE_TAG=V100R001C01B010 bash scripts/build-and-deploy.sh build
```

幂等验证：重跑 `bash $EXT/inject.sh $CON && bash $EXT/brand-apply.sh $CON` → 全部 SKIP/已应用提示。
回滚验证（演练实测）：
```bash
git checkout -- frontend/ backend/console/src/main/resources/landing/    # 恢复已跟踪文件
git clean -fd frontend/src frontend/public backend/console/src/main/resources/landing/   # 删除注入新增文件
```
（仅 checkout 会残留 19 个 inject 新增的 untracked 文件，必须配合 git clean。）

---

## 6. 回滚方案

| 场景 | 操作 |
| --- | --- |
| 部署后功能异常 | `helm rollback higress -n higress-system <上一REVISION>` |
| 代码层回退 | `git revert -m 1 <merge提交>` 或从 `backup-pre-merge-<date>` 分支恢复 |
| 镜像回退 | 重新构建上一版本镜像 + kind load + rollout restart（tag 复用） |

---

## 7. 模拟升级演练记录（2026-08-26）

> 演练目标：验证 §4 流程可执行、冲突处置规则有效、耗时 ≤ 1 人日。演练在隔离目录 `/tmp/upgrade-drill` 进行，不污染工作仓库与集群。

| 场景 | 步骤摘要 | 结果 | 耗时 |
| --- | --- | --- | --- |
| A. 无新上游提交 | fetch mirror + merge | **通过**：mirror/main 为 HEAD 祖先 → `Already up to date`（no-op，升级安全） | 0 分 |
| B. 上游有新提交（模拟） | 基于 upstream/main 造模拟提交 64c3cb3（bump Dockerfile FROM 行）→ merge 冲突（UU backend/Dockerfile）→ 按 §3 #11 处置（取 fork 侧）→ merge 276249e → Step4 核对 = 18 文件精确匹配 → Step5 `ApiClient client` 字段在位 → Step6a mvn test 0（含 UpstreamApiClientAccessorTest）→ Step6c inject(20)+brand(44) 重放：landing 品牌化 6 处、Footer 无 v、幂等 SKIP → Step6b JDK11 全量编译成功（278 class） | 25 分 |
| 合计 | 全流程 | **通过**：25 分 39 秒 ≤ 480 分钟（1 人日） | 25 分 39 秒 |

**演练发现并修正的问题**：
1. 品牌面遗漏：`backend/console/src/main/resources/landing/index.html` 硬编码品牌（提交 9e27ea3/e1981ed）未纳入 brand.patch → s3e 恢复上游 + 补丁补充（fork cde5ec6 / extension a860ce7），品牌面 100% 可重放；
2. 回滚仅 `git checkout` 会残留 inject 新增 untracked 文件（实测 19 个）→ 手册回滚命令补充 `git clean`（见 §5）。

（演练执行证据：`.remote_check/s3e_e3_drill_out.txt`）
