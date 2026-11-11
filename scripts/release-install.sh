#!/bin/zsh
set -euo pipefail

PROJECT="3D Model Viewer.xcodeproj"
SCHEME="3D Model Viewer"
CONFIG="Release"
APP_NAME="3D Model Viewer.app"
PROCESS_NAME="3D Model Viewer"
DEST="/Applications/$APP_NAME"
BUILD_DIR=".build-release"
SRC="$BUILD_DIR/Build/Products/$CONFIG/$APP_NAME"
XCODEBUILD="/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"

SKIP_BUILD=0
LAUNCH=1
BUILD_ONLY=0

usage() {
  cat <<'EOF'
用法：
  scripts/release-install.sh                 构建 Web 与 Release，替换 /Applications 中的旧版并启动
  scripts/release-install.sh --skip-build    使用 .build-release 中已有产物安装
  scripts/release-install.sh --no-launch     安装后不自动启动
  scripts/release-install.sh --build-only    只构建并校验 Release 产物，不退出或替换已安装应用

旧版会移入废纸篓，脚本不会删除 Debug 产物或清空废纸篓。
EOF
}

for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --no-launch) LAUNCH=0 ;;
    --build-only) BUILD_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "未知参数：$arg"; usage >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
log() { print "[release] $*"; }
is_running() { pgrep -f "/$APP_NAME/Contents/MacOS/$PROCESS_NAME" >/dev/null 2>&1; }

if [[ $SKIP_BUILD -eq 0 ]]; then
  [[ -x "$XCODEBUILD" ]] || { print -u2 "找不到 Xcode：$XCODEBUILD"; exit 1; }
  log "构建 Web 资源"
  npm --prefix web run build
  log "编译 $CONFIG（scheme=$SCHEME）"
  "$XCODEBUILD" -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR" build
else
  log "跳过编译，使用已有产物"
fi

[[ -d "$SRC" ]] || { print -u2 "找不到 Release 产物：$SRC"; exit 1; }
[[ -x "$SRC/Contents/MacOS/$PROCESS_NAME" ]] || { print -u2 "Release 产物缺少可执行文件：$SRC"; exit 1; }
codesign --verify --deep --strict "$SRC"
log "Release 产物校验通过：$SRC"

if [[ $BUILD_ONLY -eq 1 ]]; then
  log "构建完成，未替换已安装应用"
  exit 0
fi

if is_running; then
  log "退出运行中的 $PROCESS_NAME"
  osascript -e "quit app \"$PROCESS_NAME\"" 2>/dev/null || true
  for attempt in {1..20}; do
    if ! is_running; then break; fi
    sleep 0.5
  done
  if is_running; then
    print -u2 "应用尚未退出，请手动关闭后重新运行；未替换现有版本。"
    exit 1
  fi
fi

if [[ -e "$DEST" ]]; then
  BACKUP="$HOME/.Trash/3D Model Viewer-old-$(date +%Y%m%d-%H%M%S)-$$.app"
  log "旧版移入废纸篓：$BACKUP"
  mv "$DEST" "$BACKUP"
fi

log "安装到 $DEST"
ditto "$SRC" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign --verify --deep --strict "$DEST"

if [[ $LAUNCH -eq 1 ]]; then
  log "启动 $PROCESS_NAME"
  open "$DEST"
fi
log "完成"
