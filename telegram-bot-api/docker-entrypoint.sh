#!/bin/sh
# Telegram Bot API Server 启动入口
# 必需参数来自环境变量；EXTRA_ARGS 透传额外选项（如 --verbosity=2）
set -e

: "${TELEGRAM_API_ID:?TELEGRAM_API_ID is required (see .env)}"
: "${TELEGRAM_API_HASH:?TELEGRAM_API_HASH is required (see .env)}"

DIR=/var/lib/telegram-bot-api
mkdir -p "$DIR" "$DIR/temp" 2>/dev/null || true

exec /usr/local/bin/telegram-bot-api \
    --api-id="$TELEGRAM_API_ID" \
    --api-hash="$TELEGRAM_API_HASH" \
    --http-port="${HTTP_PORT:-8081}" \
    --dir="$DIR" \
    --temp-dir="$DIR/temp" \
    --local \
    $EXTRA_ARGS
