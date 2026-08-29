# syntax=docker/dockerfile:1
# ============================================================
# Telegram Bot API Server（官方源码多阶段构建）
# 上游：https://github.com/tdlib/telegram-bot-api
# 以 --local 模式运行：上传上限 2000MB、下载无限制（OtterHub 2GB 方案核心）
# 官方 server 仅支持 HTTP，TLS 终止由前置 Caddy 负责（见 docker-compose.yml）
# ============================================================

# 上游引用：分支名（master）或 40 位 commit SHA（固定版本、构建可复现）
ARG TBA_REF=master

# ---------- 构建阶段：编译官方 telegram-bot-api ----------
FROM ubuntu:24.04 AS builder
ARG TBA_REF
ARG DEBIAN_FRONTEND=noninteractive

# 依赖：gperf 为上游 README 列出的必需构建工具
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential g++ make cmake git gperf \
        libssl-dev zlib1g-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# 浅克隆指定 ref（分支或 SHA），并拉取 tdlib 子模块
RUN git init . \
    && git remote add origin https://github.com/tdlib/telegram-bot-api.git \
    && git fetch --depth 1 origin "${TBA_REF}" \
    && git checkout --detach FETCH_HEAD \
    && git submodule update --init --recursive --depth 1

# 编译并安装到 /usr/local/bin（完整 TDLib 编译，约 15~35 分钟）
RUN mkdir -p build && cd build \
    && cmake -DCMAKE_BUILD_TYPE=Release .. \
    && cmake --build . --target install -j"$(nproc)"

# ---------- 运行阶段 ----------
FROM ubuntu:24.04
ARG DEBIAN_FRONTEND=noninteractive

# 最小运行时依赖：libssl3 / zlib / CA 证书 / curl(健康检查)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libssl3 zlib1g ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -r tba \
    && useradd -r -g tba -d /var/lib/telegram-bot-api -s /sbin/nologin tba \
    && mkdir -p /var/lib/telegram-bot-api \
    && chown -R tba:tba /var/lib/telegram-bot-api

COPY --from=builder /usr/local/bin/telegram-bot-api /usr/local/bin/telegram-bot-api
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# 非 root 运行
USER tba
WORKDIR /var/lib/telegram-bot-api

# bot 会话与 file_id 数据库所在目录（建议挂卷持久化）
VOLUME ["/var/lib/telegram-bot-api"]

ENV HTTP_PORT=8081
EXPOSE 8081

# 健康检查：server 对无效 bot token 返回 404 JSON，
# 只要 HTTP 层有响应即认为进程存活（curl 无 -f，连接失败才退出非零）
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -s -o /dev/null "http://127.0.0.1:${HTTP_PORT}/bot000:health/getMe" || exit 1

ENTRYPOINT ["docker-entrypoint.sh"]
