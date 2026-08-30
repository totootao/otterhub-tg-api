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
               │  MTProto（TCP 443 连 Telegram DC）
               │  ← 可选：TG_PROXY 配置后全部流量经代理转发
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
3. **服务器**：Docker + Docker Compose；需能连上 Telegram DC（MTProto，TCP 443）
   - 海外 VPS：开箱直连，无需任何额外配置
   - 国内服务器：出站通常不通 Telegram，配置 `TG_PROXY` 即可（见下节「代理模式」，原生 MTProto 代理支持，无需 iptables/透明代理/TUN）
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

## 单容器运行（docker run）

不需要 Caddy/TLS 全套编排时（内网测试、已有自研网关等场景），可以只跑 `telegram-bot-api` 一个容器：

```bash
docker run -d \
  --name telegram-bot-api \
  --restart unless-stopped \
  -p 8081:8081 \
  -e TELEGRAM_API_ID=<你的api_id> \
  -e TELEGRAM_API_HASH=<你的api_hash> \
  -v tba-data:/var/lib/telegram-bot-api \
  totootao/otterhub-tg-api:latest
```

需要出站代理（国内服务器）时加一个 `-e TELEGRAM_PROXY`，语义与 compose 里的 `TG_PROXY` 完全一致：

```bash
docker run -d \
  --name telegram-bot-api \
  --restart unless-stopped \
  -p 8081:8081 \
  -e TELEGRAM_API_ID=<你的api_id> \
  -e TELEGRAM_API_HASH=<你的api_hash> \
  -e TELEGRAM_PROXY=socks5://user:password@proxy-host:1080 \
  -v tba-data:/var/lib/telegram-bot-api \
  totootao/otterhub-tg-api:latest
```

**代理跑在宿主机上（如同机 Clash `127.0.0.1:7890`）**：默认 bridge 网络里容器内的 `127.0.0.1` 指向容器自身而非宿主机，改用 `--network host` 共享宿主机网络栈（此时 `-p` 映射失效，服务直接监听宿主机 8081）：

```bash
docker run -d \
  --name telegram-bot-api \
  --restart unless-stopped \
  --network host \
  -e TELEGRAM_API_ID=<你的api_id> \
  -e TELEGRAM_API_HASH=<你的api_hash> \
  -e TELEGRAM_PROXY=socks5://127.0.0.1:7890 \
  -v tba-data:/var/lib/telegram-bot-api \
  totootao/otterhub-tg-api:latest
```

参数说明：

| 参数 | 说明 |
|---|---|
| `-p 8081:8081` | 容器 8081 映射到宿主机 8081；HTTP 明文，仅限内网/测试 |
| `-e TELEGRAM_API_ID` / `-e TELEGRAM_API_HASH` | 必填，[my.telegram.org](https://my.telegram.org) 申请 |
| `-e TELEGRAM_PROXY` | 可选，MTProto 出站代理 URL（等价于 `--mtproto-proxy` 选项），留空直连 |
| `-e EXTRA_ARGS` | 可选，透传额外启动参数，如 `--verbosity=2` |
| `-e HTTP_PORT` | 可选，改容器内监听端口（默认 8081，配合 `-p` 使用） |
| `-v tba-data:/var/lib/telegram-bot-api` | bot 会话 + file_id 数据库持久化；删卷 = 所有 bot 需重新 logOut 迁移 |

启动后验证：

```bash
docker ps --filter name=telegram-bot-api        # STATUS 应显示 (healthy)，镜像内置 HEALTHCHECK
docker logs telegram-bot-api 2>&1 | grep -i proxy  # 配了代理应出现 MTProto proxy enabled
curl -s "http://127.0.0.1:8081/bot000:health/getMe"  # 有 JSON 响应即 HTTP 层存活
```

两条注意事项：

- **明文风险**：直连 8081 没有 TLS，bot token 在 HTTP 里裸奔。仅限内网或已有 TLS 网关的场景；公网部署请回到 compose 全套（Caddy 自动 TLS + `x-proxy-token` 校验）
- **镜像来源**：`docker run` 直接拉 `totootao/otterhub-tg-api:latest` 的前提是 Docker Hub Secrets 已配置并完成过推送（见常见问题）。镜像还没推上去时，先在仓库根目录本地构建再运行：

  ```bash
  docker build -t otterhub-tg-api:local telegram-bot-api/
  docker run -d --name telegram-bot-api --restart unless-stopped \
    -p 8081:8081 \
    -e TELEGRAM_API_ID=<你的api_id> -e TELEGRAM_API_HASH=<你的api_hash> \
    -v tba-data:/var/lib/telegram-bot-api \
    otterhub-tg-api:local
  ```

## 代理模式（国内服务器）

官方 `telegram-bot-api` 二进制本身不支持给 MTProto 连接配代理（自带的 `--proxy` 选项只管 webhook 出站）。本仓库给上游源码打了一个补丁（`telegram-bot-api/patches/0001-mtproto-proxy.patch`），调用 **TDLib 原生的 `addProxy` 能力**，在 TDLib 发起到 DC 的任何连接之前注册并启用代理——bot 登录、消息收发、2GB 文件上传下载，全部流量走代理。配置风格参考 [tangyoha/telegram_media_downloader](https://github.com/tangyoha/telegram_media_downloader) 的 proxy 配置（scheme/hostname/port/username/password），此处统一为 URL 写法。

在 `.env` 中取消注释并填写：

```bash
# Clash/V2Ray 常见的 SOCKS5（最常用）
TG_PROXY=socks5://127.0.0.1:7890
# 带认证：socks5://user:password@host:port
# HTTP 代理（需支持 HTTP CONNECT 透明隧道）：http://host:port
# MTProto 代理：mtproto://secret@host:port
```

然后 `docker compose up -d` 重新创建容器即可。生效验证：`docker compose logs telegram-bot-api` 会出现 `Adding MTProto proxy 127.0.0.1:7890` 与 `MTProto proxy enabled for all connections to Telegram DCs`。

细节说明：

- **等价的命令行/环境变量**：补丁同时给二进制增加了 `--mtproto-proxy` 选项与 `TELEGRAM_PROXY` 环境变量（compose 里 `TG_PROXY` 就是透传给它的），语义与 `--api-id`/`TELEGRAM_API_ID` 一致，CLI 优先于环境变量
- **格式**：`scheme://[user:password@]host:port`；socks5/socks/http/mtproto 四种 scheme（socks 视为 socks5）；userinfo 支持 `%XX` 百分号编码；IPv6 地址写 `[::1]:1080`；端口必填
- **协议覆盖**：socks5、http（CONNECT 隧道）、mtproto；**不支持 socks4**（参考项目支持，但 TDLib 协议层没有 socks4 实现）
- **代理建议**：2GB 分片场景下代理吞吐就是上传速度上限，建议用本地低延迟代理（如同机 Clash）或专线，避免公共代理
- **补丁维护**：补丁在 Dockerfile 构建阶段以 `git apply` 应用；若上游改动导致上下文漂移，构建会**明确失败**（而不是静默丢掉代理能力），此时需基于新源码重新生成补丁（`git diff` 后替换 patch 文件）。Dockerfile 里还有一道自检：编译产物 `--help` 必须包含 `--mtproto-proxy`，否则构建失败

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
若上游源码改动导致 MTProto 代理补丁应用失败，构建会报 `git apply` 错误——按「代理模式」一节的补丁维护说明重新生成补丁即可。

**Q: 配了 TG_PROXY 但 bot 连不上 Telegram？**
按顺序排查：`docker compose logs telegram-bot-api` 看 `MTProto proxy enabled` 日志是否出现（没出现说明 `TELEGRAM_PROXY` 没传进容器，检查 `.env` 的 `TG_PROXY` 是否生效）；出现了但连不上，则是代理本身不通或出口到 Telegram DC 被断，在服务器上直接测代理连通性：`curl -x socks5h://host:port https://api.telegram.org/`。

**Q: 代理会拖慢上传下载吗？**
会。全部 DC 流量经代理转发，代理吞吐即速度上限。同机 Clash（127.0.0.1）开销最小；跨机/公共代理在大文件场景下不建议。

**Q: 怎么固定版本？**
上游仓库没有发 tag，用 commit SHA 固定。在 `.env` 中设置 `TBA_REF=<40位SHA>` 后 `docker compose build`。已验证可用快照：`e3e9dd8e5b3d7ab8537cd5a10dc31d5ffa8f82d1`（2026-08-25，代理补丁即基于该版本制作）。

**Q: 首次 CI 构建显示"仅构建验证，未推送"？**
本仓库还未配置 `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` Secrets（Secrets 不跨仓库共享）。到仓库 Settings → Secrets and variables → Actions 添加后，手动触发 workflow 并勾选 `push_image` 即可推送镜像 `totootao/otterhub-tg-api`。

**Q: 健康检查原理？**
镜像内置 HEALTHCHECK 对 `/bot000:health/getMe` 发请求——server 对无效 token 会返回 404 JSON，只要 HTTP 有响应即视为进程存活。

## 目录结构

```
├── telegram-bot-api/
│   ├── Dockerfile              # 官方源码多阶段构建（--local），含补丁应用与自检
│   ├── docker-entrypoint.sh    # 参数拼装（api-id/api-hash/dir/local）
│   └── patches/
│       └── 0001-mtproto-proxy.patch  # MTProto 出站代理支持（TDLib 原生 addProxy）
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
