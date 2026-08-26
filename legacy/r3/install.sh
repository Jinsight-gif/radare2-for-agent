#!/usr/bin/env bash
# r3 部署脚本：把仓库里的 r3 复制到 ~/.local/bin/r3 并 chmod +x
# （PLAN.md §8 + PLAN-v1.1.md §0：WSL 的 bash 内直接执行，无需 Windows 侧发起）
set -e

SRC="$(cd "$(dirname "$0")" && pwd)/r3"
DEST_DIR="${HOME}/.local/bin"
DEST="$DEST_DIR/r3"

if [ ! -f "$SRC" ]; then
    echo "错误: 找不到 $SRC" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST"
chmod +x "$DEST"
echo "已部署: $DEST"

case ":$PATH:" in
    *":$DEST_DIR:"*) ;;
    *)
        echo "提示: $DEST_DIR 不在 PATH 中；请把它加入 PATH 后重开 shell" >&2
        echo "      （验收用 bash -lc 'command -v r3' 检查 PATH 生效）" >&2
        ;;
esac
