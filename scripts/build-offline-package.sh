#!/usr/bin/env bash
#
# 构建 Dify 离线安装包（linux/amd64）。
# 在一台【能联网】的 Linux x64 机器上运行，产出一个自包含的 tar.gz，
# 拷贝到内网/离线机器上解压执行 install.sh 即可部署。
#
# 用法:
#   ./scripts/build-offline-package.sh
#   DIFY_VERSION=1.17.0 ./scripts/build-offline-package.sh
#   REGISTRY_MIRROR=mirror.gcr.io ./scripts/build-offline-package.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 留空表示自动解析 GitHub 上最新的稳定版（纯 X.Y.Z，排除 rc/beta/fix 之类预发布）
DIFY_VERSION="${DIFY_VERSION:-}"
PLATFORM="${PLATFORM:-linux/amd64}"
ARCH_TAG="${ARCH_TAG:-linux-amd64}"
# 当 Docker Hub 直连受限时可指定拉取镜像源，例如 mirror.gcr.io。
# 镜像拉下来后会重新打回官方名字，离线包里始终是官方 tag。
REGISTRY_MIRROR="${REGISTRY_MIRROR:-}"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/.build}"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/dist}"
# 默认从 compose 文件解析镜像清单；指定本变量可改用固定清单文件
IMAGES_FILE="${IMAGES_FILE:-}"
EXTRA_IMAGES_FILE="${EXTRA_IMAGES_FILE:-}"
# 层已经是压缩过的，gzip 收益有限；-1 换取明显更快的打包速度。
GZIP_LEVEL="${GZIP_LEVEL:-1}"
# 是否把 Docker Engine 静态包 + Compose 插件一起打进离线包（目标机器可零依赖）
WITH_DOCKER="${WITH_DOCKER:-1}"
# 留空表示取 download.docker.com 上 stable 频道的最新版
DOCKER_VERSION="${DOCKER_VERSION:-}"
COMPOSE_VERSION="${COMPOSE_VERSION:-latest}"

usage() {
  cat <<'EOF'
用法: ./scripts/build-offline-package.sh [选项]

  --version <版本>          Dify 版本，默认自动取 GitHub 上最新稳定版
  --images-file <文件>      改用固定镜像清单，不从 compose 解析（一般不需要）
  --mirror <registry>       Docker Hub pull-through 镜像源，如 mirror.gcr.io
  --extra-images <文件>     追加镜像清单（如 scripts/images-optional.txt）
  --out <目录>              产物输出目录，默认 dist/
  --no-docker               不附带 Docker Engine（目标机器已装 Docker 时可用，包更小）
  --with-docker             附带 Docker Engine + Compose（默认行为）
  --docker-version <版本>   指定 Docker 静态包版本，默认取 stable 最新
  --compose-version <版本>  指定 Compose 版本，如 v2.29.7，默认 latest
  -h, --help                显示本帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version)       DIFY_VERSION="$2"; shift 2 ;;
    --mirror)        REGISTRY_MIRROR="$2"; shift 2 ;;
    --extra-images)  EXTRA_IMAGES_FILE="$2"; shift 2 ;;
    --images-file)   IMAGES_FILE="$2"; shift 2 ;;
    --out)           OUT_DIR="$2"; shift 2 ;;
    --with-docker)   WITH_DOCKER=1; shift ;;
    --no-docker)     WITH_DOCKER=0; shift ;;
    --docker-version)  DOCKER_VERSION="$2"; shift 2 ;;
    --compose-version) COMPOSE_VERSION="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) usage >&2; echo "未知参数: $1" >&2; exit 2 ;;
  esac
done


log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "未找到 docker，请先安装 Docker Engine。"
docker info >/dev/null 2>&1 || die "无法连接 Docker daemon，请确认 dockerd 正在运行且当前用户有权限。"
command -v git >/dev/null || die "未找到 git。"
[ "$WITH_DOCKER" -eq 1 ] && { command -v curl >/dev/null || die "未找到 curl（附带 Docker 需要下载二进制；或加 --no-docker）。"; }

if [ -z "$DIFY_VERSION" ]; then
  log "解析 Dify 最新稳定版"
  # git 输出是字典序，1.17.0 会排在 1.9.2 前面，所以必须用 sort -V 按版本号排。
  # 只取纯 X.Y.Z，把 rc / beta / fix 之类预发布标签排除掉。
  DIFY_VERSION="$(git ls-remote --tags --refs https://github.com/langgenius/dify.git 2>/dev/null \
    | sed 's|.*refs/tags/||' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
  [ -n "$DIFY_VERSION" ] || die "无法解析最新版本，请用 --version 指定。"
fi

# 必须放在版本解析之后：自动解析时这里才拿得到真正的版本号，
# 否则包名会变成 dify-offline--linux-amd64 这种空版本。
PKG_NAME="dify-offline-${DIFY_VERSION}-${ARCH_TAG}"
PKG_DIR="${WORK_DIR}/${PKG_NAME}"

read_list() {  # 去掉注释与行尾说明，输出干净的镜像名
  [ -n "${1:-}" ] && [ -f "$1" ] || return 0
  sed -e 's/#.*$//' -e 's/[[:space:]]*$//' "$1" | grep -vE '^[[:space:]]*$' || true
}

log "Dify 版本: ${DIFY_VERSION}  平台: ${PLATFORM}"
[ -n "$REGISTRY_MIRROR" ] && log "拉取镜像源: ${REGISTRY_MIRROR}"

rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR" "$OUT_DIR"

# ---------------------------------------------------------------- 1. 源码 ----
log "获取 Dify ${DIFY_VERSION} 的 docker 部署文件"
SRC_DIR="${WORK_DIR}/dify-src-${DIFY_VERSION}"
if [ ! -d "$SRC_DIR/.git" ]; then
  rm -rf "$SRC_DIR"
  git clone --depth 1 --branch "$DIFY_VERSION" https://github.com/langgenius/dify.git "$SRC_DIR"
fi
cp -a "$SRC_DIR/docker" "$PKG_DIR/docker"
# .env 是部署入口，先由 .env.example 生成一份，安装脚本再补随机密钥。
cp "$PKG_DIR/docker/.env.example" "$PKG_DIR/docker/.env.example.orig"
for f in LICENSE README.md; do
  [ -f "$SRC_DIR/$f" ] && cp "$SRC_DIR/$f" "$PKG_DIR/dify-$f"
done

# ------------------------------------------------------------ 1b. 镜像清单 ----
# 不写死镜像列表：每个 Dify 版本的服务构成都可能变（1.17 就比 1.9 多出
# agent-backend / agent-local-sandbox / busybox），手工维护必然滞后。
# 直接问 compose 要，profile 由 .env.example 里的 COMPOSE_PROFILES 决定。
IMAGES=()
if [ -n "$IMAGES_FILE" ]; then
  log "使用指定的镜像清单: ${IMAGES_FILE}"
  while IFS= read -r line; do [ -n "$line" ] && IMAGES+=("$line"); done < <(read_list "$IMAGES_FILE")
else
  log "从 compose 解析镜像清单"
  # compose 里的服务声明了 env_file: .env，必须先有 .env 才能解析；
  # 解析完删掉，离线包里不带 .env（由 install.sh 生成，含随机密钥）。
  cp "$PKG_DIR/docker/.env.example" "$PKG_DIR/docker/.env"
  while IFS= read -r line; do
    [ -n "$line" ] && IMAGES+=("$line")
  done < <(cd "$PKG_DIR/docker" && docker compose config --images 2>/dev/null | sort -u)
  rm -f "$PKG_DIR/docker/.env"
fi
while IFS= read -r line; do [ -n "$line" ] && IMAGES+=("$line"); done < <(read_list "$EXTRA_IMAGES_FILE")
[ ${#IMAGES[@]} -gt 0 ] || die "解析不到任何镜像，请检查 docker compose 是否可用。"

log "需要 ${#IMAGES[@]} 个镜像:"
printf '      %s\n' "${IMAGES[@]}"

# -------------------------------------------------------------- 2. 拉镜像 ----
mkdir -p "$PKG_DIR/images"
MANIFEST="$PKG_DIR/images/manifest.txt"
: > "$MANIFEST"

mirror_ref() {  # canonical name -> 镜像源上的完整引用
  local img="$1"
  [ -z "$REGISTRY_MIRROR" ] && { echo "$img"; return; }
  case "$img" in
    */*)
      # 只有含 / 时首段才可能是 registry 域名；含 . 或 : 即认定是域名，
      # 这类镜像不在 Docker Hub 上，镜像源代理不了，保持原样直连。
      # （不能对整个 img 做这个判断：postgres:15-alpine 这种无 / 的名字
      #  里的 : 是 tag 分隔符，不是端口号。）
      case "${img%%/*}" in
        *.*|*:*) echo "$img" ;;
        *)       echo "${REGISTRY_MIRROR}/${img}" ;;
      esac ;;
    *) echo "${REGISTRY_MIRROR}/library/${img}" ;;
  esac
}

for img in "${IMAGES[@]}"; do
  ref="$(mirror_ref "$img")"
  log "拉取 ${img}${ref:+  (来源 ${ref})}"
  docker pull --platform "$PLATFORM" "$ref" >/dev/null
  [ "$ref" != "$img" ] && docker tag "$ref" "$img"
  image_id="$(docker image inspect "$img" --format '{{.Id}}')"
  size="$(docker image inspect "$img" --format '{{.Size}}')"
  # RepoDigests 记的是镜像源上的引用，留着可以回源核验来源
  repo_digest="$(docker image inspect "$img" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}-{{end}}')"
  printf '%s\t%s\t%s\t%s\n' "$img" "$image_id" "$size" "$repo_digest" >> "$MANIFEST"
done

log "导出镜像（单个归档，跨镜像共享层只存一份）"
# 一次 docker save 全部镜像，dify-api 被三个服务复用、alpine 系镜像共享基础层，
# 合并导出比逐个导出小很多。
docker save "${IMAGES[@]}" | gzip -"${GZIP_LEVEL}" > "$PKG_DIR/images/dify-images.tar.gz"
log "镜像归档大小: $(du -h "$PKG_DIR/images/dify-images.tar.gz" | cut -f1)"

# --------------------------------------------------- 3. Docker 运行时 ----
if [ "$WITH_DOCKER" -eq 1 ]; then
  RT_DIR="$PKG_DIR/runtime"
  mkdir -p "$RT_DIR"

  if [ -z "$DOCKER_VERSION" ]; then
    log "查询 Docker 静态包最新稳定版"
    DOCKER_VERSION="$(curl -fsSL --max-time 60 \
        "https://download.docker.com/linux/static/stable/x86_64/" \
      | grep -oE 'docker-[0-9]+\.[0-9]+\.[0-9]+\.tgz' | sed 's/^docker-//; s/\.tgz$//' \
      | sort -V | tail -1)"
    [ -n "$DOCKER_VERSION" ] || die "无法解析 Docker 最新版本，请用 --docker-version 指定。"
  fi

  log "下载 Docker Engine ${DOCKER_VERSION} 静态包"
  curl -fSL --retry 3 --retry-delay 2 --max-time 900 \
    -o "$RT_DIR/docker-${DOCKER_VERSION}.tgz" \
    "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz"
  # 静态包里必须有 dockerd，否则下到的是错误内容
  tar -tzf "$RT_DIR/docker-${DOCKER_VERSION}.tgz" | grep -q 'docker/dockerd' \
    || die "下载到的 docker-${DOCKER_VERSION}.tgz 不完整。"

  if [ "$COMPOSE_VERSION" = "latest" ]; then
    COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64"
  else
    COMPOSE_URL="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64"
  fi
  log "下载 Docker Compose (${COMPOSE_VERSION})"
  curl -fSL --retry 3 --retry-delay 2 --max-time 900 -o "$RT_DIR/docker-compose" "$COMPOSE_URL"
  chmod +x "$RT_DIR/docker-compose"
  compose_ver="$("$RT_DIR/docker-compose" version --short 2>/dev/null || echo unknown)"
  [ "$compose_ver" = unknown ] && die "下载到的 docker-compose 无法执行。"

  cat > "$RT_DIR/VERSIONS" <<EOF
docker=${DOCKER_VERSION}
compose=${compose_ver}
EOF
  cp "$REPO_ROOT/package-files/install-docker.sh" "$PKG_DIR/install-docker.sh"
  chmod +x "$PKG_DIR/install-docker.sh"
  log "运行时依赖: Docker ${DOCKER_VERSION} + Compose ${compose_ver} ($(du -sh "$RT_DIR" | cut -f1))"
else
  log "按要求不附带 Docker Engine（目标机器需自备）"
fi

# ------------------------------------------------------------ 4. 组装包 ----
log "组装安装脚本与文档"
cp "$REPO_ROOT/package-files/install.sh"   "$PKG_DIR/install.sh"
cp "$REPO_ROOT/package-files/uninstall.sh" "$PKG_DIR/uninstall.sh"
cp "$REPO_ROOT/package-files/README.md"    "$PKG_DIR/README.md"
chmod +x "$PKG_DIR/install.sh" "$PKG_DIR/uninstall.sh"

cat > "$PKG_DIR/VERSION" <<EOF
DIFY_VERSION=${DIFY_VERSION}
PLATFORM=${PLATFORM}
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
IMAGE_COUNT=${#IMAGES[@]}
BUNDLED_DOCKER=$([ "$WITH_DOCKER" -eq 1 ] && echo "${DOCKER_VERSION}" || echo "no")
EOF

( cd "$PKG_DIR" && find . -type f ! -name SHA256SUMS -print0 | sort -z \
    | xargs -0 sha256sum > SHA256SUMS )

# ------------------------------------------------------------- 5. 打 tar ----
log "打包 ${PKG_NAME}.tar.gz"
tar -C "$WORK_DIR" -cf - "$PKG_NAME" | gzip -"${GZIP_LEVEL}" > "${OUT_DIR}/${PKG_NAME}.tar.gz"
( cd "$OUT_DIR" && sha256sum "${PKG_NAME}.tar.gz" > "${PKG_NAME}.tar.gz.sha256" )

log "完成: ${OUT_DIR}/${PKG_NAME}.tar.gz  ($(du -h "${OUT_DIR}/${PKG_NAME}.tar.gz" | cut -f1))"
cat "${OUT_DIR}/${PKG_NAME}.tar.gz.sha256"
