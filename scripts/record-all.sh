#!/usr/bin/env bash
# 汇总记录 Job：把各构建 entry 的 result.json（+ 发布产出的 published/released）写进状态文件，
# 并生成构建报告。本脚本不执行上游代码，因此可以持有 contents:write。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

: "${UB_ARTIFACTS:?UB_ARTIFACTS 未设置}"
run_id="${UB_RUN_ID:-local}"
results_dir="${UB_RESULTS_DIR:-reports/run-results}"
mkdir -p "$results_dir"

# 发布元数据（published.json / released.json）由发布 Job 单独上传成一个 artifact，
# 不在 result.json 同目录。按项目名建索引，否则镜像摘要永远取不到（计划 7.2/11.2 要求记录）。
declare -A PUB_BY_NAME REL_BY_NAME
while read -r f; do
  [ -n "$f" ] || continue
  n="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name",""))' "$f" 2>/dev/null || true)"
  [ -n "$n" ] && PUB_BY_NAME["$n"]="$f"
done < <(find "$UB_ARTIFACTS" -name 'published*.json' 2>/dev/null)
while read -r f; do
  [ -n "$f" ] || continue
  n="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name",""))' "$f" 2>/dev/null || true)"
  [ -n "$n" ] && REL_BY_NAME["$n"]="$f"
done < <(find "$UB_ARTIFACTS" -name 'released*.json' 2>/dev/null)

failed=0
count=0

# result.json 是每个 matrix entry 都会产出的（构建失败也会产出）
while read -r res; do
  [ -n "$res" ] || continue
  dir="$(dirname "$res")"
  read -r name status sha version method < <(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get("name",""), d.get("status",""), d.get("sha",""), d.get("version",""), d.get("method",""))
' "$res")
  # 失败原因单独取，避免空格被 shell 拆开
  error="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("error") or "")' "$res")"
  [ -n "$name" ] || continue
  count=$((count + 1))

  digest=""; image=""; release_tag=""
  pub="${PUB_BY_NAME[$name]:-}"
  [ -n "$pub" ] || pub="$dir/published.json"
  if [ -f "$pub" ]; then
    read -r digest image < <(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get("digest",""), d.get("image",""))
' "$pub")
  fi
  # release_tag 优先取发布结果，取不到就用构建结果里的（result.json 已带该字段）
  rel="${REL_BY_NAME[$name]:-}"
  [ -n "$rel" ] || rel="$dir/released.json"
  if [ -f "$rel" ]; then
    release_tag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("release_tag",""))' "$rel")"
  fi
  if [ -z "$release_tag" ]; then
    release_tag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("release_tag",""))' "$res")"
  fi

  platforms="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(",".join(d.get("docker_targets") or d.get("targets") or []))
' "$res")"

  # 同一个项目在原生 arm runner 路径下会有多个 entry：任一 entry 失败就算该项目失败
  set +e
  python3 "$UB_REPO_ROOT/scripts/ub.py" record \
    --project "$name" --status "$status" --sha "$sha" --version "$version" \
    --method "$method" --platforms "$platforms" \
    ${image:+--image "$image"} ${digest:+--image-digest "$digest"} \
    ${error:+--error "$error"} \
    ${release_tag:+--release-tag "$release_tag"} \
    --run-id "$run_id" --results-dir "$results_dir" 2>&1 | tail -2
  rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" -eq 0 ] || { warn "记录 $name 状态失败（rc=$rc）"; failed=$((failed + 1)); }
  [ "$status" = "success" ] || failed=$((failed + 1))
done < <(find "$UB_ARTIFACTS" -name 'result.json' | sort)

[ "$count" -gt 0 ] || die "没有找到任何 result.json（构建阶段可能整体失败）"

# 同一项目多 entry 时结果目录里最后写入的会覆盖前面的；用「任一失败即失败」修正
python3 - "$results_dir" <<'PY'
import json, sys
from pathlib import Path
d = Path(sys.argv[1])
for f in sorted(d.glob("*.json")):
    r = json.loads(f.read_text())
    if r.get("status") != "success":
        continue
    # 如果同名项目在别处有失败记录，就标记为失败
    for g in d.glob("*.json"):
        if g == f:
            continue
        o = json.loads(g.read_text())
        if o.get("name") == r.get("name") and o.get("status") != "success":
            r["status"] = "failure"
            r["error"] = (r.get("error") or "") + " (同项目其它架构构建失败)"
            f.write_text(json.dumps(r, indent=2, ensure_ascii=False))
            break
PY

python3 "$UB_REPO_ROOT/scripts/ub.py" report \
  --run-id "$run_id" --results-dir "$results_dir" --out reports/build-report.json

log "记录完成：$count 个 entry，$failed 个失败"
[ "$failed" -eq 0 ] || exit 1
