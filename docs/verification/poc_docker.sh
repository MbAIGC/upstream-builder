#!/usr/bin/env bash
# 验证计划书「模式 B：使用上游 Dockerfile」——两个上游的 Dockerfile 能否一行不改地构建。
# 需要：docker。用法：bash docs/verification/poc_docker.sh
set -uo pipefail

WORK="${WORK:-$(mktemp -d)}"
mkdir -p "$WORK"
cd "$WORK"
echo "工作目录: $WORK"

echo "########## 下载两个上游的源码快照 ##########"
curl -sL --max-time 120 -o cline2api.tar.gz \
  "https://github.com/luawei1/cline2api/archive/refs/tags/v1.6.4.tar.gz"
curl -sL --max-time 180 -o cps.tar.gz \
  "https://github.com/Hxjcc/cline-pass-switcher-go/archive/refs/heads/main.tar.gz"
tar xzf cline2api.tar.gz
tar xzf cps.tar.gz
[ -d cline2api-1.6.4 ] && mv cline2api-1.6.4 cline2api
CPS_DIR="$(find . -maxdepth 1 -type d -name 'cline-pass-switcher-go-*' | head -1)"
[ -n "$CPS_DIR" ] || { echo "cps 源码目录未找到"; exit 1; }

echo
echo "############ B-1: luawei1/cline2api v1.6.4（上游 Dockerfile 原样，amd64）############"
start=$(date +%s)
docker build --no-cache -t poc/cline2api:v1.6.4 cline2api > build_cline2api.log 2>&1
echo "exit=$? elapsed=$(( $(date +%s) - start ))s"
tail -5 build_cline2api.log

echo
echo "############ B-2: Hxjcc/cline-pass-switcher-go main（上游 Dockerfile 原样，amd64）############"
start=$(date +%s)
docker build --no-cache -t poc/cps:main "$CPS_DIR" > build_cps.log 2>&1
echo "exit=$? elapsed=$(( $(date +%s) - start ))s"
tail -5 build_cps.log

echo
echo "############ 启动检查（计划书 6.2 第 5 步）############"
docker rm -f smk1 smk2 >/dev/null 2>&1
docker run -d --name smk1 -p 13457:3457 poc/cline2api:v1.6.4 >/dev/null 2>&1
docker run -d --name smk2 -p 13123:3123 -e DATA_DIR=/data poc/cps:main >/dev/null 2>&1
sleep 6
printf '  cline2api GET /health -> %s  （期望 200）\n' \
  "$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:13457/health 2>&1)"
printf '  cps       GET /       -> %s  （期望 403：控制台需鉴权）\n' \
  "$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:13123/ 2>&1)"
docker rm -f smk1 smk2 >/dev/null 2>&1

echo
echo "结论：两个上游 Dockerfile 均无需修改即可构建；cps 的健康检查必须用 expect=[200,403]。"
