# upstream-builder 可行性评审

**项目名：** upstream-builder（原文档标题里的 "go-upstream-builder" 已按此更名）
**评审对象：** `go-upstream-builder-开发落地计划.md`（1230 行）
**被测上游：** `Hxjcc/cline-pass-switcher-go`、`luawei1/cline2api`
**运行环境：** GitHub Actions（本评审不依赖本地编译，下文所有实测只用于验证「配置是否写对」）
**结论日期：** 2026-10-02

---

## 一、总体结论

**能落地，机械流程已全部跑通；但方案文档有 4 处结构性缺陷，不改会在第一周就踩到。**

分三个等级：

| 部分 | 判定 | 说明 |
|---|---|---|
| 拉源码 / 构建 / 推 GHCR / 发 Release 的机械流程 | ✅ 已验证可行 | 两个真实上游用上游 Dockerfile 均构建成功，镜像可启动 |
| 配置驱动 + 增量 + 失败隔离的骨架 | ✅ 可实现 | 但 `build.type` 分类法在多语言下会崩，见 §3.5 |
| 「上游源码放在管理仓库根目录」 | ❌ 有实测缺陷 | `.gitignore` / `.gitattributes` / `.github` 按同步顺序互相污染，见 §3.1 |
| 「构建 Job 不持有发布凭据」 | ⚠️ 与方案自身冲突 | `go test`、`npm ci`、Dockerfile `RUN` 都是执行上游代码，见 §3.2 |
| 「上游不止 Go，还有 Python」 | ⚠️ 需要重构 | 需要 language × method 两轴 + 能力标志，见 §3.5 |

---

## 二、实测结果（这些是环境无关的配置验证）

用两个上游的**真实源码快照**原样构建，不做任何修改：

### 2.1 模式 B（上游 Dockerfile）——完全可行

| 上游 | ref | 结果 | 耗时 | 镜像大小 | 启动检查 |
|---|---|---|---|---|---|
| `luawei1/cline2api` | tag `v1.6.4` | ✅ 成功 | 121s | 29.6 MB | `GET /health` → **200** |
| `Hxjcc/cline-pass-switcher-go` | branch `main` | ✅ 成功 | 183s | 29.3 MB | `GET /` → **403** |

两个 Dockerfile 都**不需要改一行**就能构建。计划书「优先使用上游已有 Dockerfile」这条判断是正确的。

> **注意 cps 的 403：** 计划书 §6.2 第 5 步「运行基础镜像检查」如果按「`curl -f /` 返回 200」实现，**cps 会永远判定失败**——它的控制台需要鉴权，未登录访问返回 403。
> `healthcheck.path` 和期望状态码必须按项目配置，不能由平台猜。

> **关于注册表：** 发布目标只用 **GHCR**（`ghcr.io/<owner>/<project>`），评审全文按此假设。
> 唯一与其它注册表有关的地方是**构建输入**：上游 Dockerfile 的 `FROM golang:1.26-alpine` / `node:24-alpine` / `alpine:3.22` 默认从 Docker Hub 拉取。
> 模式 B「不修改上游 Dockerfile」意味着这一步绕不开；如果构建环境不允许访问 Docker Hub，就必须加一层 base image 重写/镜像代理，那属于**改写上游 Dockerfile**，需要在报告里显式记录。

### 2.2 模式 A（Go 直接编译）——计划书的示例配置是错的

| 检查项 | 结果 |
|---|---|
| cline2api：`CGO_ENABLED=0 go build .` | ✅ 成功（`main.go` 有 `//go:build !desktop`，wails/CGO 不参与服务端构建） |
| cline2api：`go test ./...` | ✅ 通过（`ok cline-go-proxy 2.742s`） |
| cps：按计划书示例的 `package: "."` 构建 | ❌ **失败：`no Go files in /src`** |
| cps：`package: "./cmd/cline-pass-switcher"` | ✅ 成功 |
| cps：交叉编译 `linux/amd64`、`linux/arm64`、`windows/amd64` | ✅ 全部成功 |
| cline2api：交叉编译 `linux/arm64` | ✅ 成功 |

**结论：** 计划书 §6.1 的示例里 `"workdir": "cline-pass-switcher-go"` + `"package": "."` 两个值对这个仓库都是错的——cps 的入口是 `./cmd/cline-pass-switcher`，且源码按新方案不再放子目录。这类错误只能靠**第一次真跑**发现，所以「先跑通两个真实项目再加第三个」这条实施原则是对的。

### 2.3 上游的两个行为特征（决定调度策略）

| | `Hxjcc/cline-pass-switcher-go` | `luawei1/cline2api` |
|---|---|---|
| tag / release | **0 个 tag，0 个 release** | 14 个 tag / 11 个 release，最新 `v1.6.4` |
| 提交频率 | 每天 1～13 次（10-02 当天 10 分钟内 3 次） | 每天 2～12 次 |
| 源码体积（解压） | 3.0 MB | 824 KB |
| 构建依赖 | Go 1.25 + **Node 24 / npm ci / vite**（前端嵌进二进制） | Go 1.26（go.mod 写 1.25.0，Dockerfile 用 `golang:1.26-alpine`，两者都存在） |

**两个直接影响：**

1. **「上游无变化就跳过」对 cps 基本无效。** 它每天都有提交，日内多次。按计划书 §10.1 的增量逻辑，cps 会**几乎每天都重建**，而 cps 是四架构 + `npm ci` + `vite build` 的贵项目。
   → 必须加**按项目的节流**（`min_interval`，例如 cps 每天最多建一次），而不是「有变化就建」。
2. **cps 永远发不出正式 Release。** 计划书 §8.4 写「默认不创建上游没有对应版本依据的正式版本」，而 cps 没有任何 tag。
   → `release.tag_strategy` 必须显式化：`upstream-tag`（cline2api）/ `sha` / `rolling-prerelease`（cps）。否则这条规则直接否掉了项目 A 的 Release 功能。

---

## 三、必须修的 4 处设计缺陷

### 3.1 【严重·已实测】上游源码放仓库根目录 → git 元数据互相污染

计划书 §三 要求「上游项目直接放在管理仓库根目录，不创建 upstream/ 源码目录」。**这一条会坏，原因是 Git 的 `.gitignore` 语义。**

两个上游都在**仓库根目录**自带 `.gitignore`：

- `luawei1/cline2api` 的 `.gitignore` 末尾有 `*_test.go`、`*.test`（它的仓库策略就是「测试文件只在本地跑，不提交」）
- `Hxjcc/cline-pass-switcher-go` 的 `.gitignore` 会忽略 `config.json`、`data/`、`*.log`、`.env*`、`web/node_modules/`

而 `.gitignore` 的作用域是**它所在的目录及其所有子目录**。一个仓库根目录只能有一份 `.gitignore`，于是：

**实测（模拟两个项目按顺序同步到根目录）：**

```
磁盘上 cline2api 根级 *_test.go：14 个
磁盘上全部 *_test.go：81 个

同步顺序 = cline2api 然后 cps → cps 的 .gitignore 覆盖了 cline2api 的
git add -A 后 tracked *_test.go：81 个（全部提交）
```

反过来先同步 cps 再同步 cline2api，`*_test.go` 就会**全局生效**，cps 的 67 个测试文件**静默消失**。

**后果比「少几个文件」严重得多：**

1. **结果依赖同步顺序，不确定。** 谁最后同步谁说了算。
2. **`go test` 变成空跑。** 计划书 §6.1 第 4 步「执行 `go test`，前提是项目测试可运行」——测试文件被 gitignore 掉之后，`go test ./...` 依然**返回成功**，只是什么都没测。这是最危险的一种失败：静默通过。
3. **构建输入被静默篡改。** 上游还有 `.gitattributes`（cps 有 `*.sh text eol=lf`）同样冲突。上游的 `.github/workflows/ci.yml`（两个仓库都有）如果落到根目录，会变成**管理仓库自己的 workflow**，被触发、消耗额度、可能直接失败。
4. 计划书 §4.3 说「禁止删除管理仓库自身的 `.github/`、`scripts/`…」，所以你必须把上游的 `.github` 剔除——但剔除之后，你构建的源码快照**已经不等于上游源码**了，而 snapshot 里没有任何东西记录这个差异。

**实测修法（推荐）：快照放 `vendor/<name>/` 命名空间下。**

```
磁盘上 cline2api *_test.go：14 → tracked：0   （它自己的 .gitignore 生效，符合上游策略）
磁盘上 cps *_test.go：67      → tracked：67  （不受 cline2api 影响）
```

嵌套的 `.gitignore` 只作用于自己的子目录，两个项目各按自己的策略处理，**零冲突、结果确定**。
骨架采用的就是这个布局（`vendor/<name>/`），并在提交时用 `git add -f`，让快照严格等于上游 tar.gz 的内容。

**三种选择：**

| 方案 | 优点 | 代价 |
|---|---|---|
| **A. `vendor/<name>/` 命名空间**（本项目采用） | 修掉全部冲突；保留快照可审计 | 推翻计划书 §一.1/§一.2 的「根目录」要求 |
| **B. 不落库**：按 SHA 现场下载 → 同一次 workflow 内构建 → state 只记 SHA | 彻底消灭 gitignore 冲突、路径穿越、仓库膨胀；provenance 更强（`(repo, sha)` 可直接复现） | 仓库里看不到源码；需要一个 state 文件记录已构建 SHA |
| **C. 坚持根目录** | 不改文档 | 必须同步时剔除上游 `.gitignore`/`.gitattributes`/`.github`，由平台维护唯一根 `.gitignore`，并在报告里显式记录「构建输入已被改写」 |

> 本项目按「源码要落库」的要求采用 **A（`vendor/<name>/`）**，并额外做了三件事让 A 也安全：
> 提交用 `git add -f`（快照等于 tar.gz 内容，不受上游 `.gitignore` 影响）、
> 剔除上游 `.github/`（避免其 workflow 在本仓库被执行，并在 `UPSTREAM.json` 里记录 `stripped`）、
> 以及把上游 ref 与 `tree_sha256` 写进 `UPSTREAM.json`（构建输入的任何改写都可见）。
> **B（`layout: "none"`）仍然保留为一个配置项**，两种布局下构建脚本完全一致。

### 3.2 【中高】「构建 Job 不持有发布凭据」与方案自身冲突

计划书 §12.1 写「禁止自动执行上游提供的安装脚本或任意代码」——**这条按字面无法实现**，因为：

- 模式 B（上游 Dockerfile）的 `RUN` 指令**就是**上游代码（cline2api 的 Dockerfile 里 `go mod download`、`go build`）
- 模式 A 的 `go test` **执行**上游测试代码 = 执行任意代码
- 前端构建 `npm ci` 会执行依赖包的 `postinstall` 脚本
- 模式 D 的 custom 脚本更不用说

所以正确的表述不是「不执行上游代码」，而是**「执行上游代码的 Job 不持有写权限」**。计划书 §7.4 已经提出了「构建 Job / 验证 Job / 发布 Job 拆分」，但 §9.2 又把 11 个步骤写成一个 workflow 的连续步骤——**两节互相矛盾，必须以 §7.4 为准重写 §9.2。**

具体约束：

- **Job 级 `permissions`**，不是 workflow 级：跑上游代码的 Job 只能 `contents: read`
- 产物经 `actions/upload-artifact` 传递，**发布 Job 不重跑构建**
- 镜像跨 Job 传递只有两条干净路径：
  - **OCI archive**：构建 Job `docker buildx build --output type=oci,dest=img.tar`（多架构会产出 image index），发布 Job 用 `skopeo copy oci-archive:img.tar docker://ghcr.io/...` 推送。发布 Job 完全不接触上游代码。
  - **staging tag + 晋升**：构建 Job 推到不可变 `sha-xxxxxxx` staging tag，验证通过后发布 Job 用 `docker buildx imagetools create -t ghcr.io/x:latest ghcr.io/x:sha-xxxxxxx` 把 `latest` 指过去。**这是计划书 §7.2 第 3 条「`latest` 只在构建与检查成功后更新」唯一可靠的实现方式**——`latest` 指向的是已验证的 digest，不是重新构建的产物。

### 3.3 【中】GitHub Actions 层面的具体坑（计划书没写，但会直接卡住）

以下几条都会直接卡住流程，社区与 Actions 文档都已确认：

| 问题 | 后果 | 修法 |
|---|---|---|
| **`GITHUB_TOKEN` push 不触发其他 workflow** | sync 提交后 build.yml **不会自动跑**，计划书 §9.1 已提到但没给解法 | 显式 `gh workflow run build.yml`，**并且需要 `actions: write`**——计划书 §7.4 的权限清单漏了这条 |
| **buildx 默认产出 provenance attestation** | GHCR 上出现 `unknown/unknown` 架构条目，下游 digest 漂移 | `provenance: false`（+ `sbom: false`）。社区已确认这是标准修法 |
| **GHCR 新 package 默认 private** | 计划书 §7.5「应明确设置或检查其可见性」但**不能可靠自动化**：用户级 package 用 PAT 改可见性可以，组织级 API 有限制 | 写成「一次性人工步骤 + 在报告里记录期望可见性」 |
| **`actions/cache` / `type=gha` 缓存 10GB 上限 + 会被驱逐**；gha cache scope 绑定分支，PR 里读不到主分支缓存 | 缓存不命中时构建时间翻倍 | 缓存键必须含 lockfile 哈希（`go.sum` / `package-lock.json` / Python 的 `requirements.txt` 或 `uv.lock`） |
| **schedule 在整点严重排队** | 定时任务延迟数十分钟 | 避开整点（骨架用 `17 3 * * *`） |
| **`concurrency` 用错会杀掉正在发布的 Job** | 发布中途被取消 → 半成品 | 构建用 `group: build-${{ matrix.project }}` + `cancel-in-progress: false`（排队而不是取消） |
| **matrix 部分失败** | 计划书要求「不能把部分失败伪装成全部成功」 | `fail-fast: false` + 汇总 Job 用 `needs` + `if: always()` 显式判定并 `exit 1` |

### 3.4 【中】arm64 多架构：Actions 上怎么选（这是你问的重点）

计划书默认每个项目都要 `linux/amd64` + `linux/arm64`。在 GitHub Actions 上有两条路，**必须按语言分开选**：

| 路径 | 适用 | 代价 |
|---|---|---|
| **交叉编译 + buildx 组装 manifest list** | **Go / Rust**（`cross_compile = true`） | 最快。前端等架构无关产物在 amd64 runner 上构建一次，Go 用 `GOARCH=arm64` 出二进制 |
| **QEMU 模拟**（`docker/setup-qemu-action`） | 兜底 | 慢；`npm ci` / `vite build` 在 QEMU 下尤其慢且容易 OOM。**cps 这种带前端构建的项目不建议走 QEMU** |
| **原生 arm64 runner** `ubuntu-24.04-arm` | **Python / Node**（`cross_compile = false`，必须原生） | ⚠️ **仅公共仓库免费可用，私有仓库加了该 label 会直接失败** |

**对 cps 的具体建议：** 不要在 arm64 上重跑前端构建。前端产物（`internal/webassets/dist/`）是架构无关的——在 amd64 runner 上构建一次，用 artifact 传给两个架构的 Go 交叉编译 Job，再用 `imagetools create` 合成 manifest list。这比 QEMU 方案快一个数量级。

### 3.5 【针对你的核心问题】多语言：现在的分类法是错的

计划书 §6 的 `build.type` 取值是 `go | dockerfile | custom`。**这三个值不在同一个维度上**：「go」是语言，「dockerfile」是打包方式，「custom」是逃生舱。一旦加入 Python，就会变成 `go / python / dockerfile / custom` 的混搭，每加一种语言都要动调度器——违背了「加项目只改 JSON」的目标。

**建议改成正交三轴：**

```jsonc
"build":  { "language": "go",        // go | python | node | rust | none
            "method":   "native" },  // native | dockerfile | custom
"docker": { "strategy": "upstream" } // upstream | generated | custom
```

**语言适配器统一契约（平台只认这个接口，新语言只实现它）：**

| 阶段 | Go | Python | Node |
|---|---|---|---|
| `detect` | `go.mod` / `go.work` | `pyproject.toml` / `requirements.txt` | `package.json` |
| `toolchain` | `actions/setup-go` | `actions/setup-python`（+ uv/pip 缓存） | `actions/setup-node` |
| `deps`（锁文件） | `go.sum` | `requirements.txt`(**带 hash**) / `uv.lock` / `poetry.lock` | `package-lock.json` |
| `assets`（架构无关，只跑一次） | 前端 `npm run build` | 前端构建 / 代码生成 | `tsc` / `vite build` |
| `build`（按 target） | `GOOS`/`GOARCH` 交叉编译 | **无编译**；打包 wheel / zipapp / sdist | 打包 bundle |
| `test` | `go test ./...` | `pytest` | `npm test` |
| `package` | `tar.gz` + `SHA256SUMS` | `wheel` / `tar.gz` + `SHA256SUMS` | `tar.gz` + `SHA256SUMS` |
| `runtime`（generated docker） | distroless/alpine + 二进制 | `python:3.12-slim` + venv + gunicorn/uvicorn | `node:24-alpine` |
| `healthcheck` | **必须项目指定**（见 §2.1 的 403） | 项目指定 | 项目指定 |

**必须显式声明能力标志，不能靠猜：**

```jsonc
"build": {
  "cross_compile": true,          // Go/Rust: true
  "arch_native_required": false   // Python 冻结二进制(PyInstaller/pex): true
}
```

**Python 的两个硬约束（计划书完全没有）：**

1. **冻结/打包出的「独立二进制」不能交叉编译。** PyInstaller / pex / shiv 都必须在目标 OS+架构 上运行才能产出该平台的产物。所以「Python 项目发 linux-arm64 二进制」= 必须有 arm64 runner 或 QEMU——**这里才是 arm64 决策真正咬人的地方**（§3.4）。
2. **有 C 扩展的依赖必须按架构构建。** 纯 Python 依赖可以在 amd64 上构建一次复用；`numpy`/`cryptography` 这类要么命中 manylinux wheel（可以），要么在 QEMU 下源码编译（极慢、可能失败）。配置里要允许 `docker.per_arch_deps: true` 让平台知道这一步不可省。

**顺带：`platforms` 字段混了三种目标词汇，必须拆开。**
计划书用 `"platforms": ["linux/amd64"]` 同时表达了 Docker platform、Go 的 `GOOS/GOARCH`、以及 Release 资产名（`linux-amd64.tar.gz`）。
但 Release 实际需要 `windows/amd64`、`darwin/arm64`（cline2api 上游自己就在 Windows/macOS/Linux 三个 runner 上构建桌面版），这些**不是** Docker platform。
→ 建议统一成 `target = { os, arch }`，由平台派生三套命名，否则后面一定长出一堆字符串拼接补丁。

---

## 四、修正版落地顺序

计划书 §十七 的顺序基本合理，按上面的评审调整如下：

1. **配置系统 + 骨架**（`upstream.json` v2：三轴 + target 对象 + 能力标志 + 校验器）
2. **同步器**（默认 `layout: "vendor"`：按 SHA 下载 → 校验 → 原子替换 `vendor/<name>/` → 记 provenance；
   `layout: "none"` 作为可选布局，两种布局下构建脚本一致）
3. **Go 适配器**（交叉编译 + `assets` 阶段分离；`package` 路径必须从配置读，别学 §6.1 的示例）
4. **Docker 构建 + OCI archive 传递 + staging tag 晋升**（把「构建」和「发布」拆成两个 Job，权限按 §3.2）
5. **GHCR 发布**（`provenance: false`；可见性人工步骤）
6. **Release**（`tag_strategy` 三选一；cps 走 `rolling-prerelease`）
7. **workflow 串联**（`actions: write` + `gh workflow run`；per-project concurrency；部分失败汇总）
8. **节流与缓存**（per-project `min_interval`；lockfile 哈希缓存键）
9. **Python 适配器**（用 `cross_compile: false` 验证能力标志设计是否成立）
10. **custom 适配器**（放最后，逃生舱不应该早于主路径）

---

## 五、可以直接开工的最小骨架

```jsonc
{
  "version": 2,
  "defaults": { "targets": ["linux/amd64", "linux/arm64"], "continue_on_error": true },
  "sync": { "layout": "none", "store_state": "reports/upstream-state.json" },
  "projects": [
    {
      "name": "cline2api",
      "repo": "https://github.com/luawei1/cline2api",
      "ref": { "type": "release-latest" },
      "version_source": "tag",
      "build": { "enabled": true, "language": "go", "method": "dockerfile",
                 "go_version": "1.26", "package": ".", "binary": "cline-proxy",
                 "test": { "enabled": true, "required": false }, "cross_compile": true },
      "docker": { "enabled": true, "strategy": "upstream", "image": "ghcr.io/<you>/cline2api",
                  "context": ".", "dockerfile": "Dockerfile", "provenance": false,
                  "targets": ["linux/amd64", "linux/arm64"],
                  "smoke": { "path": "/health", "expect": [200], "timeout": 60 } },
      "release": { "enabled": true, "binary": false, "tag_strategy": "upstream-tag" }
    },
    {
      "name": "cline-pass-switcher-go",
      "repo": "https://github.com/Hxjcc/cline-pass-switcher-go",
      "ref": { "type": "branch", "value": "main" },
      "version_source": "sha",
      "throttle": { "min_interval": "24h" },
      "build": { "enabled": true, "language": "go", "method": "native", "go_version": "1.25",
                 "package": "./cmd/cline-pass-switcher", "binary": "cline-pass-switcher",
                 "assets": [{ "run": "cd web && npm ci && npm run build", "runner": "ubuntu-latest" }],
                 "targets": ["linux/amd64", "linux/arm64", "windows/amd64"],
                 "test": { "enabled": true, "required": true }, "cross_compile": true },
      "docker": { "enabled": true, "strategy": "upstream", "image": "ghcr.io/<you>/cline-pass-switcher-go",
                  "context": ".", "dockerfile": "Dockerfile", "provenance": false,
                  "targets": ["linux/amd64", "linux/arm64"],
                  "smoke": { "path": "/", "expect": [200, 403], "timeout": 60 } },
      "release": { "enabled": true, "binary": true, "tag_strategy": "rolling-prerelease",
                   "assets": ["linux-amd64", "linux-arm64", "windows-amd64"] }
    }
  ]
}
```

---

## 六、附：证据文件

| 文件 | 内容 |
|---|---|
| `docs/verification/build_cline2api.log` | cline2api v1.6.4 完整构建日志（上游 Dockerfile，成功） |
| `docs/verification/build_cps.log` | cps main 完整构建日志（含 node/vite 阶段） |
| `docs/verification/poc_go.sh` | 模式 A 验证脚本（入口路径、交叉编译、`go test`） |
| `docs/verification/poc_docker.sh` | 模式 B 验证脚本 |
| `docs/verification/e2e-local.sh` | 骨架脚本端到端验证（真实上游，不发布） |
| `docs/verification/tree_*.json` | 三个仓库的完整文件树 |

> 说明：本评审的构建验证在本地 Docker 上完成，目的是确认**配置正确性**（入口包路径、
> Dockerfile、版本对应关系、健康检查期望值）——这些与在 GitHub Actions 上运行完全一致。
> 本地未做 arm64 模拟（QEMU 已还原），多架构路径按 §3.4 在 Actions 层面决策。

---

## 七、落地实现状态

按本评审的修正结论，已实现可运行骨架（`upstream.json` v2 + `scripts/` + 三个 workflow）。
与原始计划的对应关系：

| 评审结论 | 落地情况 |
|---|---|
| §3.1 源码落库用命名空间 | ✅ `sync.layout = "vendor"`：快照提交到 `vendor/<name>/`（`git add -f` + 剔除 `.github` + `UPSTREAM.json` 记录 provenance）；`layout: "none"` 仍可选 |
| §3.2 构建/发布分离 | ✅ `build` Job 只有 `contents: read`；发布走 OCI archive + skopeo，发布 Job 不执行上游代码 |
| §3.3 Actions 具体坑 | ✅ 显式 `gh workflow run` + `actions: write`；`provenance: false`；lockfile 哈希缓存；`concurrency` 不打断发布；部分失败汇总 |
| §3.4 arm64 策略 | ✅ `docker.native_per_arch` 开关 + 按架构矩阵展开 + `imagetools create` 合成 |
| §3.5 多语言两轴 | ✅ `build.language` × `build.method` + `cross_compile` 能力标志 + 矛盾声明校验 |
| Release tag 命名空间 | ✅ tag 带项目前缀（`cline2api/v1.6.4`），否则 N 个项目共用一个仓库会互相覆盖 |
| 健康检查不能猜 | ✅ `docker.smoke.expect` 支持状态码数组（cps 的 `/` 是 403） |

骨架侧新增、原始计划里没有的东西：

1. `throttle.min_interval_hours` —— cps 每天 1~13 次提交，没有节流就会天天重建。
2. `build.assets[]` —— 架构无关的前端构建只跑一次，而不是每个架构重复跑（QEMU 下尤其致命）。
3. `ub.py lockhash` —— 锁文件在 `vendor/<name>/` 而不在仓库根目录，
   `setup-go`/`setup-node` 的 `cache: true` 只会去根目录找（找不到直接失败），必须改成"源码就绪 → 算哈希 → actions/cache"。
4. `record` 阶段区分 `last_synced_sha` 与 `last_successful_build_sha`（计划 §10.1 要求），
   并保证部分失败在报告与 workflow 状态里都如实体现。

仍在骨架里**未验证**的部分（需要真实仓库才能跑）已列在 `README.md` 的"已知限制"。
