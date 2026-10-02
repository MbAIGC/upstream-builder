#!/usr/bin/env bash
# 打包独立二进制：每个目标一个 tar.gz + SHA256SUMS。
# 只处理 release.assets 里列出的目标（Docker-only 项目可以留空，不会被强制打包）。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

: "${UB_SRC:?}" "${UB_DIST:?}" "${UB_OUT:?}"
is_true "${UB_RELEASE_ENABLED:-false}" || { log "release.enabled=false，跳过打包"; exit 0; }
is_true "${UB_RELEASE_BINARY:-false}" || { log "release.binary=false（Docker-only 项目），跳过打包"; exit 0; }

project_dist="$UB_DIST/$UB_NAME/$UB_VERSION"
[ -d "$project_dist" ] || die "没有编译产物目录: $project_dist"

assets="${UB_RELEASE_ASSETS:-}"
[ -n "${assets// /}" ] || { log "release.assets 为空，改用 build targets"; assets="$(asset_suffix_of_list "$UB_BUILD_TARGETS")"; }

mkdir -p "$UB_OUT/packages"
for suffix in $assets; do
  srcdir="$project_dist/$suffix"
  [ -d "$srcdir" ] || { warn "缺少该目标的产物目录，跳过: $srcdir"; continue; }

  ship="$(mktemp -d)"
  # 产物本体
  cp -a "$srcdir"/. "$ship"/
  # 许可证与说明：保留上游版权声明（计划 12.3），绝不删除
  for f in LICENSE LICENSE.md LICENSE.txt COPYING README.md README; do
    if [ -f "$UB_SRC/$f" ] && [ ! -f "$ship/$f" ]; then cp "$UB_SRC/$f" "$ship/"; fi
  done
  # 构建来源说明：可追溯到上游 commit
  cat > "$ship/SOURCE.txt" <<EOF
project:        $UB_NAME
upstream:       $UB_REPO
commit:         $UB_SHA
version:        $UB_VERSION
target:         $srcdir
built_at:       $(date -u +%Y-%m-%dT%H:%M:%SZ)
built_by:       upstream-builder (GitHub Actions)
EOF

  # 校验和（对包内所有文件）
  ( cd "$ship" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs sha256sum > SHA256SUMS )

  pkg="$UB_OUT/packages/${UB_NAME}-${UB_VERSION}-${suffix}.tar.gz"
  tar czf "$pkg" -C "$ship" .
  sha256_of "$pkg" > "${pkg}.sha256"
  rm -rf "$ship"
  log "已打包 $pkg ($(du -h "$pkg" | cut -f1))"
done

ls -la "$UB_OUT/packages"
