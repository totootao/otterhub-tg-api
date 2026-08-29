# OtterHub TG API Server（2GB 方案）

自建 Telegram Bot API Server 基础设施仓库，对应 otterhub-server README 中的 TODO：

> 申请 TG API ID，自建 Telegram Bot API Server，单个文件下载上限可提升至 2GB

采用官方 [tdlib/telegram-bot-api](https://github.com/tdlib/telegram-bot-api) 以 `--local` 模式运行，突破云端 API 的文件大小限制，为 OtterHub 大文件上传/下载提供底座。

## 效果对比

| 能力 | 云端 api.telegram.org | 本项目（--local 模式） |
|---|---|---|
| 单文件上传上限 | 50 MB | 2000 MB |
| 单文件下载上限 | 20 MB | 2000 MB（官方口径"无限制"） |
| Webhook | 仅 HTTPS + 固定端口 443/80/88/8443 | HTTP、任意 IP/端口、最多 10 万并发连接 |
| 上传方式 | multipart 传输 | 额外支持本地路径与 `file://` URI |
| `getFile` 返回的 file_path | 相对路径 | 绝对本地路径 |

> OtterHub 当前 `MAX_CHUNK_SIZE = 20MB` 正是受云端 20MB 下载上限约束；切换到本服务后即可提升分片尺寸。

## 架构

```
Cloudflare Worker / otterhub-server
        │  HTTPS 443（自动携带 x-proxy-token 头）
        ▼
┌─────────────────────────────┐
│  Caddy（TLS 终止 + 令牌校验） │  ← 对外域名 TG_DOMAIN
└──────────────┬──────────────┘
               │  HTTP 8081（仅容器网络内部）
               ▼
┌─────────────────────────────────────────┐
│  telegram-bot-api 容器（--local 模式）    │
│  上传 2000MB / 下载无限制 / HTTP only    │
└──────────────┬──────────────────────────┘
               │  MTProto（TCP 443 直连 Telegram DC）
               ▼
        Telegram 数据中心
```

要点：

- 官方 server 只接受 HTTP，必须前置 TLS 终止代理（Caddy 负责自动签发 Let's Encrypt 证书）
- `x-proxy-token` 校验与 otterhub-server 的 `tg-proxy.ts` 约定完全一致：`TG_API_BASE` 配成对象数组时，`tgFetch` 会自动附加该头
- 8081 不对外暴露，只有 Caddy 能访问

## 前置条件

1. **TG API 凭证**（你已申请）：[my.telegram.org](https://my.telegram.org) → API development tools，得到 `api_id` + `api_hash`
2. **一个域名**：划一个子域名（如 `tg.example.com`）做 A 记录指向服务器公网 IP，**务必 DNS only（灰云）**
   - 原因一：Cloudflare 代理（橙云）对请求体有 100MB 上限，会掐断大文件上传
   - 原因二：灰云直连时 Caddy 才能通过 HTTP-01 挑战自动签证书
3. **服务器**：Docker + Docker Compose；**必须能直连 Telegram DC**（MTProto，TCP 443）
   - 国内服务器通常出站不通 Telegram：要么把本服务部署在海外 VPS，要么用 iptables 透明转发把到 Telegram DC 网段的流量转给可出墙的出口（注意：TDLib 不读 `HTTP_PROXY` 环境变量）
4. **构建资源**：首次源码编译约需 2GB+ 内存、20~40 分钟（CI 或服务器上构建均可）

## 快速开始

```bash
# 1. 拉取本仓库
git clone https://github.com/totootao/otterhub-tg-api.git
cd otterhub-tg-api

# 2. 配置
cp .env.example .env
#    填写 TELEGRAM_API_ID / TELEGRAM_API_HASH / TG_DOMAIN / PROXY_TOKEN

# 3. 启动（首次在服务器上源码构建，约 20~40 分钟）
#    若已配置 Docker Hub 镜像可省去 --build
docker compose up -d --build

# 4. 全链路验证（替换为你的 Bot Token）
TG_DOMAIN=tg.example.com PROXY_TOKEN=xxx ./scripts/verify.sh 123456:ABC-xxxx
```

验证通过后，`https://<TG_DOMAIN>` 就是你的专属 Bot API 端点，接口路径与 `api.telegram.org` 完全一致（`/bot<token>/<method>`、`/file/bot<token>/<path>`）。

## 迁移现有 Bot（重要）

把已经在云端 `api.telegram.org` 注册过 webhook 的 bot 迁到本地 server 前，**必须先在云端登出**：

```bash
curl "https://api.telegram.org/bot<TOKEN>/logOut"
```

两条关键事实：

- 同一 bot 同时登录两台 server 时无法保证收到全部 updates
- **file_id 不跨 server**：本地 server 的 file_id 映射存在自己的工作目录（`/var/lib/telegram-bot-api`）里，云端时期签发的 file_id 在本地 server 上大概率无法解析

因此对 OtterHub 的迁移策略建议采用**双模式**：Bot 池中保留部分 bot 继续挂云端（负责旧文件下载），新增/迁移部分 bot 挂本地 server（负责新文件上传下载），由 otterhub-server 按分片元数据记录的来源路由。详见下节。

## 与 otterhub-server 集成（待实施）

本仓库只解决基础设施；应用侧改动在 otterhub-server 中进行（另一条 TODO）：

1. **`TG_API_BASE` 直接指向本服务**（`tg-proxy.ts` 已支持，零改动即可生效）：

   ```
   TG_API_BASE='[{"base":"https://tg.example.com","token":"<PROXY_TOKEN>"}]'
   ```

   `tgFetch` 会把所有 `https://api.telegram.org/...` 请求改写到该地址并附加 `x-proxy-token` 头，上传（sendDocument）与下载（`/file/bot<token>/...`）两条链路都会走过来。

2. **`MAX_CHUNK_SIZE` 调整**：`shared/src/types/index.ts` 中从 20MB 提升。建议 100~512MB，不要一步到 2000MB：
   - Cloudflare Worker 出站 fetch 走 443 无请求体大小硬限制，但链路带宽与超时（现有代码按 0.3~0.5MB/s 动态估算超时）决定了单片过大易超时
   - 分片数减少 → TG 消息数、KV 元数据量、请求次数同步下降

3. **旧文件兼容路由**：按分片 KV 元数据记录的上传来源，将云端时期文件路由到 `api.telegram.org`，本地时期文件路由到本服务（涉及 `tg-adapter.ts` 下载链路改造）

4. **bot 池分工**：tg-pool 中标记各 slot 归属（cloud / local），上传分配与下载取 token 时按归属选择

## 常见问题

**Q: 为什么用 443，不用 8081 直连？**
Cloudflare Workers 出站 fetch 仅支持部分端口（80/443/8080/8443/2052 等）；且 server 只支持 HTTP，明文暴露 bot token 有风险，必须 TLS。443 是唯一通用选择。若服务器 443 被占用，可在 compose 里把 Caddy 改映射到 8443（也在允许列表内）。

**Q: 数据存在哪？**
`/var/lib/telegram-bot-api`（compose 具名卷 `tba-data`），包含各 bot 的会话与 file_id 数据库，删除卷 = 所有 bot 需重新 logOut 迁移。Caddy 证书存于 `caddy-data` 卷。

**Q: 怎么升级到上游新版本？**
两种方式：
- 服务器上：`git pull && docker compose up -d --build`（Dockerfile 默认跟随上游 master）
- CI：每周一 04:00 UTC 自动重建；配置好 Docker Hub Secrets 后也会自动推送新镜像

**Q: 怎么固定版本？**
上游仓库没有发 tag，用 commit SHA 固定。在 `.env` 中设置 `TBA_REF=<40位SHA>` 后 `docker compose build`。已验证可用快照：`e3e9dd8e5b3d7ab8537cd5a10dc31d5ffa8f82d1`（2026-08-25）。

**Q: 首次 CI 构建显示"仅构建验证，未推送"？**
本仓库还未配置 `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` Secrets（Secrets 不跨仓库共享）。到仓库 Settings → Secrets and variables → Actions 添加后，手动触发 workflow 并勾选 `push_image` 即可推送镜像 `totootao/otterhub-tg-api`。

**Q: 健康检查原理？**
镜像内置 HEALTHCHECK 对 `/bot000:health/getMe` 发请求——server 对无效 token 会返回 404 JSON，只要 HTTP 有响应即视为进程存活。

## 目录结构

```
├── telegram-bot-api/
│   ├── Dockerfile              # 官方源码多阶段构建（--local）
│   └── docker-entrypoint.sh    # 参数拼装（api-id/api-hash/dir/local）
├── caddy/
│   └── Caddyfile               # TLS 终止 + x-proxy-token 校验 + 流式反代
├── scripts/
│   └── verify.sh               # 部署后全链路验证
├── docker-compose.yml          # 一键编排
└── .github/workflows/
    └── docker-image.yml         # CI 构建 + Docker Hub 推送 + 每周跟随上游重建
```

## 许可

本仓库的配置与文档以 [MIT](LICENSE) 发布。
容器内编译的 `telegram-bot-api` 来自上游 [tdlib/telegram-bot-api](https://github.com/tdlib/telegram-bot-api)，其源码遵循 [Boost Software License](http://www.boost.org/LICENSE_1_0.txt)，与本仓库许可相互独立。
