#!/usr/bin/env bash
# 验证计划书「模式 A：Go 直接编译」是否成立，以及它给的示例配置是否写对。
# 用 golang 容器跑，因此本机不需要装 Go。需要：docker。
# 用法：bash docs/verification/poc_go.sh
set -uo pipefail

WORK="${WORK:-$(mktemp -d)}"
mkdir -p "$WORK"
cd "$WORK"
echo "工作目录: $WORK"

if [ ! -d cline2api ] || [ ! -d cps ]; then
  curl -sL --max-time 120 -o c2a.tar.gz \
    "https://github.com/luawei1/cline2api/archive/refs/tags/v1.6.4.tar.gz"
  curl -sL --max-time 180 -o cps.tar.gz \
    "https://github.com/Hxjcc/cline-pass-switcher-go/archive/refs/heads/main.tar.gz"
  tar xzf c2a.tar.gz && mv cline2api-1.6.4 cline2api
  tar xzf cps.tar.gz
  CPS_DIR="$(find . -maxdepth 1 -type d -name 'cline-pass-switcher-go-*' | head -1)"
  mv "$CPS_DIR" cps
fi

G=golang:1.26-alpine

echo "########## A-1: cline2api 按上游 Dockerfile 的方式构建（go build .）##########"
docker run --rm -v "$PWD/cline2api:/src" -w /src -e CGO_ENABLED=0 \
  "$G" go build -ldflags="-s -w" -o /tmp/cline-proxy . 2>&1 | tail -10
echo "exit=${PIPESTATUS[0]}  （期望 0：main.go 有 //go:build !desktop，wails/CGO 不参与服务端构建）"

echo
echo "########## A-2: cline2api 的 go test ./...（计划 6.1 第 4 步要求）##########"
docker run --rm -v "$PWD/cline2api:/src" -w /src -e CGO_ENABLED=0 \
  "$G" sh -c 'go test ./... 2>&1 | tail -5'

echo
echo "########## A-3: cps 按计划书示例写 package=\".\" —— 预期失败 ##########"
docker run --rm -v "$PWD/cps:/src" -w /src -e CGO_ENABLED=0 \
  "$G" go build -o /tmp/out . 2>&1 | tail -5
echo "（期望：no Go files in /src —— 真实入口是 ./cmd/cline-pass-switcher）"

echo
echo "########## A-4: cps 用正确入口交叉编译 linux/amd64 + linux/arm64 + windows/amd64 ##########"
docker run --rm -v "$PWD/cps:/src" -w /src "$G" sh -c '
  set -e
  CGO_ENABLED=0 GOOS=linux   GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /tmp/cps-amd64 ./cmd/cline-pass-switcher
  CGO_ENABLED=0 GOOS=linux   GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o /tmp/cps-arm64 ./cmd/cline-pass-switcher
  CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -o /tmp/cps.exe ./cmd/cline-pass-switcher
  echo "三个目标全部编译成功"
  ls -la /tmp/cps-amd64 /tmp/cps-arm64 /tmp/cps.exe
'

echo
echo "########## A-5: cline2api arm64 交叉编译 ##########"
docker run --rm -v "$PWD/cline2api:/src" -w /src "$G" sh -c '
  CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o /tmp/c2a-arm64 . && echo "arm64 编译成功"'

echo
echo "结论：Go 交叉编译成立（一个 amd64 runner 可出多架构）；但计划书 §6.1 的 package=\".\" 对 cps 是错的。"
