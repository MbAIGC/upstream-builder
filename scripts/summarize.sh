#!/usr/bin/env bash
# 把一个 entry 的构建结果写成 Markdown（喂给 $GITHUB_STEP_SUMMARY）。
# 单独成脚本的原因：内联多行 python 会打断 workflow 的 YAML 块标量。
set -euo pipefail

result="${1:-${UB_OUT:?UB_OUT 未设置}/result.json}"

python3 - "$result" <<'PY'
import json
import sys

try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"- 没有 result.json（{e}）")
    raise SystemExit(0)

entry = d.get("entry") or d.get("name") or "?"
print(f"### {entry}")
print()
print(f"- 状态: **{d.get('status')}**")
print(f"- 上游: `{(d.get('sha') or '')[:12]}`  version={d.get('version') or '-'}")
print(f"- 方式: {d.get('language') or '-'}/{d.get('method') or '-'}  runner={d.get('runner') or '-'}")
print(f"- 二进制目标: {', '.join(d.get('targets') or []) or '-'}")
print(f"- 镜像目标: {', '.join(d.get('docker_targets') or []) or '-'}")
if d.get("packages"):
    print(f"- 发布包: {', '.join(d['packages'])}")
if d.get("release_tag"):
    print(f"- Release tag: `{d['release_tag']}`")
if d.get("error"):
    print(f"- 失败步骤: {d['error']}")
print()
PY
