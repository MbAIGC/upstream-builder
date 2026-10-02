#!/usr/bin/env bash
# 公共函数。所有构建脚本都以 `source lib.sh` 开头。
# 约定：本文件只提供工具函数，不产生副作用。

if [ -z "${UB_LIB_LOADED:-}" ]; then
  UB_LIB_LOADED=1

  log()   { printf '\033[1;34m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
  warn()  { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
  die()   { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
  group() { printf '::group::%s\n' "$*"; }
  group_end() { printf '::endgroup::\n'; }

  need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }
  is_true() { [ "${1:-}" = "true" ]; }

  # 用 python 解析 JSON 片段，避免依赖 jq
  json_get() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1],""))' "$1"; }

  sha256_of() { sha256sum "$1" | awk '{print $1}'; }

  # "linux/amd64 linux/arm64" -> 逐行
  each_target() { printf '%s\n' $1 | sed '/^$/d'; }

  goos_of()   { case "$1" in linux) echo linux ;; darwin) echo darwin ;; windows) echo windows ;; *) die "不支持的 os: $1" ;; esac; }
  goarch_of() { case "$1" in amd64) echo amd64 ;; arm64) echo arm64 ;; arm) echo arm ;; *) die "不支持的 arch: $1" ;; esac; }
  exe_suffix(){ [ "$1" = "windows" ] && printf '.exe' || printf ''; }

  rust_triple_of() {
    case "$1" in
      linux/amd64)   echo x86_64-unknown-linux-gnu ;;
      linux/arm64)   echo aarch64-unknown-linux-gnu ;;
      darwin/amd64)  echo x86_64-apple-darwin ;;
      darwin/arm64)  echo aarch64-apple-darwin ;;
      windows/amd64) echo x86_64-pc-windows-msvc ;;
      *) die "Rust 没有为该目标预置 triple: $1（请用 build.native_command 自定义）" ;;
    esac
  }

  # 目标 -> 资源名后缀，例如 linux/amd64 -> linux-amd64
  asset_suffix_of() { printf '%s\n' "$1" | tr '/' '-'; }
  asset_suffix_of_list() { local t; for t in $1; do asset_suffix_of "$t"; done | tr '\n' ' '; }

  ub_python() { python3 "${UB_REPO_ROOT:?UB_REPO_ROOT 未设置}/scripts/ub.py" "$@"; }

  # 工作目录的唯一来源。工作流里「取源码」和「构建」是两个步骤，
  # 如果各自算一遍路径就会漂移（UB_SRC 未设置就是这么炸的）。
  # 已有的值优先复用，便于工作流通过 $GITHUB_ENV 传入。
  ub_init_paths() {
    export UB_REPO_ROOT="${UB_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    export UB_WORK="${UB_WORK:-${RUNNER_TEMP:-/tmp}/ub}"
    export UB_DIST="${UB_DIST:-$UB_WORK/dist}"
    export UB_OUT="${UB_OUT:-$UB_WORK/out-${UB_ENTRY:-${UB_NAME:?UB_NAME 未设置}}}"
    if [ "${UB_SYNC_LAYOUT:-vendor}" = "vendor" ]; then
      # 落库布局：源码就是仓库里的快照，不复制到临时目录（大仓库复制很贵）
      export UB_SRC="${UB_SRC:-$UB_REPO_ROOT/${UB_VENDOR_DIR:-vendor}/${UB_NAME:?UB_NAME 未设置}}"
    else
      export UB_SRC="${UB_SRC:-$UB_WORK/src/${UB_NAME:?UB_NAME 未设置}}"
      mkdir -p "$UB_SRC"
    fi
    mkdir -p "$UB_WORK" "$UB_DIST" "$UB_OUT"
  }

  # 保证 UB_SRC 里是 UB_SHA 对应的源码。幂等，可重复调用。
  ub_ensure_source() {
    ub_init_paths
    if [ "${UB_SYNC_LAYOUT:-vendor}" = "vendor" ]; then
      local up="$UB_SRC/UPSTREAM.json" cur=""
      if [ -f "$up" ]; then
        cur="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("sha",""))' "$up" 2>/dev/null || true)"
      fi
      if [ "$cur" = "$UB_SHA" ]; then
        log "复用仓库内快照（${UB_VENDOR_DIR:-vendor}/$UB_NAME，sha=${UB_SHA:0:12}）"
      else
        warn "仓库内快照与目标 SHA 不一致（现有=${cur:-<无>} 目标=$UB_SHA），现场补同步"
        ub_python vendor --project "$UB_NAME" --sha "$UB_SHA" --version "$UB_VERSION" --dest "$UB_SRC" >/dev/null
        log "已补齐快照：$UB_SRC"
      fi
      [ -d "$UB_SRC" ] || die "快照目录不存在: $UB_SRC"
      [ -f "$UB_SRC/UPSTREAM.json" ] || die "快照缺少 UPSTREAM.json: $UB_SRC（应含上游 SHA 与源码树摘要）"
    else
      if [ -f "$UB_SRC/.ub-sha" ] && [ "$(cat "$UB_SRC/.ub-sha")" = "$UB_SHA" ]; then
        log "复用已有下载快照（SHA 未变）"
      else
        ub_python fetch --project "$UB_NAME" --sha "$UB_SHA" --dest "$UB_SRC"
        printf '%s' "$UB_SHA" > "$UB_SRC/.ub-sha"
      fi
    fi
  }

  # 展开 build.native_command 里的占位符
  expand_cmd() {
    local cmd="$1" os="$2" arch="$3" outdir="$4"
    cmd="${cmd//\{os\}/$os}"
    cmd="${cmd//\{arch\}/$arch}"
    cmd="${cmd//\{goos\}/$(goos_of "$os")}"
    cmd="${cmd//\{goarch\}/$(goarch_of "$arch")}"
    cmd="${cmd//\{target\}/$(asset_suffix_of "$os/$arch")}"
    cmd="${cmd//\{triple\}/$(rust_triple_of "$os/$arch")}"
    cmd="${cmd//\{outdir\}/$outdir}"
    printf '%s' "$cmd"
  }

  # build.env / docker.env 之类的小 map -> KEY=VALUE 行
  json_to_env_lines() {
    python3 -c '
import json,sys
try: d=json.loads(sys.argv[1] or "{}")
except Exception: d={}
for k,v in d.items(): print(f"{k}={v}")
' "$1"
  }

  # 执行 build.assets（架构无关的准备步骤：前端构建、代码生成……）
  run_assets() {
    local src="$1" assets_json="$2" i=0
    local n
    n=$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1] or "[]")))' "$assets_json")
    [ "$n" = "0" ] && { log "没有 assets 步骤"; return 0; }
    while [ "$i" -lt "$n" ]; do
      local run wd shell_
      run=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[int(sys.argv[2])].get("run",""))' "$assets_json" "$i")
      wd=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[int(sys.argv[2])].get("workdir","."))' "$assets_json" "$i")
      shell_=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[int(sys.argv[2])].get("shell","bash"))' "$assets_json" "$i")
      [ -z "$run" ] && { i=$((i+1)); continue; }
      group "asset[$i] (workdir=$wd): $run"
      log "运行架构无关的准备步骤：$run"
      ( cd "$src/$wd" && "$shell_" -c "$run" ) || die "assets 步骤失败: $run"
      group_end
      i=$((i+1))
    done
  }
fi
