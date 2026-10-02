#!/usr/bin/env bash
# 把构建 Job 散装上传的 artifact 按「项目」归组，再逐个发布。
#
# 为什么需要归组：原生 arm runner 路径下，同一个项目会产生多个 matrix entry
# （cps-amd64 / cps-arm64），每个 entry 一个 artifact；发布时必须把它们合到一起，
# 镜像要合成一个 manifest list，Release 要补齐所有资产。
#
# 用法: publish-all.sh image|release
set -euo pipefail
source "$(dirname "$0")/lib.sh"

what="${1:?用法: publish-all.sh image|release}"
: "${UB_ARTIFACTS:?UB_ARTIFACTS 未设置（actions/download-artifact 的输出目录）}"

group_root="$(mktemp -d)"
log "按项目归组 artifact：$UB_ARTIFACTS -> $group_root"

# 每个 entry 目录里都有 result.json / image-meta.json，其中 name 就是项目名
find "$UB_ARTIFACTS" -name 'result.json' -o -name 'image-meta.json' | while read -r meta; do
  dir="$(dirname "$meta")"
  read -r name entry < <(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get("name",""), d.get("entry") or d.get("name") or "entry")
' "$meta")
  [ -n "$name" ] || continue
  # 必须按 entry 分目录保存：同一个项目的多个 entry 都会产出 image.tar / image-meta.json，
  # 平铺到同一层会互相覆盖，结果只推上去一个架构（且架构校验必然失败）。
  mkdir -p "$group_root/$name/$entry"
  cp -a "$dir"/. "$group_root/$name/$entry"/
done

if is_true "${UB_GROUP_ONLY:-false}"; then
  log "UB_GROUP_ONLY=true：只输出归组结果，不真正发布"
  find "$group_root" -type f | sort
  exit 0
fi

found=0
for d in "$group_root"/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  found=1
  log "================ 发布项目: $name ================"
  UB_ARTIFACTS="$d" bash "$(dirname "$0")/publish-${what}.sh" || die "项目 $name 的 ${what} 发布失败"
done

[ "$found" = "1" ] || die "没有找到任何构建产物（构建阶段可能全部失败）"
log "${what} 发布阶段完成"
