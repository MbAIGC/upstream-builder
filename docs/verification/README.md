# 复现实验与实测证据

这里保存评审与骨架的实测证据。**这些不是单元测试**，是用两个真实上游跑出来的记录。

## 文件

| 文件 | 内容 |
|---|---|
| `build_cline2api.log` | `luawei1/cline2api` v1.6.4 用**上游 Dockerfile 原样**构建（成功，121s，29.6MB，`/health`=200） |
| `build_cps.log` | `Hxjcc/cline-pass-switcher-go` main 构建（成功，183s，29.3MB，含 node/vite 阶段） |
| `tree_*.json` | 两个被测上游的完整文件树 |
| `poc_go.sh` | 模式 A 验证：入口包路径、`go test`、交叉编译 |
| `poc_docker.sh` | 模式 B 验证：上游 Dockerfile 原样构建 |
| `e2e-local.sh` | 骨架脚本的端到端验证（取源码 → 测试 → 编译 → smoke → OCI archive → 打包） |

## 怎么复现

需要一个可用的 Docker，以及 Go 工具链（`e2e-local.sh` 会用到 `go`）：

```bash
# 1) 模式 B：上游 Dockerfile 是否真的能构建
bash docs/verification/poc_docker.sh

# 2) 模式 A：入口包路径 / 交叉编译 / go test
bash docs/verification/poc_go.sh

# 3) 骨架脚本端到端（真实上游，不发布）
bash docs/verification/e2e-local.sh cline2api
bash docs/verification/e2e-local.sh cline-pass-switcher-go
```

## 关键结论（数字来自上面这些日志）

| 结论 | 证据 |
|---|---|
| 两个上游的 Dockerfile **一行不改**即可构建 | `build_*.log` |
| 计划书 §6.1 的示例配置是错的 | `poc_go.sh`：cps 写 `package: "."` → `no Go files in /src`；真实入口是 `./cmd/cline-pass-switcher` |
| `cline2api` 的服务端可脱离 wails/CGO 构建 | `main.go` 有 `//go:build !desktop`；`poc_go.sh` 的 `CGO_ENABLED=0 go build .` 成功 |
| smoke 门禁不能猜路径 | cps 的 `/` 返回 **403**（控制台需鉴权），按 200 判定会永远失败 |
| 上游提交频率决定了必须节流 | cps 每天 1~13 次提交，10-02 当天 10 分钟内 3 次；且它 **0 tag / 0 release** |
| cps 的 `.gitignore`（以及 cline2api 的）证明"源码放仓库根目录"会互相污染 | 评审 §3.1；`tree_*.json` 可见两个仓库根目录都有 `.gitignore` |

## 未在本地验证的部分

见 `README.md` 的"已知限制"：真实 Actions 执行、你的 GHCR、`ubuntu-24.04-arm`、
多架构 manifest 合成、Release 创建。
