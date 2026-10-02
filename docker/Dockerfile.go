# syntax=docker/dockerfile:1
#
# 平台生成的 Dockerfile 模板（upstream.json 里 docker.strategy = "generated"）。
#
# 什么时候用：项目能产出独立二进制、运行时依赖简单、不需要上游的资源文件与启动脚本。
# 什么时候不要用：上游 Dockerfile 里带前端构建、静态资源复制、启动脚本或特权处理
#   （例如 cline-pass-switcher-go 的 docker-entrypoint.sh 要做 PUID/PGID 降权），
#   这种情况必须用 strategy="upstream"，否则会静默丢掉这些行为。
#
# 只实现了 Go。Python / Node 请在 docker/ 下自行添加 Dockerfile.python / Dockerfile.node。

ARG GO_IMAGE=golang:1.26-alpine
FROM ${GO_IMAGE} AS builder

WORKDIR /src
COPY . .

ARG GO_PACKAGE=.
ARG APP_LDFLAGS=-s -w
ARG APP_BINARY=app
ARG CGO_ENABLED=0

RUN CGO_ENABLED=${CGO_ENABLED} GOOS=linux \
    go build -trimpath -ldflags="${APP_LDFLAGS}" -o "/out/${APP_BINARY}" "${GO_PACKAGE}"

ARG BASE_IMAGE=alpine:3.22
FROM ${BASE_IMAGE}

RUN apk add --no-cache ca-certificates tzdata

ARG APP_BINARY=app
ARG APP_NAME=app
# 固定安装到 /usr/local/bin/app：exec 形式的 ENTRYPOINT 不做变量替换，
# 用 ${APP_BINARY} 拼路径会得到一个指向字面量 "${APP_BINARY}" 的坏 ENTRYPOINT。
COPY --from=builder "/out/${APP_BINARY}" "/usr/local/bin/app"

# 注意：不要在这里臆造端口/启动参数。端口与运行参数由项目的 README 决定，
# 若项目需要，请在 upstream.json 里显式配置 docker.env / docker.exposed_ports。
ENV APP_NAME=${APP_NAME}
ENV APP_BINARY=${APP_BINARY}
ENTRYPOINT ["/usr/local/bin/app"]
