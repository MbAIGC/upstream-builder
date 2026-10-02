#!/usr/bin/env bash
# 提交并推送（带 rebase 重试）。
#
# 为什么需要重试：sync 提交源码快照、build 的 record Job 提交构建状态，
# 两者可能同时在写 main，直接 push 会有一个被拒。
#
# 用法: commit-and-push.sh "<commit message>" [pathspec...]
#       不给 pathspec 时默认提交 upstream.json 里配置的 vendor_dir 与 state_file。
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# 只解析仓库根目录：本脚本不碰源码路径，不能调 ub_init_paths（它需要 UB_NAME，
# 而 sync / record 的提交步骤里并没有 UB_NAME）。
export UB_REPO_ROOT="${UB_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

msg="${1:?用法: commit-and-push.sh <message> [pathspec...]}"
shift || true

if [ "$#" -eq 0 ]; then
  mapfile -t paths < <(python3 - "$UB_REPO_ROOT/upstream.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d.get("sync") or {}
print(s.get("vendor_dir", "vendor"))
print(s.get("state_file", "reports/upstream-state.json"))
PY
)
  set -- "${paths[@]}"
fi

git config user.name  "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

# -f 强制纳入：快照的语义是「上游 tar.gz 的内容」，不能受上游 .gitignore 影响
# （实测会被丢掉的是 *_test.go 这类文件）
git add -A -f -- "$@"
if git diff --cached --quiet; then
  log "没有需要提交的变更（$*）"
  exit 0
fi
git commit -q -m "$msg"
log "已提交：$msg"

branch="${GITHUB_REF_NAME:-main}"
for i in 1 2 3 4 5; do
  if git push origin "HEAD:$branch"; then
    log "已推送到 $branch（第 $i 次尝试）"
    exit 0
  fi
  log "推送被拒（可能另一条 workflow 同时在写），rebase 后重试 #$i"
  git pull --rebase --autostash origin "$branch" || true
  sleep 3
done
die "推送失败（重试 5 次）"
