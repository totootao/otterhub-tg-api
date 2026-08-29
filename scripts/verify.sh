#!/usr/bin/env bash
# 部署后全链路验证：Caddy TLS → 令牌校验 → telegram-bot-api → Telegram
# 用法：
#   TG_DOMAIN=tg.example.com PROXY_TOKEN=xxx ./scripts/verify.sh <BOT_TOKEN>
set -euo pipefail

TG_DOMAIN="${TG_DOMAIN:?环境变量 TG_DOMAIN 未设置}"
PROXY_TOKEN="${PROXY_TOKEN:?环境变量 PROXY_TOKEN 未设置}"
BOT_TOKEN="${1:?用法: TG_DOMAIN=... PROXY_TOKEN=... $0 <BOT_TOKEN>}"

BASE="https://${TG_DOMAIN}"

echo "[1/3] getMe（带令牌，应返回 ok:true）"
curl -fsS -H "x-proxy-token: ${PROXY_TOKEN}" \
    "${BASE}/bot${BOT_TOKEN}/getMe" | head -c 300; echo; echo

echo "[2/3] 令牌防护（不带令牌，应返回 403）"
code=$(curl -s -o /dev/null -w "%{http_code}" "${BASE}/bot${BOT_TOKEN}/getMe")
if [ "$code" = "403" ]; then
    echo "  ✓ 无令牌访问被拒绝（HTTP 403）"
else
    echo "  ✗ 预期 403，实际 ${code} —— 检查 Caddyfile 令牌校验是否生效"
fi
echo

echo "[3/3] getWebhookInfo（检查 bot 登录状态）"
curl -fsS -H "x-proxy-token: ${PROXY_TOKEN}" \
    "${BASE}/bot${BOT_TOKEN}/getWebhookInfo" | head -c 300; echo

echo
echo "提示：bot 若原挂云端，需先 curl https://api.telegram.org/bot${BOT_TOKEN}/logOut"
