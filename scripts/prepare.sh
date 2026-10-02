#!/usr/bin/env bash
# 取源码快照 + 跑架构无关的准备步骤 + 跑测试。
# 输入：UB_* 环境变量（由 `ub.py env` 生成）；UB_SRC 为目标目录。
# 关键点：源码只落在 $RUNNER_TEMP 下，永远不进管理仓库。
set -euo pipefail

UB_SRC="${UB_SRC:?UB_SRC 未设置}"
source "$(dirname "$0")/lib.sh"

group "取上游源码快照 (layout=none，不落库)"
log "项目=$UB_NAME  上游=$UB_REPO  sha=$UB_SHA"
# 已有同一 SHA 的快照就复用：工作流需要「先取源码算 lockfile 哈希、再恢复缓存」，
# 因此 fetch 会被调用两次，这里用 marker 避免重复下载。
if [ -f "$UB_SRC/.ub-sha" ] && [ "$(cat "$UB_SRC/.ub-sha")" = "$UB_SHA" ]; then
  log "复用已有快照（SHA 未变）"
else
  ub_python fetch --project "$UB_NAME" --sha "$UB_SHA" --dest "$UB_SRC"
  printf '%s' "$UB_SHA" > "$UB_SRC/.ub-sha"
fi
group_end

# 只取源码模式：让工作流能先算 lockfile 哈希再恢复缓存
if is_true "${UB_FETCH_ONLY:-false}"; then
  log "UB_FETCH_ONLY=true：只取源码，结束"
  exit 0
fi

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
