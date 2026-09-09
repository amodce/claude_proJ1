#!/usr/bin/env bash
#
# 在离线机器上安装随包附带的 Docker Engine（静态二进制）+ Compose 插件。
# 只在目标机器还没装 Docker 时需要；已有 Docker 的话跳过即可。
#
#   sudo ./install-docker.sh
#
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RT_DIR="${PKG_DIR}/runtime"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
CLI_PLUGIN_DIR="${CLI_PLUGIN_DIR:-/usr/local/lib/docker/cli-plugins}"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "需要 root 权限，请用 sudo 运行。"
[ "$(uname -m)" = "x86_64" ] || die "本包为 x86_64 构建，当前架构是 $(uname -m)。"
[ -d "$RT_DIR" ] || die "缺少 runtime/ 目录 —— 这个离线包构建时未附带 Docker（构建时加 --with-docker）。"

DOCKER_TGZ="$(ls "$RT_DIR"/docker-*.tgz 2>/dev/null | head -1)"
[ -n "$DOCKER_TGZ" ] || die "runtime/ 下找不到 docker-*.tgz。"

if command -v dockerd >/dev/null 2>&1 && [ -z "${FORCE:-}" ]; then
  warn "系统里已有 dockerd（$(command -v dockerd)）。如需强制覆盖安装: FORCE=1 sudo ./install-docker.sh"
  exit 0
fi

# --------------------------------------------------------------- 内核检查 ----
log "检查内核依赖"
missing_mod=""
for m in overlay br_netfilter iptable_nat; do
  modprobe "$m" 2>/dev/null || missing_mod="${missing_mod} ${m}"
done
[ -n "$missing_mod" ] && warn "以下内核模块加载失败，容器网络可能异常:${missing_mod}"

# ----------------------------------------------------------------- 安装 ----
log "解包 $(basename "$DOCKER_TGZ") 到 ${BIN_DIR}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
tar -xzf "$DOCKER_TGZ" -C "$tmp"
install -m 0755 "$tmp"/docker/* "$BIN_DIR"/

if [ -f "$RT_DIR/docker-compose" ]; then
  log "安装 Compose 插件到 ${CLI_PLUGIN_DIR}"
  install -d -m 0755 "$CLI_PLUGIN_DIR"
  install -m 0755 "$RT_DIR/docker-compose" "$CLI_PLUGIN_DIR/docker-compose"
  # 同时留一份 docker-compose 命令，兼容习惯用 v1 写法的脚本
  ln -sf "$CLI_PLUGIN_DIR/docker-compose" "$BIN_DIR/docker-compose"
else
  warn "runtime/ 下没有 docker-compose，跳过 Compose 安装。"
fi

# ------------------------------------------------------------- systemd ----
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  log "写入 systemd 服务"
  getent group docker >/dev/null || groupadd --system docker

  cat > /etc/systemd/system/docker.service <<EOF
[Unit]
Description=Docker Application Container Engine
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=${BIN_DIR}/dockerd -H unix:///var/run/docker.sock
ExecReload=/bin/kill -s HUP \$MAINPID
Restart=always
RestartSec=2
# 容器数量多时默认的 fd / 进程数上限不够
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/docker.socket <<EOF
[Unit]
Description=Docker Socket for the API

[Socket]
ListenStream=/var/run/docker.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
EOF

  systemctl daemon-reload
  systemctl enable --now docker.service
  sleep 3
else
  warn "未检测到 systemd。请自行以守护方式启动: ${BIN_DIR}/dockerd &"
  nohup "${BIN_DIR}/dockerd" >/var/log/dockerd.log 2>&1 &
  sleep 5
fi

# ------------------------------------------------------------------ 验证 ----
log "验证安装"
export PATH="${BIN_DIR}:${PATH}"
docker version --format 'Docker Engine {{.Server.Version}}' || die "dockerd 未能正常启动，请查看 journalctl -u docker 或 /var/log/dockerd.log。"
docker compose version || warn "Compose 插件不可用。"

cat <<EOF

Docker 安装完成。

  让普通用户免 sudo 使用:  usermod -aG docker <用户名>   （需重新登录生效）
  接下来部署 Dify:         sudo ./install.sh
EOF
