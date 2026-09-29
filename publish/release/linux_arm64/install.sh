#!/usr/bin/env bash
# desktopToy — 生成 .desktop 桌面启动项（输出到程序文件夹内，与可执行文件、图标同目录）
# 用法：在本程序文件夹内执行  bash install.sh
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

# 定位程序文件夹内的可执行文件（DesktopToy / DesktopToy.x86_64 / DesktopToy.arm64，排除 .pck）
EXE=""
for f in "$DIR"/DesktopToy.*; do
  case "$f" in
    *.pck) ;;
    *) [ -f "$f" ] && EXE="$f" && break ;;
  esac
done
[ -z "$EXE" ] && [ -f "$DIR/DesktopToy" ] && EXE="$DIR/DesktopToy"
if [ -z "$EXE" ]; then
  echo "错误：未在 $DIR 找到 DesktopToy 可执行文件" >&2
  exit 1
fi

ICON="$DIR/icon.png"
if [ ! -f "$ICON" ]; then
  echo "错误：未找到图标 $ICON" >&2
  exit 1
fi

OUT="$DIR/desktopToy.desktop"
cat > "$OUT" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=desktopToy
Name[zh_CN]=桌面小游戏
Comment=Desktop toy games collection
Comment[zh_CN]=桌面小游戏合集
Exec="$EXE"
Path=$DIR
Icon=$ICON
Terminal=false
Categories=Game;
StartupNotify=true
EOF

chmod +x "$OUT"
echo "已生成: $OUT"
echo "提示：将其复制到 ~/.local/share/applications/ 后即可出现在系统应用菜单"
