#!/usr/bin/env bash
# 停止并清理 Dify。默认保留数据卷。
set -euo pipefail
PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

cd "${PKG_DIR}/docker"
docker compose down
echo "已停止 Dify。"

if [ "$PURGE" -eq 1 ]; then
  printf '\033[1;31m这会删除 %s/docker/volumes 下的全部数据（数据库、上传文件、向量库）。\033[0m\n' "$PKG_DIR"
  read -r -p "确认删除？输入 yes 继续: " ans
  if [ "$ans" = "yes" ]; then
    rm -rf "${PKG_DIR}/docker/volumes/db" "${PKG_DIR}/docker/volumes/redis" \
           "${PKG_DIR}/docker/volumes/app" "${PKG_DIR}/docker/volumes/weaviate" \
           "${PKG_DIR}/docker/volumes/plugin_daemon"
    echo "数据已删除。"
  else
    echo "已取消，数据保留。"
  fi
else
  echo "数据卷保留在 ${PKG_DIR}/docker/volumes（加 --purge 可一并删除）。"
fi
