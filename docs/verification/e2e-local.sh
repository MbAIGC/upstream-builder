#!/usr/bin/env bash
# 端到端验证骨架脚本：真实上游 -> 取源码 -> 测试 -> 编译 -> smoke -> OCI archive -> 打包
#
# 需要：docker + 本机 Go 工具链（与 GH runner 上的 actions/setup-go 对应）。
# 不会推送任何东西（发布阶段不参与）。
#
# 用法：bash docs/verification/e2e-local.sh cline2api cline-pass-switcher-go
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${WORK:-$(mktemp -d)}"

# 只有 method=native 的项目才需要本机工具链；method=dockerfile 的编译在容器里完成
if ! command -v go >/dev/null 2>&1; then
  echo "提示：本机没有 Go。method=dockerfile 的项目不受影响；method=native 的会在编译步骤失败。"
fi

export UB_REPO_ROOT="$REPO_ROOT"
export UB_WORK="$WORK"
export GITHUB_TOKEN="${GITHUB_TOKEN:-}"
export RUNNER_NAME=local-box
export RUNNER_TEMP="$UB_WORK/tmp"
# 让 Go 的缓存放进工作目录，避免污染本机
export GOCACHE="$UB_WORK/gocache" GOMODCACHE="$UB_WORK/gomodcache" GOPATH="$UB_WORK/gopath"

mkdir -p "$UB_WORK/tmp"
cd "$UB_REPO_ROOT"
echo "工作目录: $UB_WORK"

# 用临时状态文件，避免污染仓库里交付的 reports/upstream-state.json
STATE="$UB_WORK/state.json"

for proj in "$@"; do
  echo "================= $proj ================="
  python3 scripts/ub.py plan --project "$proj" --state "$STATE" >/dev/null 2>&1 || true
  eval "$(python3 scripts/ub.py env --project "$proj" --owner acme --state "$STATE")"
  export UB_ENTRY="$UB_NAME"
  export UB_NATIVE_PER_ARCH=false
  # 本地验证默认跳过前端 npm 安装（耗时且需要 npm registry），其余流程完全一致。
  # 想连前端一起验证就设置 UB_ASSETS_JSON='' 之外的原始值（去掉这行即可）。
  export UB_ASSETS_JSON='[]'
  # 本地通常只有 amd64；要验证多架构请自行准备 arm64 模拟或原生环境
  export UB_ENTRY_TARGETS="${E2E_TARGETS:-linux/amd64}"
  export UB_ENTRY_DOCKER_TARGETS="${E2E_DOCKER_TARGETS:-linux/amd64}"
  export UB_OUT="$UB_WORK/out-$UB_ENTRY"

  echo "--- lang=$UB_LANGUAGE method=$UB_METHOD docker=$UB_DOCKER_ENABLED release=$UB_RELEASE_BINARY/$UB_RELEASE_ENABLED ---"
  bash scripts/run-project.sh > "$UB_WORK/$proj.log" 2>&1
  rc=$?
  echo "exit=$rc"
  grep -E "smoke|go build|已打包|复用已有快照|失败步骤" "$UB_WORK/$proj.log" | tail -15
  echo "--- 产物 ---"
  find "$UB_OUT" -maxdepth 2 -type f 2>/dev/null | sed "s|$UB_WORK/||" | sort
  echo "--- result.json ---"
  python3 -c "
import json
d = json.load(open('$UB_OUT/result.json'))
print({k: d[k] for k in ('name','status','language','method','targets','docker_targets','packages','has_image')})" 2>/dev/null || echo "（没有 result.json）"
done
