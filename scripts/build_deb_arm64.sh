#!/usr/bin/env bash
#
# PiliPlus -> Linux ARM64 .deb 一键构建脚本
#
# 必须在 Linux ARM64 (aarch64) 主机上运行：
#   * 树莓派 5 / RK3588 开发板 / ARM 云主机
#   * GitHub Actions 的 ubuntu-24.04-arm runner
#
# 依赖（Debian/Ubuntu）：
#   sudo apt-get install -y git curl unzip xz-utils zip \
#       clang cmake ninja-build pkg-config libgtk-3-dev \
#       libwebkit2gtk-4.1-dev libasound2-dev libmpv-dev \
#       libblkid-dev liblzma-dev dpkg-dev file
#
# 用法：
#   git clone https://github.com/bggRGjQaUbCoE/PiliPlus.git && cd PiliPlus
#   bash /path/to/build_deb_arm64.sh
#
# 产物：dist/PiliPlus_linux_<version>_arm64.deb
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m[FAIL] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. 环境检查
[ "$(uname -s)" = "Linux" ] || die "本脚本只能在 Linux 上运行（当前：$(uname -s)）"

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  aarch64|arm64) ;;
  *) die "本脚本用于原生 ARM64 构建，当前主机架构为 $HOST_ARCH。
   Flutter 桌面端不支持交叉编译，请在 aarch64 机器或 GitHub Actions 的
   ubuntu-24.04-arm runner 上执行。" ;;
esac

command -v flutter >/dev/null || die "未找到 flutter，请把 Flutter SDK 的 bin 目录加入 PATH（要求 3.47.9）"
command -v dpkg-deb >/dev/null || die "未找到 dpkg-deb，请安装 dpkg-dev"
command -v git >/dev/null || die "未找到 git"

FLUTTER_ROOT="$(cd "$(dirname "$(command -v flutter)")/.." && pwd)"
export FLUTTER_ROOT
log "FLUTTER_ROOT = $FLUTTER_ROOT"
flutter --version 2>&1 | head -2 || true

if [ ! -d "linux" ]; then
  die "当前目录不是 PiliPlus 仓库根目录：$ROOT"
fi

# ------------------------------------------------------ 1. 版本号 + 构建元数据
log "生成版本号与 pili_release.json"
VERSION_NAME="$(sed -n 's/^version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' pubspec.yaml | head -1)"
[ -n "$VERSION_NAME" ] || die "无法从 pubspec.yaml 解析版本号"

if git rev-parse --git-dir >/dev/null 2>&1; then
  VERSION_CODE="$(git rev-list --count HEAD)"
  COMMIT_HASH="$(git rev-parse HEAD)"
else
  die "当前不是 git 仓库。请用 'git clone' 获取源码（完整历史），
   patch 流程依赖 git apply，且版本号来自 commit 数量。"
fi
FULL_VERSION="${VERSION_NAME}+${VERSION_CODE}"
BUILD_TIME="$(date +%s)"

# 改写 pubspec 版本（与上游 lib/scripts/build.ps1 行为一致）
sed -i "s|^version:.*|version: ${FULL_VERSION}|" pubspec.yaml

printf '{"pili.name":"%s","pili.code":%s,"pili.hash":"%s","pili.time":%s}\n' \
  "$VERSION_NAME" "$VERSION_CODE" "$COMMIT_HASH" "$BUILD_TIME" > pili_release.json
log "版本：$FULL_VERSION  commit：${COMMIT_HASH:0:9}"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "version=${FULL_VERSION}" >> "$GITHUB_ENV"
fi

# ------------------------------------------------------------ 2. Flutter 补丁
# 移植自 lib/scripts/patch.ps1（platform = linux）
normalize_lf() { sed -i 's/\r$//' "$1"; }

FLUTTER_PATCHES=(
  lib/scripts/modal_barrier.patch
  lib/scripts/text_selection.patch
  lib/scripts/mouse_cursor.patch
  lib/scripts/image_anim.patch
  lib/scripts/layout_builder.patch
  lib/scripts/navigation_drawer.patch
  lib/scripts/popup_menu.patch
  lib/scripts/fab.patch
  lib/scripts/null_safety_for_selectable_region.patch
  lib/scripts/selectable_region.patch
  lib/scripts/editable_text.patch
  lib/scripts/text_field.patch
  lib/scripts/scroll_position.patch
  lib/scripts/scrollable.patch
  lib/scripts/scrollable_gesture.patch
  lib/scripts/draggable_scrollable_sheet.patch
  lib/scripts/scaffold.patch
  lib/scripts/text.patch
  lib/scripts/text_painter.patch
  lib/scripts/sliver.patch
  lib/scripts/refresh_indicator.patch
  lib/scripts/double_tap_gesture.patch
)

MATERIAL_PATCHES=(
  lib/scripts/material/modal_barrier_material.patch
  lib/scripts/material/navigation_drawer.patch
  lib/scripts/material/popup_menu.patch
  lib/scripts/material/fab.patch
  lib/scripts/material/text_field.patch
  lib/scripts/material/scaffold.patch
  lib/scripts/material/refresh_indicator.patch
  lib/scripts/material/tabs.patch
)

log "给 Flutter SDK 打补丁（工作目录：$FLUTTER_ROOT）"
export GIT_AUTHOR_NAME=ci GIT_AUTHOR_EMAIL=example@example.com
export GIT_COMMITTER_NAME=ci GIT_COMMITTER_EMAIL=example@example.com

pushd "$FLUTTER_ROOT" >/dev/null
if [ -d .git ]; then
  git reset --hard HEAD >/dev/null
else
  echo "[WARN] Flutter SDK 不是 git 仓库，跳过 reset（git apply 仍可用）"
fi
for p in "${FLUTTER_PATCHES[@]}"; do
  normalize_lf "$ROOT/$p"
  git apply "$ROOT/$p" || die "补丁失败：$p
  如果这是 Flutter 版本不匹配导致的，请确认 SDK 版本与 .fvmrc 一致（3.47.9）"
  echo "  applied $p"
done
popd >/dev/null

# --------------------------------------------------- 3. pub get + 依赖补丁
log "清理 pub 缓存中的 material_ui / cupertino_ui"
PUB_CACHE_DIR="${PUB_CACHE:-$HOME/.pub-cache}"
rm -rf "$PUB_CACHE_DIR"/hosted/pub.dev/material_ui-* 2>/dev/null || true

log "flutter pub get"
flutter pub get

apply_pub_patches() { # $1=包名前缀 $2...=补丁
  local prefix="$1"; shift
  local dir
  dir="$(ls -d "$PUB_CACHE_DIR"/hosted/pub.dev/"${prefix}"-* 2>/dev/null | sort -V | tail -1)"
  [ -n "$dir" ] || die "pub 缓存中找不到 $prefix 包"
  log "给 $prefix 打补丁（$dir）"
  pushd "$dir" >/dev/null
  local p
  for p in "$@"; do
    normalize_lf "$ROOT/$p"
    git apply "$ROOT/$p" || die "补丁失败：$p"
    echo "  applied $p"
  done
  popd >/dev/null
}

apply_pub_patches material_ui "${MATERIAL_PATCHES[@]}"

# linux 平台不需要 cupertino 补丁，仅做存在性校验（与上游脚本一致）
ls -d "$PUB_CACHE_DIR"/hosted/pub.dev/cupertino_ui-* >/dev/null 2>&1 \
  || die "pub 缓存中找不到 cupertino_ui 包"

# ------------------------------------------------------------ 4. 编译 release
log "flutter build linux --release"
flutter build linux --release --dart-define-from-file=pili_release.json --no-pub

BUNDLE="build/linux/arm64/release/bundle"
[ -x "$BUNDLE/piliplus" ] || die "未找到构建产物：$BUNDLE/piliplus"
log "产物：$BUNDLE"

# ------------------------------------------------------------- 5. 打 deb 包
PKG_NAME="${PKG_NAME:-piliplus}"          # Debian 包名要求全小写
DEB_ARCH="arm64"
DEB_DEPENDS="${DEB_DEPENDS:-libgtk-3-0t64, libmpv2}"
DEB_RECOMMENDS="${DEB_RECOMMENDS:-libwebkit2gtk-4.1-0}"

STAGE="build/deb/PiliPlus_linux_${FULL_VERSION}_${DEB_ARCH}"
OUT_DIR="dist"
mkdir -p "$OUT_DIR"
rm -rf "$STAGE"
mkdir -p "$STAGE"/opt/PiliPlus "$STAGE"/DEBIAN \
         "$STAGE"/usr/share/applications \
         "$STAGE"/usr/share/icons/hicolor/512x512/apps

log "填充安装目录"
cp -r "$BUNDLE"/. "$STAGE"/opt/PiliPlus/
chmod 0755 "$STAGE/opt/PiliPlus/piliplus"

cp assets/linux/com.example.piliplus.desktop "$STAGE/usr/share/applications/"
cp assets/images/logo/logo.png "$STAGE/usr/share/icons/hicolor/512x512/apps/piliplus.png"

# 安装大小（KiB，向上取整）
SIZE_KB=$(( ( $(du -sb --apparent-size "$STAGE/opt" "$STAGE/usr" | awk '{s+=$1} END {print s}') + 1023 ) / 1024 ))

log "生成 DEBIAN/control（Architecture: $DEB_ARCH, Installed-Size: ${SIZE_KB}KB）"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: ${PKG_NAME}
Version: ${FULL_VERSION}
Maintainer: gh-MzA4Nzk <githubaccount2333@proton.me>
Original-Maintainer: bggRGjQaUbCoE <githubaccount56556@proton.me>
Section: x11
Priority: optional
Architecture: ${DEB_ARCH}
Essential: no
Installed-Size: ${SIZE_KB}
Depends: ${DEB_DEPENDS}
Recommends: ${DEB_RECOMMENDS}
Description: third-party Bilibili client developed in Flutter
 PiliPlus is a third-party Bilibili client built with Flutter.
 This package contains the ARM64 (aarch64) Linux desktop build.
Homepage: https://github.com/bggRGjQaUbCoE/PiliPlus
EOF

# 维护脚本：沿用上游 assets/linux/DEBIAN，做两处健壮性修正
cp assets/linux/DEBIAN/postinst "$STAGE/DEBIAN/postinst"
cp assets/linux/DEBIAN/prerm    "$STAGE/DEBIAN/prerm"
cp assets/linux/DEBIAN/postrm   "$STAGE/DEBIAN/postrm"
# postrm 里裸 rm 在文件缺失时会让 dpkg 报错
sed -i 's|^rm /usr/bin/piliplus$|rm -f /usr/bin/piliplus|' "$STAGE/DEBIAN/postrm"
chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm" "$STAGE/DEBIAN/postrm"

log "生成 DEBIAN/md5sums"
pushd "$STAGE" >/dev/null
find opt usr -type f -print0 | xargs -0 md5sum > DEBIAN/md5sums
chmod 0644 DEBIAN/control DEBIAN/md5sums
popd >/dev/null

DEB_FILE="$OUT_DIR/PiliPlus_linux_${FULL_VERSION}_${DEB_ARCH}.deb"
log "dpkg-deb --build"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB_FILE" >/dev/null

log "完成"
dpkg-deb --info "$DEB_FILE" | sed 's/^/    /'
echo
echo "    文件：$ROOT/$DEB_FILE"
echo "    大小：$(du -h "$DEB_FILE" | cut -f1)"
echo
echo "    安装：sudo apt install ./$(basename "$DEB_FILE")"
