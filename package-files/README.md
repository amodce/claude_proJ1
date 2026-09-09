# Dify 离线安装包（Linux x64）

本目录是一个自包含的 Dify 离线部署包：所有容器镜像已随包提供，安装过程**不需要访问公网**。

具体版本、构建时间见同目录下的 `VERSION` 文件。

## 目录结构

```
├── install.sh              离线安装脚本（主入口）
├── install-docker.sh       离线安装 Docker Engine（目标机器没装 Docker 时用）
├── uninstall.sh            停止 / 清理
├── VERSION                 版本与构建信息
├── SHA256SUMS              包内所有文件的校验和
├── images/
│   ├── dify-images.tar.gz  全部容器镜像（docker save 归档）
│   └── manifest.txt        镜像清单：名称 / image ID / 大小
├── runtime/                Docker Engine 静态包 + Compose 插件（构建时加 --no-docker 则没有此目录）
│   ├── docker-<版本>.tgz
│   ├── docker-compose
│   └── VERSIONS
├── docker/                 Dify 官方 docker 部署目录（compose 文件、nginx、ssrf_proxy 等配置）
│   └── .env.example        配置模板，install.sh 会据此生成 .env
├── dify-LICENSE
└── dify-README.md
```

## 前置条件

| 组件 | 要求 |
|---|---|
| 操作系统 | Linux x86_64，内核 3.10 以上（建议 4.x+） |
| CPU / 内存 | 至少 2 核 4GB，生产建议 4 核 8GB 以上 |
| 磁盘 | 至少 15GB 可用空间 |
| Docker | **不需要预装** —— 本包自带（见 `runtime/`） |

如果 `runtime/` 存在，`install.sh` 检测到机器上没有可用的 Docker 时会自动先执行
`install-docker.sh`：解包静态二进制到 `/usr/local/bin`、装好 Compose 插件、写入
systemd 服务并启动。也可以手动单独执行：

```bash
sudo ./install-docker.sh
```

已经装了 Docker 的机器会跳过这一步，不会覆盖现有环境（确需覆盖用 `FORCE=1`）。

## 安装

```bash
tar -xzf dify-offline-<版本>-linux-amd64.tar.gz
cd dify-offline-<版本>-linux-amd64
sudo ./install.sh
```

脚本会依次完成：环境检查 →（需要时）安装 Docker → 导入镜像 → 逐个校验镜像 →
生成 `docker/.env`（随机密钥 + 离线适配）→ `docker compose up -d --pull never` →
等待 API 就绪。

就绪判断探的是 `/console/api/setup` 而不是首页：首页只要 nginx 和 web 起来就能返回，
但那时 api 可能还在跑数据库迁移。所以脚本报"安装完成"时服务是真的能用了。

完成后浏览器打开 `http://<服务器IP>/install` 设置管理员账号。

### 常用参数

```bash
sudo ./install.sh --port 8080     # 80 端口被占用时换端口
sudo ./install.sh --skip-start    # 只导入镜像和生成配置，不启动
sudo ./install.sh --skip-load     # 镜像已导入过，跳过这一步
sudo ./install.sh --online        # 目标机器其实能上外网，保留插件市场等联网功能
```

## 安装脚本做了哪些离线适配

`install.sh` 生成 `.env` 时（未加 `--online` 时）会改这几项，因为它们在纯离线环境下
只会让界面一直转圈或报错：

| 配置项 | 值 | 原因 |
|---|---|---|
| `MARKETPLACE_ENABLED` | `false` | 插件市场需要访问 marketplace.dify.ai |
| `CHECK_UPDATE_URL` | 空 | 关闭版本更新检查 |
| `FORCE_VERIFYING_SIGNATURE` | `false` | 允许安装本地 `.difypkg` 离线插件包 |

同时会把 `.env.example` 里公开的默认密钥全部换成随机值：`SECRET_KEY`、`DB_PASSWORD`、
`REDIS_PASSWORD`、`CODE_EXECUTION_API_KEY` / `SANDBOX_API_KEY`、`WEAVIATE_API_KEY`
（含 weaviate 容器侧的放行列表）、`PLUGIN_DAEMON_KEY`、`PLUGIN_DIFY_INNER_API_KEY`。

> 重装或迁移时如果要保留数据库，必须连同 `docker/.env` 一起保留 —— `DB_PASSWORD`
> 是 postgres 首次初始化时写死的，换了密码旧数据卷会连不上。

## 运维

```bash
cd docker
docker compose ps                  # 服务状态
docker compose logs -f api         # API 日志
docker compose restart api worker  # 重启
docker compose down                # 停止
```

数据全部落在 `docker/volumes/` 下（`db` 数据库、`app/storage` 上传文件、
`weaviate` 向量库、`plugin_daemon` 插件）。**备份就是备份这个目录加上 `docker/.env`。**

卸载：`./uninstall.sh`（保留数据），`./uninstall.sh --purge`（连数据一起删）。

## 离线环境下的功能边界

有几件事在断网环境里天然做不到，与本包无关：

- **模型供应商**：OpenAI / Anthropic / Gemini 等都要公网。离线环境请接内网自建的推理服务
  （Ollama、Xinference、vLLM、LocalAI 等），在「设置 → 模型供应商」里按 OpenAI 兼容接口配置。
- **插件安装**：装不了市场里的插件。可在能联网的机器上下载 `.difypkg`，拷进来后在
  「插件 → 安装插件 → 本地上传」安装（本包已默认关闭签名校验以支持这条路径）。
- **联网工具**：Google 搜索、网页抓取一类工具节点无法使用。

## 常见问题

**80 端口被占用** — `sudo ./install.sh --port 8080`；已经装好的话改 `docker/.env` 里的
`EXPOSE_NGINX_PORT` 再 `docker compose up -d`。

**api 容器反复重启** — 先看 `docker compose logs api`。多数是首次启动的数据库迁移还没跑完
（等几分钟），或 `.env` 被手工改坏了。

**`docker compose up` 想去拉镜像** — 说明有镜像没导入成功。重跑 `./install.sh`，
校验环节会指出缺哪个。

**导入镜像报磁盘空间不足** — 镜像解包后约 10GB，清理空间后重跑 `./install.sh`。

**普通用户执行 docker 报权限错误** — `sudo usermod -aG docker <用户名>`，重新登录生效。

**要换向量库**（pgvector / qdrant 等）— 本包只带了默认的 weaviate。换向量库需要额外镜像，
用构建仓库里的 `scripts/images-optional.txt` 重新打一个包。
