#!/usr/bin/env bash
# 可信发布 Job：发布 GitHub Release（独立二进制）。
# 幂等：同名 Release 已存在时按 tag_strategy 决定「不覆盖」或「滚动更新资产」。
# 本 Job 不执行上游代码，只上传构建 Job 已经打包好的产物。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

: "${UB_ARTIFACTS:?UB_ARTIFACTS 未设置}"

meta="$(find "$UB_ARTIFACTS" -name 'image-meta.json' | sort | head -1)"
if [ -n "$meta" ]; then
  eval "$(ub_python meta-env --meta "$meta")"
fi
if [ -z "${UB_RELEASE_TAG:-}" ]; then
  # 纯二进制项目（没有镜像）时改从 result.json 取
  res="$(find "$UB_ARTIFACTS" -name 'result.json' | sort | head -1)"
  [ -n "$res" ] || { log "没有找到构建元数据，跳过 Release"; exit 0; }
  eval "$(ub_python meta-env --meta "$res")"
fi

pkgs="$(find "$UB_ARTIFACTS" -name '*.tar.gz' | sort)"
if [ -z "$pkgs" ]; then
  log "没有二进制包（release.binary=false 或未启用），跳过 Release"
  exit 0
fi

need gh
strategy="${UB_RELEASE_TAG_STRATEGY:-sha}"
tag="$UB_RELEASE_TAG"
log "Release tag=$tag  策略=$strategy"

src_json="$(find "$UB_ARTIFACTS" -name '*.source.json' | sort | head -1)"
tree_sha="unknown"
[ -n "$src_json" ] && tree_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("tree_sha256","unknown"))' "$src_json")"

notes="$(mktemp)"
cat > "$notes" <<EOF
由 upstream-builder 自动构建并发布。

| 项目 | 值 |
|---|---|
| 上游仓库 | $UB_REPO |
| 上游版本 | $UB_VERSION |
| 上游 Commit | \`$UB_SHA\` |
| 源码树摘要 | \`$tree_sha\` |
| 构建时间 | $(date -u +%Y-%m-%dT%H:%M:%SZ) |
| 构建方式 | ${UB_LANGUAGE}/${UB_METHOD} |

校验：每个包内附 \`SHA256SUMS\`，同名 \`.sha256\` 为压缩包本身的摘要。
许可证与版权声明随包分发，未做任何修改。
EOF

declare -a assets=()
for p in $pkgs; do assets+=("$p"); [ -f "${p}.sha256" ] && assets+=("${p}.sha256"); done

if gh release view "$tag" >/dev/null 2>&1; then
  if [ "$strategy" = "rolling-prerelease" ]; then
    log "Release $tag 已存在，按 rolling-prerelease 滚动更新资产"
    gh release upload "$tag" "${assets[@]}" --clobber
  else
    # 正式版本不覆盖已有资产；但要补齐缺失的资产。
    # 原生 arm runner 路径下同一项目会分多个 entry 发布，第二个 entry 不能因为
    # Release 已存在就什么也不传（否则 arm64 的包会永远缺失）。
    existing="$(gh release view "$tag" --json assets --jq '.assets[].name' 2>/dev/null || true)"
    missing=()
    for a in "${assets[@]}"; do
      if printf '%s\n' "$existing" | grep -qxF "$(basename "$a")"; then
        log "已存在，跳过（不覆盖正式版本）: $(basename "$a")"
      else
        missing+=("$a")
      fi
    done
    if [ "${#missing[@]}" -eq 0 ]; then
      log "Release $tag 资产已齐全，无需改动"
      rm -f "$notes"
      exit 0
    fi
    log "补齐缺失资产：${#missing[@]} 个"
    gh release upload "$tag" "${missing[@]}"
  fi
else
  declare -a flags=(--title "$UB_NAME $UB_VERSION" --notes-file "$notes")
  [ "$strategy" = "rolling-prerelease" ] && flags+=(--prerelease)
  [ "$strategy" = "upstream-tag" ] || flags+=(--prerelease)
  gh release create "$tag" "${assets[@]}" "${flags[@]}"
fi
rm -f "$notes"

mkdir -p "${UB_OUT:-/tmp/ub-out}"
python3 - "${UB_OUT:-/tmp/ub-out}/released.json" "$tag" <<'PY'
import json, os, sys
json.dump({"name": os.environ.get("UB_NAME",""), "release_tag": sys.argv[2],
           "status": "success"}, open(sys.argv[1],"w"), indent=2, ensure_ascii=False)
PY
log "Release $tag 发布完成"
