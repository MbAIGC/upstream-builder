#!/usr/bin/env bash
# 只取源码快照（同时把工作路径写进 $GITHUB_ENV，供后续步骤复用）。
#
# 为什么单独成脚本：源码不落库时，工作流必须先取源码、算出 lockfile 哈希，
# 才能恢复 actions/cache（setup-go/setup-node 的 cache:true 在这里是行不通的）。
set -euo pipefail
source "$(dirname "$0")/lib.sh"
export UB_REPO_ROOT="${UB_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
ub_init_paths

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "UB_WORK=$UB_WORK"
    echo "UB_SRC=$UB_SRC"
    echo "UB_DIST=$UB_DIST"
    echo "UB_OUT=$UB_OUT"
  } >> "$GITHUB_ENV"
fi

export UB_FETCH_ONLY=true
exec bash "$UB_REPO_ROOT/scripts/prepare.sh"
