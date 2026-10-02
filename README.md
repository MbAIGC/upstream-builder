# upstream-builder

多上游项目的自动同步、编译、二进制打包与 GHCR 镜像发布平台。运行在 GitHub Actions 上，
配置驱动：**新增一个上游项目原则上只改 `upstream.json`。**

本目录包含两份东西：

| 文件 | 说明 |
|---|---|
| `go-upstream-builder-开发落地计划.md` | 原始方案（1230 行） |
| `upstream-builder-可行性评审.md` | 对原始方案的评审：实测结论 + 4 处必须先改的缺陷 |
| 本 README + `scripts/` + `.github/workflows/` | 按评审结论实现的**可运行骨架** |

---

## 快速开始

1. 把本目录作为一个 GitHub 仓库推到你的账号下（**建议 public**：`ubuntu-24.04-arm`
   原生 arm64 runner 只对公共仓库免费，私有仓库加了该 label 会直接失败）。
2. 编辑 `upstream.json`，把每个项目的 `docker.image` 里的 owner 处理好
   （用 `{owner}` 占位符时会自动取 `github.repository_owner`）。
3. 确认仓库设置 → Actions → Workflow permissions 允许读写（`record` Job 要提交状态文件）。
4. 手动跑一次 `sync`（Actions → sync → Run workflow）。它会解析上游 SHA，
   有变化就提交状态并自动触发 `build`。

不需要配置任何 secret：GHCR 与 Release 都用仓库自带的 `GITHUB_TOKEN`。

---

## 工作原理

```
sync.yml (每天 03:17 + 手动)
  └─ 解析每个项目的 ref -> SHA，与 reports/upstream-state.json 比较
     ├─ 无变化/命中节流 -> 结束
     └─ 有变化 -> 提交状态文件 -> gh workflow run build.yml -f pins=<本次 SHA>

build.yml
  plan            解析要构建的项目，输出 matrix（含每项的目标架构）
  build  ×N       【只读凭据】取源码 -> 测试 -> 编译 -> smoke 门禁 -> OCI archive -> 打包
  publish-image   【packages:write】OCI archive -> push 不可变 sha 标签 -> 校验架构 -> 晋升 latest
  publish-release 【contents:write】上传二进制包，补齐缺失资产，不覆盖已有正式版本
  record          【contents:write】写状态、生成报告、如实反映部分失败

manual-build.yml  人工入口，参数名与计划书一致（project/force/publish/platforms/build_type）
```

### Job 权限模型（这是整套设计的安全核心）

| Job | 权限 | 是否执行上游代码 | 理由 |
|---|---|---|---|
| `plan` | `contents: read` | 否 | 只读配置与 GitHub API |
| `build` | `contents: read` | **是** | Dockerfile 的 `RUN`、`go test`、`npm ci`、custom 脚本都是上游代码。**这个 Job 拿不到 `packages:write`，磁盘上也没有 registry 凭据** |
| `publish-image` | `packages: write` | 否 | 只接受 OCI archive，用 skopeo 推送 |
| `publish-release` | `contents: write` | 否 | 只上传已打包的产物 |
| `record` | `contents: write` | 否 | 只读产物 JSON |

发布顺序保证 `latest` 永不指向未验证的产物：

```
push sha-<short>  ->  校验实际架构清单  ->  晋升 latest/版本标签  ->  复核 digest 一致
```

标签晋升用 `skopeo copy` 从已验证的 sha 标签复制（或 `docker buildx imagetools create`
合成 manifest list），**不重新构建**。

---

## 源码同步：落库到 `vendor/<name>/`

上游源码快照**提交进管理仓库**，每个项目一个命名空间目录：

```
vendor/
├── cline2api/
│   ├── UPSTREAM.json      # 上游地址 / ref / SHA / 版本 / 源码树摘要 / 文件数
│   └── ...                # 上游 tar.gz 的内容（.github 已剔除）
└── cline-pass-switcher-go/
    ├── UPSTREAM.json
    └── ...
```

由 `sync` workflow 负责写入并提交（每天一次 + 手动）。

### 为什么是 `vendor/<name>/` 而不是仓库根目录

上游自带的 `.gitignore` 作用域是**它所在的目录及其所有子目录**，而一个仓库根目录
只能有一份 `.gitignore`。把两份快照都摊在根目录时：后同步的那份会覆盖前一份，
且规则全局生效。实测 `luawei1/cline2api` 的 `.gitignore` 里有 `*_test.go`，
一旦它胜出，另一个项目的测试文件会**静默消失**，而 `go test ./...` 依然返回成功
（详见评审 §3.1）。放进各自的子目录后，每份 `.gitignore` 只作用于自己的子树，互不干扰。

### 提交时用 `git add -f`

`sync` 提交快照时用 `git add -A -f vendor/<name>` **强制纳入**。原因：快照的语义是
「上游 tar.gz 的内容」，不应该受上游 `.gitignore` 影响——否则 cline2api 的 14 个
`*_test.go` 会被丢掉，构建阶段跑测试就成了空跑。源码归档本身只包含上游已跟踪的文件，
所以 `-f` 不会引入游离文件。

每次同步还会：

- 剔除上游 `.github/`（否则上游 workflow 会变成本仓库的 workflow 被执行）；
- 写 `vendor/<name>/UPSTREAM.json` 记录 provenance（SHA、版本、`tree_sha256`、文件数）；
- SHA 未变化时**完全不重写**，避免产生无意义的提交；
- 替换是原子的（先备份旧快照，移动成功后才删），失败时保留旧源码。

### 不需要源码进仓库？

把 `upstream.json` 的 `sync.layout` 改成 `"none"`：源码改为按 SHA 现场下载到
`$RUNNER_TEMP`，只在仓库里留几百字节的状态文件。两种布局下构建脚本完全一致——
`ub_ensure_source` 发现 `vendor/<name>/` 缺失或 SHA 不匹配时会**现场补同步**，
所以 build 不依赖 sync 是否已经跑过。

### 代价与对策

| 代价 | 对策 |
|---|---|
| 仓库体积会随上游更新增长 | `sync` 每天最多一次；SHA 未变不产生提交；上游提交频繁的项目可加 `throttle` 降低构建频率 |
| 锁文件在 `vendor/<name>/` 而不在仓库根目录，`setup-go`/`setup-node` 的 `cache:true` 找不到（会直接失败） | 工作流顺序：源码就绪 → `ub.py lockhash` 算锁文件哈希 → `actions/cache` |
| 快照与上游 git 跟踪文件不完全等同时（我们去掉了 `.github`） | `UPSTREAM.json` 里记录 `stripped` 字段，构建输入的任何改写都可见 |


---

## 目录结构

```
upstream.json               唯一项目登记入口
vendor/<name>/              上游源码快照（由 sync 提交）+ UPSTREAM.json
scripts/
  ub.py                     引擎：validate / plan / vendor / env / lockhash / record / report
  lib.sh                    公共函数（路径、日志、目标解析、assets 执行）
  source-step.sh            工作流用：源码就绪并把路径写进 $GITHUB_ENV
  commit-and-push.sh        提交并推送（带 rebase 重试，sync 与 record 会并发写 main）
  prepare.sh                源码就绪 + assets + 测试
  build-native.sh           原生编译（go/python/node/rust 适配器）
  build-docker.sh           smoke 门禁 + 多架构 OCI archive 导出（不 push）
  package.sh                每个目标一个 tar.gz + SHA256SUMS
  publish-all.sh            按项目归组 artifact，逐个发布
  publish-image.sh          可信推送 + 架构校验 + 标签晋升 + digest 复核
  publish-release.sh        Release 幂等发布
  record-all.sh             写状态、生成报告、如实反映失败
  run-project.sh            构建 Job 总入口
  summarize.sh              Step Summary
docker/Dockerfile.go        strategy=generated 的模板
adapters/                   custom 模式的适配器（约定见该目录 README）
reports/upstream-state.json 唯一被提交的状态（很小）
docs/verification/          本地实测日志与复现脚本
```

---

## 配置

### 顶层

```jsonc
{
  "version": 2,
  "defaults": {
    "targets": ["linux/amd64", "linux/arm64"],
    "runners": { "amd64": "ubuntu-latest", "arm64": "ubuntu-24.04-arm" }
  },
  "sync": {
    "layout": "vendor",                          // vendor=源码落库到 vendor/<name>/；none=现场下载
    "vendor_dir": "vendor",
    "state_file": "reports/upstream-state.json"
  },
  "projects": [ /* ... */ ]
}
```

### 项目字段

| 字段 | 说明 |
|---|---|
| `name` | 唯一名称；同时用于产物命名、Release tag 前缀 |
| `repo` / `ref` | `ref.type`: `branch` / `tag` / `commit` / `release-latest` |
| `version_source` | `tag`（有正式版本，如 cline2api）或 `sha`（只有分支，如 cline-pass-switcher-go） |
| `throttle.min_interval_hours` | 构建节流。上游每天多次提交时用它避免天天重建 |
| `build.language` | `go` / `python` / `node` / `rust` / `none`（纯镜像项目） |
| `build.method` | `native` / `dockerfile` / `custom` |
| `build.package` | **必填且必须是真实入口**。`cline-pass-switcher-go` 的入口是 `./cmd/cline-pass-switcher`，写 `.` 会报 `no Go files` |
| `build.assets[]` | 架构无关的准备步骤（前端构建等），在构建 Job 的 amd64 runner 上只跑一次 |
| `build.test.required` | `false`（默认）时测试失败只告警；上游测试常依赖网络/凭据 |
| `build.cross_compile` | `go`/`rust` 为 `true`；`python`/`node` 冻结产物必须 `false` |
| `docker.strategy` | `upstream`（用上游 Dockerfile，**优先**）/ `generated` / `custom` |
| `docker.native_per_arch` | `false`（默认）= 一个 amd64 runner + QEMU；`true` = 每个架构一个原生 runner |
| `docker.provenance` | 保持 `false`。开启会让 GHCR 出现 `unknown/unknown` 架构条目 |
| `docker.tags` | 支持 `{version}` `{short_sha}` `{sha}` `{name}`；第一个 `sha-*` 固定为不可变标签 |
| `docker.smoke` | **必须显式指定** `container_port` + `path` + `expect`；见下方"健康检查" |
| `release.tag_strategy` | `upstream-tag` / `sha` / `rolling-prerelease` |

> **Release tag 带项目前缀**：Release 是仓库级命名空间，N 个项目共用一个仓库，
> 所以 tag 形如 `cline2api/v1.6.4`、`cline-pass-switcher-go/rolling`，否则会互相覆盖。

### 健康检查不能猜

`cline-pass-switcher-go` 的控制台需要鉴权，未登录访问 `/` 返回 **403**。
按"`curl -f /` 返回 200"实现的话它会永远判定失败。所以：

```jsonc
"smoke": { "container_port": 3457, "path": "/health", "expect": [200] }        // cline2api
"smoke": { "container_port": 3123, "path": "/",       "expect": [200, 403] }   // cps
```

### 多语言与镜像架构策略

`build.cross_compile` 管**二进制**，`docker.native_per_arch` 管**镜像** —— 两件事：

| 语言 | 交叉编译 | 冻结/打包产物 |
|---|---|---|
| Go / Rust | ✅ 一个 amd64 runner 出所有架构 | 原生编译 |
| Python / Node | ❌ 不能交叉编译 | PyInstaller/pex 等必须在目标架构上运行 |

新增 Python 项目的最小配置：

```jsonc
{
  "name": "py-svc",
  "repo": "https://github.com/<owner>/<repo>",
  "ref": { "type": "branch", "value": "main" },
  "version_source": "sha",
  "build": {
    "enabled": true, "language": "python", "method": "native",
    "python_version": "3.12",
    "package": "app",              // 含 __main__.py 的目录 -> zipapp；或用 native_command
    "binary": "py-svc",
    "cross_compile": false,        // 关键：会按架构拆到原生 runner
    "targets": ["linux/amd64", "linux/arm64"],
    "assets": [{ "run": "pip install -r requirements.txt", "workdir": "." }]
  },
  "docker": {
    "enabled": true, "strategy": "upstream",
    "image": "ghcr.io/{owner}/py-svc", "dockerfile": "Dockerfile",
    "targets": ["linux/amd64", "linux/arm64"],
    "native_per_arch": true,       // 避免 QEMU 下编译 C 扩展
    "smoke": { "container_port": 8000, "path": "/healthz", "expect": [200] }
  },
  "release": { "enabled": true, "binary": true, "tag_strategy": "sha" }
}
```

配置校验器会主动拦住矛盾声明，例如：

```
projects[2](py-svc).build.cross_compile: python 无法交叉编译出多架构产物，
  声明 cross_compile=true 但 targets 含 ['amd64', 'arm64']；
  必须改为 false 并使用原生 runner（例如 ubuntu-24.04-arm）
```

### 矩阵会自动展开

```
Go 交叉编译       -> cline-pass-switcher-go          runner=ubuntu-latest  targets=amd64+arm64+windows
镜像走原生 runner -> cline-pass-switcher-go-amd64     runner=ubuntu-latest       targets=amd64+windows
                     cline-pass-switcher-go-arm64     runner=ubuntu-24.04-arm    targets=arm64
Python            -> py-svc-amd64                      runner=ubuntu-latest
                     py-svc-arm64                      runner=ubuntu-24.04-arm
```

不出镜像的额外目标（如 `windows/amd64`）会挂到 amd64 entry 上，避免为它单开 runner
而让架构无关的 `assets` 步骤重复执行。

---

## 已知限制（诚实清单）

**已在本地用两个真实上游端到端验证过：**
解析 SHA / 增量决策 / 状态文件、`vendor/<name>/` 落库（幂等、剔除 `.github`、SHA 不一致时现场补同步）、
Go 原生编译（`./cmd/cline-pass-switcher`）、上游 Dockerfile 构建、smoke 门禁、OCI archive 导出、
打包（含 LICENSE/SOURCE.txt/SHA256SUMS）、发布路径（`oci-archive` → registry → 晋升后 digest 一致）、
Python 适配器与按架构矩阵展开、记录与报告（含部分失败如实上报）。

**尚未在真实 CI 上跑过（需要你的仓库来验证）：**
1. GitHub Actions 实际执行（YAML 已通过解析与结构校验，但没跑过）。
2. 推送到**你的** GHCR、GHCR 首次创建 package 的可见性（默认 private，改可见性不能可靠自动化，
   见评审 §3.3：需要一次性人工设置，或改用带 `write:packages` 的 PAT）。
3. `ubuntu-24.04-arm` 原生 runner（仅公共仓库可用）。
4. 多架构（>1 平台）合并：本地无 arm64 环境，只验证了单架构 archive 的推送与 digest 一致；
   N 个分架构 archive 用 `imagetools create` 合成的路径未在真实环境跑过。
5. `actions/cache` 的实际命中行为、`gh release create` 的幂等路径。

---

## 排错

| 现象 | 原因 / 处理 |
|---|---|
| `no Go files in ...` | `build.package` 写错了，必须是真实入口包路径 |
| `exec format error` | 在没有目标架构模拟器/原生 runner 的情况下构建了该架构的镜像。检查 `docker.targets` 与 `docker.native_per_arch` |
| GHCR 上出现 `unknown/unknown` | `docker.provenance` 被设为 `true`，改回 `false` |
| smoke 永远失败 | `docker.smoke.expect` 没包含真实返回码（例如鉴权后的 403） |
| `Dependencies lock file is not found` | 用了 `setup-go/setup-node` 的 `cache: true`：锁文件在 `vendor/<name>/` 而不在仓库根目录，它找不到。改用 `actions/cache` + `ub.py lockhash` |
| 构建报「快照与目标 SHA 不一致」 | 正常自愈：会现场补同步。若持续失败，先手动跑一次 `sync` |
| 推送被拒（non-fast-forward） | `sync` 与 `record` 会并发写 main；两者都用 `commit-and-push.sh`，内含 rebase 重试 |
| 上游无变化却天天重建 | 上游提交频繁（cps 每天 1~13 次），给它加 `throttle.min_interval_hours` |
| 构建 Job 里 push 失败 | 设计如此：构建 Job 没有 `packages:write`。发布只能在发布 Job 做 |

重新跑一次完整构建：Actions → manual-build → `project=all, force=true`。
