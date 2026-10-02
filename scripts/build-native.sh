#!/usr/bin/env bash
# 原生编译：按 UB_BUILD_TARGETS 逐个目标产出产物到 $UB_DIST。
# 语言适配器契约：新增语言只改本文件的 case 分支 + ub.py 的 LANGUAGES 白名单。
#   detect / toolchain / deps / assets / test 由工作流与 prepare.sh 负责，
#   本脚本只负责 build(按 target)。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

: "${UB_SRC:?}" "${UB_DIST:?}"
is_true "${UB_BUILD_ENABLED:-false}" || { log "build.enabled=false，跳过原生编译"; exit 0; }
[ -n "${UB_BUILD_TARGETS// /}" ] || { log "没有 build targets，跳过原生编译"; exit 0; }

project_dist="$UB_DIST/$UB_NAME/$UB_VERSION"
mkdir -p "$project_dist"

build_go() {
  local os="$1" arch="$2" outdir="$3"
  need go
  local -a args=()
  if is_true "$UB_TRIMPATH"; then args+=(-trimpath); fi
  if [ -n "${UB_LDFLAGS:-}" ]; then args+=(-ldflags "$UB_LDFLAGS"); fi
  args+=(-o "$outdir/$UB_BINARY$(exe_suffix "$os")" "$UB_PACKAGE")

  group "go build $os/$arch  (package=$UB_PACKAGE)"
  ( cd "$UB_SRC/$UB_WORKDIR" \
    && CGO_ENABLED="${CGO_ENABLED:-0}" \
       GOOS="$(goos_of "$os")" GOARCH="$(goarch_of "$arch")" \
       go build "${args[@]}" )
  group_end
}

build_python() {
  local os="$1" arch="$2" outdir="$3"
  if [ -n "${UB_NATIVE_COMMAND:-}" ]; then
    group "python 自定义打包 $os/$arch"
    local cmd
    cmd="$(expand_cmd "$UB_NATIVE_COMMAND" "$os" "$arch" "$outdir")"
    log "执行: $cmd"
    ( cd "$UB_SRC/$UB_WORKDIR" && bash -c "$cmd" ) || die "native_command 失败: $cmd"
    group_end
    return 0
  fi
  if [ -f "$UB_SRC/$UB_WORKDIR/$UB_PACKAGE/__main__.py" ]; then
    need python3
    group "python zipapp $os/$arch（纯 Python，产物与架构无关）"
    ( cd "$UB_SRC/$UB_WORKDIR" \
      && python3 -m zipapp "$UB_PACKAGE" -o "$outdir/$UB_BINARY" -p "/usr/bin/env python3" \
      && chmod +x "$outdir/$UB_BINARY" )
    group_end
    return 0
  fi
  if [ -f "$UB_SRC/$UB_WORKDIR/pyproject.toml" ] || [ -f "$UB_SRC/$UB_WORKDIR/setup.py" ]; then
    need python3
    group "python wheel $os/$arch"
    ( cd "$UB_SRC/$UB_WORKDIR" && python3 -m pip wheel --no-deps -w "$outdir" . ) \
      || die "pip wheel 失败：若项目使用 uv/poetry/hatch，请设置 build.native_command"
    group_end
    return 0
  fi
  die "Python 项目没有可识别的打包入口。请二选一：
       - build.package 指向含 __main__.py 的目录（走 zipapp）
       - build.native_command 自定义（可用占位符 {os} {arch} {outdir} {target}）"
}

build_node() {
  local os="$1" arch="$2" outdir="$3"
  if [ -n "${UB_NATIVE_COMMAND:-}" ]; then
    local cmd
    cmd="$(expand_cmd "$UB_NATIVE_COMMAND" "$os" "$arch" "$outdir")"
    ( cd "$UB_SRC/$UB_WORKDIR" && bash -c "$cmd" ) || die "native_command 失败: $cmd"
    return 0
  fi
  need npm
  group "node 打包 $os/$arch"
  ( cd "$UB_SRC/$UB_WORKDIR" && npm ci --omit=dev )
  mkdir -p "$outdir/app"
  ( cd "$UB_SRC/$UB_WORKDIR" \
    && cp -a package.json "$outdir/app/" \
    && [ -d node_modules ] && cp -a node_modules "$outdir/app/" || true )
  group_end
  warn "node 默认打包较粗糙（复制 package.json + node_modules）；原生模块无法跨架构，生产建议 build.native_command"
}

build_rust() {
  local os="$1" arch="$2" outdir="$3"
  need cargo
  local triple
  triple="$(rust_triple_of "$os/$arch")"
  group "cargo build $triple"
  ( cd "$UB_SRC/$UB_WORKDIR" \
    && ( rustup target add "$triple" >/dev/null 2>&1 || true ) \
    && cargo build --release --target "$triple" \
    && cp "target/$triple/release/$UB_BINARY$(exe_suffix "$os")" "$outdir/" )
  group_end
}

while read -r target; do
  [ -z "$target" ] && continue
  os="${target%%/*}"; arch="${target##*/}"
  outdir="$project_dist/$os-$arch"
  mkdir -p "$outdir"
  log "编译 $UB_NAME $UB_VERSION -> $os/$arch ($UB_LANGUAGE/$UB_METHOD)"
  case "${UB_LANGUAGE}" in
    go)     build_go "$os" "$arch" "$outdir" ;;
    python) build_python "$os" "$arch" "$outdir" ;;
    node)   build_node "$os" "$arch" "$outdir" ;;
    rust)   build_rust "$os" "$arch" "$outdir" ;;
    *)      die "没有 ${UB_LANGUAGE} 的适配器实现（可用 build.method=custom 接适配器脚本）" ;;
  esac
  ls -la "$outdir"
done < <(each_target "$UB_BUILD_TARGETS")

log "原生编译完成：$project_dist"
