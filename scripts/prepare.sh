#!/usr/bin/env bash
# 准备源码 + 跑架构无关的准备步骤（assets）+ 跑测试。
# 输入：UB_* 环境变量（由 `ub.py env` 生成）。
# 源码布局由 sync.layout 决定：repo（仓库内 upstream/<name>/，sync 负责落库）
# 或 none（按 SHA 现场下载到 $RUNNER_TEMP，不进仓库）。
set -euo pipefail

source "$(dirname "$0")/lib.sh"
export UB_REPO_ROOT="${UB_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
ub_init_paths

group "准备上游源码"
log "项目=$UB_NAME  上游=$UB_REPO  sha=$UB_SHA  布局=${UB_SYNC_LAYOUT:-repo}"
ub_ensure_source
group_end

# build.env: 项目自定义构建环境变量
if [ -n "${UB_ENV_JSON:-}" ] && [ "$UB_ENV_JSON" != "{}" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    export "${line?}"
  done < <(json_to_env_lines "$UB_ENV_JSON")
fi

# 架构无关的准备步骤（前端构建等）在构建 Job 的 amd64 runner 上只做一次，
# 产物随后被所有目标架构共享；不在每个架构里重跑（这是 cps 这类项目省时间的关键）。
if [ -n "${UB_ASSETS_JSON:-}" ]; then
  run_assets "$UB_SRC" "$UB_ASSETS_JSON"
fi

# 测试：required=false 时只警告不阻断（上游测试可能需要网络/凭据）
if is_true "${UB_TEST_ENABLED:-false}"; then
  cmd="${UB_TEST_COMMAND:-}"
  if [ -z "$cmd" ]; then
    case "${UB_LANGUAGE:-}" in
      go)     cmd="go test ./..." ;;
      python) cmd="python -m pytest -q" ;;
      node)   cmd="npm test --if-present" ;;
      rust)   cmd="cargo test --release" ;;
      *)      warn "语言 ${UB_LANGUAGE:-none} 没有默认测试命令，跳过"; cmd="" ;;
    esac
  fi
  if [ -n "$cmd" ]; then
    group "测试 (required=${UB_TEST_REQUIRED:-false}): $cmd"
    if ( cd "$UB_SRC/$UB_WORKDIR" && bash -c "$cmd" ); then
      log "测试通过"
    else
      if is_true "${UB_TEST_REQUIRED:-false}"; then
        die "测试失败（required=true），终止构建: $cmd"
      else
        warn "测试失败但 required=false，继续构建（上游测试可能依赖网络或凭据）"
      fi
    fi
    group_end
  fi
fi

log "准备阶段完成：$UB_SRC"
