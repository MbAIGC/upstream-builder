#!/usr/bin/env bash
# 构建 Job 的总入口：取源码 -> 准备 -> 编译 -> 镜像 -> 打包 -> 写结果。
#
# 失败也必须留下 result.json（工作流用 `if: always()` 上传），否则「部分失败」无法如实上报。
# 本脚本运行在只读凭据的 Job 里：可以执行上游代码，但不能 push 任何 registry。
set -uo pipefail
source "$(dirname "$0")/lib.sh"

: "${UB_NAME:?}" "${UB_ENTRY:?}"
export UB_REPO_ROOT="${UB_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
ub_init_paths

# 矩阵条目可以收窄目标集合（原生 arm runner 路径：每个 entry 只做一个架构）
[ -n "${UB_ENTRY_TARGETS:-}" ] && export UB_BUILD_TARGETS="$UB_ENTRY_TARGETS"
[ -n "${UB_ENTRY_DOCKER_TARGETS:-}" ] && export UB_DOCKER_TARGETS="$UB_ENTRY_DOCKER_TARGETS"

status=success
error=""
step=""
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 注意：不能依赖 set -e —— 函数体出现在 `if ! run_all` 里时 errexit 会被关闭，
# 那样 build-docker.sh 失败后仍会继续执行并最终报 success（把失败伪装成成功）。
# 所以每一步都显式 `|| return 1`，并把失败步骤名带进报告。
run_all() {
  step="prepare";                bash "$UB_REPO_ROOT/scripts/prepare.sh"     || return 1

  if is_true "${UB_BUILD_ENABLED:-false}" && [ "${UB_METHOD}" != "dockerfile" ]; then
    step="build-native";         bash "$UB_REPO_ROOT/scripts/build-native.sh" || return 1
  elif [ "${UB_METHOD}" = "dockerfile" ]; then
    log "build.method=dockerfile：编译在 Dockerfile 内完成，跳过原生编译"
  fi

  if is_true "${UB_DOCKER_ENABLED:-false}"; then
    step="build-docker";         bash "$UB_REPO_ROOT/scripts/build-docker.sh" || return 1
  fi

  step="package";                bash "$UB_REPO_ROOT/scripts/package.sh"    || return 1
  step=""
}

if ! run_all; then
  status=failure
  error="失败步骤: ${step:-unknown}"
  warn "$error"
fi

# 把源码快照的 provenance 带出来（Release 说明里要写上游 SHA / 源码树摘要）
if [ -f "$UB_WORK/src/$UB_NAME.source.json" ]; then
  cp "$UB_WORK/src/$UB_NAME.source.json" "$UB_OUT/"
elif [ -f "$UB_SRC/UPSTREAM.json" ]; then
  # 落库布局：没有下载 sidecar，provenance 就在快照里
  cp "$UB_SRC/UPSTREAM.json" "$UB_OUT/$UB_NAME.source.json"
fi

python3 - "$UB_OUT/result.json" "$status" "$error" "$started" "$UB_OUT" <<'PY'
import json, os, sys
out_path, status, error, started, out_dir = sys.argv[1:6]

def rel(p):
    return p

result = {
    "entry": os.environ.get("UB_ENTRY", ""),
    "name": os.environ["UB_NAME"],
    "repo": os.environ.get("UB_REPO", ""),
    "sha": os.environ.get("UB_SHA", ""),
    "version": os.environ.get("UB_VERSION", ""),
    "language": os.environ.get("UB_LANGUAGE", ""),
    "method": os.environ.get("UB_METHOD", ""),
    "runner": os.environ.get("RUNNER_NAME", ""),
    "native_per_arch": os.environ.get("UB_NATIVE_PER_ARCH", "false"),
    "targets": os.environ.get("UB_BUILD_TARGETS", "").split(),
    "docker_targets": os.environ.get("UB_DOCKER_TARGETS", "").split(),
    "image": os.environ.get("UB_IMAGE", ""),
    "release_tag": os.environ.get("UB_RELEASE_TAG", ""),
    "release_binary": os.environ.get("UB_RELEASE_BINARY", ""),
    "release_tag_strategy": os.environ.get("UB_RELEASE_TAG_STRATEGY", ""),
    "release_assets": os.environ.get("UB_RELEASE_ASSETS", "").split(),
    "status": status,
    "error": error or None,
    "started_at": started,
    "finished_at": __import__("datetime").datetime.now(
        __import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "packages": sorted(os.path.basename(p) for p in
                       __import__("glob").glob(os.path.join(out_dir, "packages", "*.tar.gz"))),
    "has_image": os.path.exists(os.path.join(out_dir, "image.tar")),
}
json.dump(result, open(out_path, "w"), indent=2, ensure_ascii=False)
print(json.dumps(result, indent=2, ensure_ascii=False))
PY

if [ "$status" != "success" ]; then
  exit 1
fi
log "项目 $UB_NAME ($UB_ENTRY) 构建完成"
