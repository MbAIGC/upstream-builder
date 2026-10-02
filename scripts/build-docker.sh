#!/usr/bin/env bash
# 镜像构建：先做单架构 smoke 门禁（--load 后真跑容器），再做多架构 OCI archive 导出。
#
# 本脚本运行在「只读凭据」的构建 Job 里：它只产出 OCI archive，不 push、不登录任何 registry。
# 真正的推送与标签晋升在 publish-image.sh（可信 Job）里完成。
# 这样上游 Dockerfile / build 脚本即使被投毒，也拿不到 packages:write。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

: "${UB_SRC:?}" "${UB_OUT:?}"
is_true "${UB_DOCKER_ENABLED:-false}" || { log "docker.enabled=false，跳过镜像构建"; exit 0; }
[ -n "${UB_DOCKER_TARGETS// /}" ] || { log "没有 docker targets，跳过镜像构建"; exit 0; }
need docker

# 平台列表只从 UB_DOCKER_TARGETS 推导（单一事实来源）。
# 之前的写法另外维护了一个 UB_DOCKER_PLATFORMS，矩阵收窄目标时两者会不一致，
# 结果在一个没有 arm64 模拟器的 runner 上仍然去构建 arm64 -> exec format error。
platforms="${UB_DOCKER_TARGETS// /,}"   # 纯 bash 展开：printf '%s' $VAR 会把多个词粘连
log "docker targets: [$UB_DOCKER_TARGETS] -> platforms=$platforms"

mkdir -p "$UB_OUT"
archive="$UB_OUT/image.tar"
rm -f "$archive"

dockerfile_src="$UB_SRC/$UB_DOCKERFILE"
context_dir="$UB_SRC/$UB_DOCKER_CONTEXT"
if [ "${UB_DOCKER_STRATEGY}" = "generated" ]; then
  dockerfile_src="$UB_REPO_ROOT/docker/Dockerfile.${UB_LANGUAGE}"
  log "使用平台生成的 Dockerfile: $dockerfile_src（上下文仍是上游快照，未修改上游）"
fi
[ -f "$dockerfile_src" ] || die "Dockerfile 不存在: $dockerfile_src"
[ -d "$context_dir" ] || die "构建上下文不存在: $context_dir"

# ---- 构建参数 ----
declare -a build_args=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  build_args+=(--build-arg "$line")
done < <(json_to_env_lines "${UB_BUILD_ARGS_JSON:-{}}")
if [ "${UB_DOCKER_STRATEGY}" = "generated" ]; then
  build_args+=(--build-arg "BASE_IMAGE=${UB_BASE_IMAGE:-alpine:3.22}")
  build_args+=(--build-arg "GO_IMAGE=golang:${UB_GO_VERSION:-1.26}-alpine")
  build_args+=(--build-arg "APP_BINARY=$UB_BINARY")
  build_args+=(--build-arg "APP_NAME=$UB_NAME")
  build_args+=(--build-arg "GO_PACKAGE=${UB_PACKAGE:-.}")
  build_args+=(--build-arg "APP_LDFLAGS=${UB_LDFLAGS:--s -w}")
fi

# provenance/sbom：默认关闭。开启会让 GHCR 出现 unknown/unknown 架构条目，且会让 digest 漂移。
declare -a prov=(--provenance=false --sbom=false)
if is_true "${UB_DOCKER_PROVENANCE:-false}"; then
  prov=(--provenance=true)
  warn "docker.provenance=true：GHCR 上会出现 unknown/unknown 架构条目，下游 digest 也可能漂移"
fi

declare -a cache_args=()
if is_true "${UB_CACHE:-false}"; then
  cache_args=(--cache-from "type=gha,scope=ub-${UB_ENTRY:-$UB_NAME}" --cache-to "type=gha,mode=max,scope=ub-${UB_ENTRY:-$UB_NAME}")
fi

# ---------- 1) smoke 门禁：单架构 --load，真跑起来检查 ----------
if [ -n "${UB_SMOKE_PATH:-}" ] || [ -n "${UB_SMOKE_COMMAND:-}" ]; then
  smoke_tag="ub-smoke-${UB_NAME}:${UB_SHORT_SHA}"
  group "smoke 门禁：构建单架构镜像并实际启动 (linux/${UB_SMOKE_ARCH})"
  docker buildx build \
    --platform "linux/${UB_SMOKE_ARCH}" \
    --file "$dockerfile_src" \
    --load \
    --tag "$smoke_tag" \
    "${prov[@]}" "${cache_args[@]}" "${build_args[@]}" \
    "$context_dir"

  cid="$(docker run -d --name "ub-smoke-${UB_NAME}" \
          -p "127.0.0.1::${UB_SMOKE_PORT:-80}" \
          -e "DATA_DIR=/data" \
          ${UB_SMOKE_ENV_ARGS:-} \
          "$smoke_tag" ${UB_SMOKE_CONTAINER_CMD:-} )"
  cleanup_smoke() {
    docker logs "ub-smoke-${UB_NAME}" >&2 || true
    docker rm -f "ub-smoke-${UB_NAME}" >/dev/null 2>&1 || true
  }
  trap cleanup_smoke EXIT

  timeout_s="${UB_SMOKE_TIMEOUT:-60}"
  ok=0
  if [ -n "${UB_SMOKE_COMMAND:-}" ]; then
    log "smoke：等待容器就绪后执行自定义命令"
    sleep 3
    for _ in $(seq 1 "$timeout_s"); do
      if docker exec "ub-smoke-${UB_NAME}" sh -c "$UB_SMOKE_COMMAND" >/dev/null 2>&1; then ok=1; break; fi
      sleep 1
    done
  else
    host_port="$(docker port "ub-smoke-${UB_NAME}" "${UB_SMOKE_PORT}/tcp" 2>/dev/null | head -1 | awk -F: '{print $NF}')"
    [ -n "$host_port" ] || die "无法获取映射端口（容器可能已退出）"
    url="http://127.0.0.1:${host_port}${UB_SMOKE_PATH}"
    log "smoke：轮询 $url，期望状态码 [${UB_SMOKE_EXPECT:-200}]，最多 ${timeout_s}s"
    for _ in $(seq 1 "$timeout_s"); do
      code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$url" || echo 000)"
      if printf ',%s,' "${UB_SMOKE_EXPECT:-200}" | grep -q ",${code},"; then ok=1; break; fi
      sleep 1
    done
    [ "$ok" = "1" ] || warn "最后一次状态码: ${code:-none}"
  fi
  docker logs "ub-smoke-${UB_NAME}" 2>&1 | tail -20 || true
  trap - EXIT
  cleanup_smoke
  [ "$ok" = "1" ] || die "smoke 检查未通过，拒绝继续构建镜像（不会污染任何已发布标签）"
  log "smoke 检查通过"
  group_end
else
  warn "未配置 docker.smoke，跳过启动检查（风险：计划 6.2/7.2 要求的『验证后才发布』形同虚设）"
fi

# ---------- 2) 多架构构建，只导出 OCI archive（不 push） ----------
group "多架构构建 -> OCI archive（无 registry 凭据）"
log "platforms=$platforms  标签=$UB_IMAGE:$UB_PUSH_TAG"
docker buildx build \
  --platform "$platforms" \
  --file "$dockerfile_src" \
  --output "type=oci,dest=${archive},oci-mediatypes=true" \
  --tag "$UB_IMAGE:$UB_PUSH_TAG" \
  "${prov[@]}" "${cache_args[@]}" "${build_args[@]}" \
  "$context_dir"
group_end

[ -s "$archive" ] || die "OCI archive 未生成: $archive"
log "OCI archive 就绪: $archive ($(du -h "$archive" | cut -f1))"

# 记录本次镜像元数据，供可信发布 Job 使用（不依赖 artifact 之外的信息）
python3 - "$UB_OUT/image-meta.json" <<'PY'
import json, os, sys
keys = ["UB_NAME","UB_IMAGE","UB_PUSH_TAG","UB_PROMOTE_TAGS","UB_DOCKER_TARGETS","UB_DOCKER_TARGETS_ALL",
        "UB_SHA","UB_VERSION","UB_SHORT_SHA","UB_RELEASE_TAG","UB_DOCKER_STRATEGY",
        "UB_ENTRY","UB_LANGUAGE","UB_METHOD"]
meta = {k.replace("UB_","",1).lower(): os.environ.get(k,"") for k in keys}
json.dump(meta, open(sys.argv[1],"w"), indent=2, ensure_ascii=False)
print("meta:", json.dumps(meta, ensure_ascii=False))
PY
