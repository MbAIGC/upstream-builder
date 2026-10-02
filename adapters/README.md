# 构建适配器（escape hatch）

只有通用构建器确实不能满足要求时才在这里新增适配器。**主路径不应该依赖适配器。**

## 什么时候需要适配器

| 场景 | 用什么 |
|---|---|
| 需要前端编译 + 后端编译 | 通常不需要适配器：用 `build.assets` 描述前端步骤，`build.method: native` 编译后端 |
| 需要代码生成 / protoc | `build.assets`（架构无关，只跑一次） |
| 特殊 CGO / 交叉编译工具链 | `build.method: custom` + 本目录脚本 |
| 上游构建流程无法用声明式描述 | `build.method: custom` + 本目录脚本 |
| 上游已提供可用 Dockerfile | **不要写适配器**，用 `docker.strategy: upstream` |

## 约定

配置：

```jsonc
"build": {
  "enabled": true,
  "language": "go",
  "method": "custom",
  "script": "adapters/build-project-x.sh",
  "targets": ["linux/amd64"]
}
```

脚本必须遵守：

1. 通过环境变量接收输入，**不要自己解析 JSON**：
   - `UB_SRC`：源码快照目录
   - `UB_WORKDIR`：项目内工作目录（相对 `UB_SRC`）
   - `UB_DIST`、`UB_VERSION`、`UB_BINARY`
   - `UB_BUILD_TARGETS`：空格分隔的目标列表
2. 产物必须写到 `$UB_DIST/$UB_NAME/$UB_VERSION/<os>-<arch>/`。
3. 失败必须返回非零退出码（不要 `|| true` 吞掉错误）。
4. **禁止**推送任何 registry、禁止创建 Release、禁止修改 `scripts/`、`upstream.json`、`.github/`。
5. 不要假设自己持有任何写权限 Token —— 执行适配器的 Job 只有 `contents: read`。

## 安全边界

适配器脚本是**上游相关代码**，运行在只读凭据的构建 Job 里。它可以读源码、可以失败，
但不能发布任何东西：镜像与 Release 都由独立的可信 Job 从产物推上去。
因此适配器里加 `docker push` 也会因为缺少凭据而失败 —— 这是设计如此，不是缺陷。
