#!/usr/bin/env bash
#
# Dify 离线安装脚本 —— 在【不联网】的 Linux x64 机器上运行。
#
#   tar -xzf dify-offline-<版本>-linux-amd64.tar.gz
#   cd dify-offline-<版本>-linux-amd64
#   sudo ./install.sh
#
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${PKG_DIR}/docker"
IMAGES_TAR="${PKG_DIR}/images/dify-images.tar.gz"
MANIFEST="${PKG_DIR}/images/manifest.txt"

SKIP_LOAD=0
SKIP_START=0
KEEP_DEFAULT_SECRETS=0
OFFLINE_TWEAKS=1
HTTP_PORT=""

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
用法: ./install.sh [选项]

  --port <端口>          Dify 对外 HTTP 端口（默认 80）
  --skip-load            跳过镜像导入（镜像已在本机时使用）
  --skip-start           只准备配置与镜像，不启动服务
  --keep-default-secrets 不重新生成随机密钥（不推荐，仅用于复现问题）
  --online               保留联网特性（插件市场等）。默认按纯离线环境关闭。

本包若含 runtime/ 目录，在目标机器没有 Docker 时会自动先装 Docker Engine；
也可以单独执行 ./install-docker.sh。
  -h, --help             显示本帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --port) HTTP_PORT="$2"; shift 2 ;;
    --skip-load) SKIP_LOAD=1; shift ;;
    --skip-start) SKIP_START=1; shift ;;
    --keep-default-secrets) KEEP_DEFAULT_SECRETS=1; shift ;;
    --online) OFFLINE_TWEAKS=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "未知参数: $1" ;;
  esac
done

# ------------------------------------------------------------ 环境检查 ----
log "环境检查"

arch="$(uname -m)"
[ "$arch" = "x86_64" ] || die "本安装包为 linux/amd64 构建，当前架构是 ${arch}。"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  if [ -x "${PKG_DIR}/install-docker.sh" ] && [ -d "${PKG_DIR}/runtime" ]; then
    log "未检测到可用的 Docker，先安装随包附带的 Docker Engine"
    [ "$(id -u)" -eq 0 ] || die "安装 Docker 需要 root，请用 sudo 重新运行 ./install.sh。"
    "${PKG_DIR}/install-docker.sh"
    export PATH="/usr/local/bin:${PATH}"
    hash -r
  fi
fi

command -v docker >/dev/null || die "未找到 docker。请先安装 Docker Engine（本包若含 runtime/ 可执行 ./install-docker.sh）。"
docker info >/dev/null 2>&1 || die "无法连接 Docker daemon。请确认 dockerd 已启动，且当前用户在 docker 组或使用 sudo。"

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
  # 镜像都在本地，禁止回源拉取（离线环境下 compose 会一直重试直到超时）
  UP_ARGS=(--pull never)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
  UP_ARGS=()   # v1 的 up 不支持 --pull
  warn "使用的是旧版 docker-compose v1，建议升级到 Compose V2 插件。"
else
  die "未找到 Docker Compose。请安装 docker compose 插件。"
fi
log "Docker: $(docker version --format '{{.Server.Version}}')，Compose: $("${COMPOSE[@]}" version --short 2>/dev/null || echo v1)"

# 镜像解包后约需 10GB，加上运行时数据留出余量
avail_kb="$(df -Pk "$PKG_DIR" | awk 'NR==2{print $4}')"
if [ "${avail_kb:-0}" -lt 15000000 ]; then
  warn "$(dirname "$PKG_DIR") 可用空间约 $((avail_kb/1024/1024))GB，建议至少 15GB。"
fi

[ -d "$COMPOSE_DIR" ] || die "缺少 docker 目录，安装包不完整。"

# ------------------------------------------------------------ 导入镜像 ----
if [ "$SKIP_LOAD" -eq 0 ]; then
  [ -f "$IMAGES_TAR" ] || die "找不到镜像归档: $IMAGES_TAR"
  log "导入镜像（$(du -h "$IMAGES_TAR" | cut -f1)，需要几分钟）"
  gunzip -c "$IMAGES_TAR" | docker load
else
  log "按要求跳过镜像导入"
fi

if [ -f "$MANIFEST" ]; then
  log "校验镜像"
  missing=0
  while IFS=$'\t' read -r img _id _size _repo_digest; do
    [ -n "${img:-}" ] || continue
    if docker image inspect "$img" >/dev/null 2>&1; then
      printf '    \033[0;32m✓\033[0m %s\n' "$img"
    else
      printf '    \033[0;31m✗\033[0m %s (缺失)\n' "$img"; missing=$((missing+1))
    fi
  done < "$MANIFEST"
  [ "$missing" -eq 0 ] || die "有 ${missing} 个镜像未成功导入。"
fi

# -------------------------------------------------------------- 配置 ----
ENV_FILE="${COMPOSE_DIR}/.env"

rand() { head -c "${1:-42}" /dev/urandom | base64 | tr -d '\n=+/' | head -c "${1:-42}"; }

set_env() {  # set_env KEY VALUE —— 存在则替换，不存在则追加
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    # 用 | 作分隔符，值里先转义 | 与 &
    local esc; esc="$(printf '%s' "$val" | sed -e 's/[|&\\]/\\&/g')"
    sed -i -E "s|^${key}=.*|${key}=${esc}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

if [ -f "$ENV_FILE" ]; then
  log "已存在 docker/.env，保留现有配置不做修改"
else
  log "生成 docker/.env"
  cp "${COMPOSE_DIR}/.env.example" "$ENV_FILE"

  if [ "$KEEP_DEFAULT_SECRETS" -eq 0 ]; then
    log "生成随机密钥（替换 .env.example 里的公开默认值）"
    sandbox_key="$(rand 32)"
    weaviate_key="$(rand 32)"
    set_env SECRET_KEY               "sk-$(rand 42)"
    set_env DB_PASSWORD              "$(rand 24)"
    set_env REDIS_PASSWORD           "$(rand 24)"
    set_env CODE_EXECUTION_API_KEY   "$sandbox_key"
    set_env SANDBOX_API_KEY          "$sandbox_key"
    set_env WEAVIATE_API_KEY         "$weaviate_key"
    # weaviate 容器侧的放行列表必须与客户端 key 一致
    set_env WEAVIATE_AUTHENTICATION_APIKEY_ALLOWED_KEYS "$weaviate_key"
    set_env PLUGIN_DAEMON_KEY        "$(rand 48)"
    set_env PLUGIN_DIFY_INNER_API_KEY "$(rand 48)"
  else
    warn "沿用 .env.example 的默认密钥，请勿用于生产环境。"
  fi

  if [ "$OFFLINE_TWEAKS" -eq 1 ]; then
    log "应用离线环境适配"
    # 这些功能都要访问公网，离线环境下开着只会在界面上一直转圈或报错
    set_env MARKETPLACE_ENABLED "false"
    set_env CHECK_UPDATE_URL    ""
    # 关闭签名校验，插件才能从本地 .difypkg 离线安装
    set_env FORCE_VERIFYING_SIGNATURE "false"
  fi

  [ -n "$HTTP_PORT" ] && { log "对外端口设为 ${HTTP_PORT}"; set_env EXPOSE_NGINX_PORT "$HTTP_PORT"; }
fi

# -------------------------------------------------------------- 启动 ----
if [ "$SKIP_START" -eq 1 ]; then
  log "按要求跳过启动。手动启动: cd ${COMPOSE_DIR} && docker compose up -d"
  exit 0
fi

log "启动 Dify"
cd "$COMPOSE_DIR"
"${COMPOSE[@]}" up -d "${UP_ARGS[@]}"

log "等待服务就绪"
port="$(grep -E '^EXPOSE_NGINX_PORT=' "$ENV_FILE" | cut -d= -f2)"; port="${port:-80}"
# 探 /console/api/setup 而不是首页：首页只要 nginx+web 起来就能返回，
# 而 api 还在跑数据库迁移，这时报"安装完成"是假的。这个接口通了才说明
# api 容器已连上数据库、迁移跑完。
PROBE_URL="http://127.0.0.1:${port}/console/api/setup"
if command -v curl >/dev/null 2>&1; then
  probe() { curl -fsS -o /dev/null --max-time 5 "$PROBE_URL"; }
elif command -v wget >/dev/null 2>&1; then
  probe() { wget -q -O /dev/null -T 5 "$PROBE_URL"; }
else
  # 精简系统上可能既没有 curl 也没有 wget，退而求其次看容器有没有反复重启
  warn "未找到 curl/wget，改用容器状态判断就绪（准确性较低）。"
  probe() {
    sleep 20
    ! "${COMPOSE[@]}" ps --status=restarting --status=exited -q 2>/dev/null | grep -q .
  }
fi

ready=0
for _ in $(seq 1 60); do   # 最多等 5 分钟，首次启动要跑数据库迁移
  if probe 2>/dev/null; then ready=1; break; fi
  sleep 5
done

echo
"${COMPOSE[@]}" ps
echo
if [ "$ready" -eq 1 ]; then
  log "安装完成"
else
  warn "服务已启动，但 API 还未就绪（首次启动要跑数据库迁移，可能需要几分钟）。"
  warn "查看日志: cd ${COMPOSE_DIR} && docker compose logs -f api"
fi

cat <<EOF

  访问地址   http://<本机IP>:${port}
  初始化管理员   http://<本机IP>:${port}/install
  配置文件   ${ENV_FILE}
  常用命令   cd ${COMPOSE_DIR}
             docker compose ps          查看状态
             docker compose logs -f api 查看 API 日志
             docker compose down        停止
EOF
