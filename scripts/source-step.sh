#!/usr/bin/env bash
# 「源码就绪」步骤：保证 $UB_SRC 里是对应 SHA 的源码，并把工作路径写进 $GITHUB_ENV。
#
# 为什么单独一步：源码落库布局下 lockfile 就在 upstream/<name>/ 里，
# 但 actions/setup-go / setup-node 的 cache:true 只会去仓库根目录找锁文件（找不到会直接失败），
# 所以顺序必须是：源码就绪 -> 用 ub.py lockhash 算哈希 -> actions/cache。
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ub_init_paths
ub_ensure_source

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "UB_WORK=$UB_WORK"
    echo "UB_SRC=$UB_SRC"
    echo "UB_DIST=$UB_DIST"
    echo "UB_OUT=$UB_OUT"
  } >> "$GITHUB_ENV"
fi
log "源码就绪：$UB_SRC"
