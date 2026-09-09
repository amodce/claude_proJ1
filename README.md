# Dify 离线安装包构建工具

在一台能联网的 Linux x64 机器上，一条命令产出可以拷进内网的 Dify 离线安装包。

产物是一个自包含的 `dify-offline-<版本>-linux-amd64.tar.gz`：容器镜像、官方 docker
部署文件、安装脚本，**以及 Docker Engine 本体**全在里面。目标机器是一台干净的
Linux x64 就够了，不需要预装 Docker，全程不碰公网。

默认版本 **Dify 1.9.2**（当前最新稳定版）。

## 构建

```bash
git clone https://github.com/amodce/claude_proJ1.git && cd claude_proJ1
./scripts/build-offline-package.sh
# 产物: dist/dify-offline-1.9.2-linux-amd64.tar.gz  (约 2.0 GB)
```

构建机要求：Linux x64、Docker daemon 可用（`docker info` 能通）、能访问 github.com /
download.docker.com / 容器镜像仓库、约 25GB 空闲磁盘。整个过程 10–30 分钟，
主要时间花在拉 `dify-api` 镜像上。

### 参数

```bash
./scripts/build-offline-package.sh --version 1.9.2         # 换 Dify 版本
./scripts/build-offline-package.sh --mirror mirror.gcr.io  # 指定拉取镜像源
./scripts/build-offline-package.sh --no-docker             # 不带 Docker，包小 113MB
./scripts/build-offline-package.sh --docker-version 28.3.2 # 指定 Docker 版本
./scripts/build-offline-package.sh --extra-images scripts/images-optional.txt
./scripts/build-offline-package.sh --out /data/dist        # 换输出目录
```

也支持同名环境变量：`DIFY_VERSION`、`REGISTRY_MIRROR`、`OUT_DIR`、`WORK_DIR`、
`GZIP_LEVEL`、`WITH_DOCKER`、`DOCKER_VERSION`、`COMPOSE_VERSION`。

**关于 `--mirror`**：Docker Hub 直连不通时（例如国内网络，或出网策略拦了
`production.cloudfront.docker.com` 这类 blob CDN），用它指定一个 Docker Hub 的
pull-through 镜像源。镜像拉下来后脚本会 `docker tag` 回官方名字，所以离线包里
和 compose 文件引用的始终是官方 tag，跟直连拉取的结果一致。

## 仓库结构

```
scripts/
  build-offline-package.sh   构建脚本（在联网机器上跑）
  images.txt                 核心镜像清单（默认部署所需，9 个）
  images-optional.txt        可选镜像（其它向量库、certbot）
package-files/
  install.sh                 离线安装脚本，会被打进包里
  uninstall.sh               停止 / 清理脚本
  README.md                  面向最终使用者的部署文档
```

## 离线包里有什么

| 内容 | 说明 |
|---|---|
| `images/dify-images.tar.gz` | 9 个容器镜像，单次 `docker save` 合并导出（≈1.9GB） |
| `runtime/` | Docker Engine 静态包 + Compose 插件（≈113MB），`--no-docker` 可去掉 |
| `docker/` | Dify 官方部署目录：compose 文件、nginx / ssrf_proxy 配置、`.env.example` |
| `install.sh` | 离线安装入口 |
| `install-docker.sh` | 离线装 Docker Engine（含 systemd 服务） |
| `uninstall.sh` | 停止 / 清理 |
| `SHA256SUMS`、`VERSION` | 完整性校验与构建信息 |

## 包含的镜像

`scripts/images.txt`，对应 Dify 默认 compose 配置（`VECTOR_STORE=weaviate`）：

| 镜像 | 作用 |
|---|---|
| `langgenius/dify-api:1.9.2` | API / worker / worker_beat 共用 |
| `langgenius/dify-web:1.9.2` | 前端 |
| `langgenius/dify-sandbox:0.2.12` | 代码执行沙箱 |
| `langgenius/dify-plugin-daemon:0.3.3-local` | 插件守护进程 |
| `postgres:15-alpine` | 主数据库 |
| `redis:6-alpine` | 缓存 / 队列 |
| `semitechnologies/weaviate:1.27.0` | 默认向量库 |
| `ubuntu/squid:latest` | ssrf_proxy |
| `nginx:latest` | 反向代理入口 |

换向量库（pgvector、qdrant 等）时把 `scripts/images-optional.txt` 里对应的行
通过 `--extra-images` 带上，并在离线机的 `docker/.env` 里改 `VECTOR_STORE`。

## 离线包怎么用

```bash
tar -xzf dify-offline-1.9.2-linux-amd64.tar.gz
cd dify-offline-1.9.2-linux-amd64
sudo ./install.sh                 # 没装 Docker 的机器会自动先装
```

安装脚本会：检查环境 →（需要时）装 Docker → 导入并逐个校验镜像 → 由 `.env.example`
生成 `.env`（随机密钥、关掉插件市场和更新检查、放开签名校验以支持本地 `.difypkg`）
→ `docker compose up -d --pull never` → 等 API 真正就绪。完成后打开
`http://<服务器IP>/install` 创建管理员账号。

细节见包内的 `README.md`（即本仓库的 `package-files/README.md`）。

## 验证情况

本仓库的脚本在 Linux x64 上完整跑过一遍：构建出 2.0GB 的包 → 解压 → `SHA256SUMS`
全部校验通过 → `install.sh` 拉起 11 个容器全部 Running → `/console/api/setup`
返回 `{"step":"not_started"}`（说明数据库迁移已完成、等待创建管理员）→
`uninstall.sh` 干净停止无残留。
