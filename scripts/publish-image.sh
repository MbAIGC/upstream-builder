#!/usr/bin/env bash
# 可信发布 Job：把构建 Job 产出的 OCI archive 推到 GHCR，验证后晋升标签。
#
# 本 Job 不执行任何上游代码：输入只有 OCI archive + image-meta.json。
# 顺序：push 到不可变 sha 标签 -> 校验架构清单 -> 晋升 latest/版本标签 -> 复核 digest 一致。
# 因此 latest 永远只指向已验证过的 digest（计划 7.2 第 3/5 条）。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

: "${UB_ARTIFACTS:?UB_ARTIFACTS 未设置（下载下来的 artifact 目录）}"

meta="$(find "$UB_ARTIFACTS" -name 'image-meta.json' | sort | head -1)"
[ -n "$meta" ] || { log "没有找到 image-meta.json，说明本次没有镜像产物；跳过"; exit 0; }
eval "$(ub_python meta-env --meta "$meta")"
log "发布 $UB_NAME ($UB_VERSION) -> $UB_IMAGE:$UB_PUSH_TAG"

need docker
need skopeo

# ghcr.io 登录：只有本 Job 持有 packages:write，构建 Job 没有这个凭据。
[ -n "${GITHUB_TOKEN:-}" ] || die "缺少 GITHUB_TOKEN，无法推送 GHCR"
export REGISTRY_AUTH_FILE="${REGISTRY_AUTH_FILE:-$HOME/.config/containers/auth.json}"
mkdir -p "$(dirname "$REGISTRY_AUTH_FILE")"
log "登录 ghcr.io（actor=${GITHUB_ACTOR:-unknown}）"
printf '%s' "$GITHUB_TOKEN" | docker login ghcr.io -u "${GITHUB_ACTOR:-github-actions}" --password-stdin
printf '%s' "$GITHUB_TOKEN" | skopeo login ghcr.io -u "${GITHUB_ACTOR:-github-actions}" --password-stdin

# 收集 OCI archive：Go 交叉编译=1 个多架构 archive；原生 arm runner=N 个单架构 archive
mapfile -t archives < <(find "$UB_ARTIFACTS" -name 'image.tar' -size +0c | sort)
if [ "${#archives[@]}" -eq 0 ]; then
  warn "$UB_NAME 没有 OCI archive（该项目构建失败或未产出镜像），跳过发布。
       注意：构建 Job 的失败状态仍然会让本次运行最终标记为失败。"
  exit 0
fi
log "找到 ${#archives[@]} 个 OCI archive"

# 用配置级列表：原生 arm runner 路径下每个 entry 只知道自己的架构，
# 但校验的是「合成后的 manifest list 是否覆盖项目声明的全部架构」。
expected_src="${UB_DOCKER_TARGETS_ALL:-$UB_DOCKER_TARGETS}"
expected="$(printf '%s\n' $expected_src | sort | tr '\n' ' ' | sed 's/ $//')"
log "期望架构清单: [$expected]"

if [ "${#archives[@]}" -eq 1 ]; then
  log "单一 archive -> 推到不可变标签 $UB_IMAGE:$UB_PUSH_TAG"
  skopeo copy --all --retry-times 3 "oci-archive:${archives[0]}" "docker://$UB_IMAGE:$UB_PUSH_TAG"
else
  stage_refs=()
  i=0
  for a in "${archives[@]}"; do
    stage="$UB_IMAGE:stage-${UB_SHORT_SHA}-${i}"
    log "推送分架构镜像 -> $stage"
    skopeo copy --all --retry-times 3 "oci-archive:${a}" "docker://$stage"
    stage_refs+=("$stage")
    i=$((i+1))
  done
  log "合成 manifest list -> $UB_IMAGE:$UB_PUSH_TAG"
  docker buildx imagetools create --tag "$UB_IMAGE:$UB_PUSH_TAG" "${stage_refs[@]}"
fi

# ---- 架构清单校验：不能只凭 buildx 成功就宣称支持多架构（计划 7.3） ----
inspect_raw() { docker buildx imagetools inspect --raw "$1" > /tmp/ub-manifest.json 2>/dev/null; }
platforms_of_manifest() {
  python3 - <<'PY'
import json
try:
    d = json.load(open('/tmp/ub-manifest.json'))
except Exception:
    print("")
    raise SystemExit
plats, unknown = [], 0
for m in d.get('manifests') or []:
    p = m.get('platform') or {}
    os_, ar = p.get('os'), p.get('architecture')
    if not os_ or not ar:
        continue
    if os_ == 'unknown' or ar == 'unknown':
        # provenance/SBOM attestation 会在 index 里留下 unknown/unknown 条目
        unknown += 1
        continue
    plats.append(f"{os_}/{ar}")
open('/tmp/ub-unknown-count', 'w').write(str(unknown))
print(' '.join(sorted(set(plats))))
PY
}

inspect_raw "$UB_IMAGE:$UB_PUSH_TAG" || die "无法读取刚推送的镜像 $UB_IMAGE:$UB_PUSH_TAG"
actual="$(platforms_of_manifest)"
unknown_count="$(cat /tmp/ub-unknown-count 2>/dev/null || echo 0)"
log "实际架构清单: [${actual:-<单架构 manifest，无 index>}]"
if [ "${unknown_count:-0}" != "0" ]; then
  warn "index 里有 ${unknown_count} 个 unknown/unknown 条目（provenance/SBOM attestation 残留）。
       它会让 GHCR 页面显示异常架构，并可能导致下游 digest 漂移。
       修法：把该项目的 docker.provenance 设为 false（upstream.json）。"
fi
if [ -n "$actual" ]; then
  if [ "$(printf '%s\n' $actual | sort | tr '\n' ' ' | sed 's/ $//')" != "$expected" ]; then
    die "架构清单不符：期望 [$expected]，实际 [$actual]。
       已推到不可变标签 $UB_PUSH_TAG，但拒绝晋升 latest（计划 7.3：必须校验实际平台清单）"
  fi
  log "架构清单校验通过"
else
  warn "只有单架构 manifest（未生成 index）；若配置了多架构，请检查 buildx 的 --platform 是否生效"
fi

digest="$(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$UB_IMAGE:$UB_PUSH_TAG")"
log "镜像摘要: $digest"

# ---- 晋升标签：从已验证的 sha 标签复制，不重新构建 ----
for t in $UB_PROMOTE_TAGS; do
  log "晋升 $UB_IMAGE:$t"
  skopeo copy --all --retry-times 3 "docker://$UB_IMAGE:$UB_PUSH_TAG" "docker://$UB_IMAGE:$t"
done

for t in $UB_PROMOTE_TAGS; do
  d2="$(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$UB_IMAGE:$t")"
  [ "$d2" = "$digest" ] || die "标签晋升后 digest 不一致：$UB_IMAGE:$t = $d2，期望 $digest"
done
log "标签晋升完成，全部指向 $digest"

mkdir -p "${UB_OUT:-/tmp/ub-out}"
python3 - "${UB_OUT:-/tmp/ub-out}/published.json" "$digest" <<'PY'
import json, os, sys
out = {
    "name": os.environ["UB_NAME"],
    "sha": os.environ["UB_SHA"],
    "version": os.environ["UB_VERSION"],
    "image": os.environ["UB_IMAGE"],
    "push_tag": os.environ["UB_PUSH_TAG"],
    "promoted_tags": os.environ.get("UB_PROMOTE_TAGS", "").split(),
    "digest": sys.argv[2],
    "platforms": os.environ.get("UB_DOCKER_TARGETS", "").split(),
    "status": "success",
}
json.dump(out, open(sys.argv[1], "w"), indent=2, ensure_ascii=False)
print(json.dumps(out, indent=2, ensure_ascii=False))
PY
