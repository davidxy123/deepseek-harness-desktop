#!/usr/bin/env bash
#
# 修正 AppImage 内 GStreamer 的两处打包缺陷（桌面端麦克风/语音输入的根因）。
#
# 1) 删除 usr/lib/gstreamer-1.0/libgstpython*.so：GStreamer 做插件扫描时会为该插件
#    初始化 CPython，而宿主 python3 没有 gi 时每次采集都打印
#    "pygobject initialization failed" 的 CRITICAL（WebKit 不用 Python 实现的元素）。
#    在自带 python 的环境里更糟：init 直接致命退出，可能连带拖死插件扫描。
# 2) 修正 apprun-hooks/linuxdeploy-plugin-gstreamer.sh 的辅助程序路径：linuxdeploy 的
#    gstreamer 插件按 Debian 布局写 usr/lib/gstreamer1.0/gstreamer-1.0/，而产物把
#    gst-plugin-scanner 放在 usr/lib/gstreamer-1.0/。路径不存在时 GStreamer 无法启动
#    外部扫描器（日志为成片的 "External plugin loader failed"），WebKit 枚举不到任何
#    音频源，getUserMedia 直接以 NotAllowedError 失败——桌面端因此既没有权限弹窗，
#    也永远拿不到录音。
#
# 重打包复用原 AppImage 自带 runtime 前缀（head -c <offset>），与
# fix-appimage-host-libs.sh 使用同一组 squashfs 参数，不依赖 appimagetool。
set -euo pipefail

readonly GST_DIR=usr/lib/gstreamer-1.0
readonly GST_HOOK=apprun-hooks/linuxdeploy-plugin-gstreamer.sh
readonly WRONG_PREFIX='usr/lib/gstreamer1.0/gstreamer-1.0/'
readonly WRONG_PREFIX_SED='usr/lib/gstreamer1\.0/gstreamer-1\.0/'
readonly RIGHT_PREFIX='usr/lib/gstreamer-1.0/'
readonly SCANNER_NAME=gst-plugin-scanner
readonly PTP_HELPER_NAME=gst-ptp-helper

# 与 linuxdeploy 产出的 squashfs 对齐（实测 zstd / 128K block / 单一 root id）。
readonly SQUASHFS_COMPRESSION=zstd
readonly SQUASHFS_BLOCK_SIZE=131072

# 在镜像中扫描 squashfs 4.0 superblock：magic "hsqs"，版本字段 s_major/s_minor == 4/0，
# block_size 为 2 的幂且在 [4096, 1048576]，compression 在 1..6，block_log 与 block_size 自洽。
# Type-2 AppImage 的尾部是 ELF runtime，正文里还可能出现字面量 "hsqs"，因此必须逐个按
# superblock 字段校验，而不是命中第一个 magic 就返回。
detect_squashfs_offset() {
  local file="$1"
  python3 - "$file" <<'PY'
import struct
import sys

path = sys.argv[1]
with open(path, 'rb') as handle:
    data = handle.read()

start = 0
while True:
    index = data.find(b'hsqs', start)
    if index < 0:
        break
    start = index + 1
    if index + 32 > len(data):
        continue
    (magic, _inodes, _mtime, block_size, _fragments, compression, block_log,
     _flags, _no_ids, s_major, s_minor) = struct.unpack_from('<IIIIIHHHHHH', data, index)
    if magic != 0x73717368:
        continue
    if s_major != 4 or s_minor != 0:
        continue
    if block_size < 4096 or block_size > 1048576 or block_size & (block_size - 1):
        continue
    if compression < 1 or compression > 6:
        continue
    if (1 << block_log) != block_size:
        continue
    print(index)
    sys.exit(0)
sys.exit(1)
PY
}

usage() {
  echo "usage: $(basename "$0") [--require-removal] <path-to.AppImage>" >&2
}

# CI 用 --require-removal：linuxdeploy 若不再打包 libgstpython，剔除会静默变成 no-op。
# 要求「至少删掉一个」把这种退化变成构建失败，提示重新核对（与 host-libs 脚本一致）。
require_removal=0
if [ "${1:-}" = "--require-removal" ]; then
  require_removal=1
  shift
fi

appimage="${1:-}"
if [ -z "$appimage" ]; then
  usage
  exit 2
fi
if [ ! -f "$appimage" ]; then
  echo "fix-appimage-gstreamer: no such file: $appimage" >&2
  exit 1
fi

appimage="$(cd "$(dirname "$appimage")" && pwd)/$(basename "$appimage")"

for tool in mksquashfs unsquashfs python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "fix-appimage-gstreamer: required tool not found: $tool" >&2
    exit 1
  fi
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cp "$appimage" "$work/in.AppImage"
chmod +x "$work/in.AppImage"

# 先让 AppImage 自带 runtime 报出 squashfs 偏移并解包（不挂载 FUSE，容器里可直接跑）。
# runtime 不可执行时（noexec 挂载等）退回扫描 superblock + unsquashfs -o。
offset=""
if offset="$("$work/in.AppImage" --appimage-offset 2>/dev/null)" && [ -n "$offset" ]; then
  case "$offset" in
    *[!0-9]*)
      echo "fix-appimage-gstreamer: unexpected AppImage offset: $offset" >&2
      exit 1
      ;;
  esac
else
  # 注意 set -e：赋值里的命令替换失败会直接终止脚本，因此必须用 `|| true` 兜住。
  offset="$(detect_squashfs_offset "$work/in.AppImage" || true)"
  if [ -z "$offset" ]; then
    echo "fix-appimage-gstreamer: runtime unusable and no squashfs superblock found in $appimage" >&2
    exit 1
  fi
  echo "fix-appimage-gstreamer: runtime unusable, scanned squashfs offset $offset"
fi

tree="$work/squashfs-root"
if ! (
  cd "$work"
  ./in.AppImage --appimage-extract >/dev/null 2>&1
) || [ ! -d "$tree" ]; then
  rm -rf "$tree"
  if ! unsquashfs -o "$offset" -d "$tree" "$work/in.AppImage" >/dev/null; then
    echo "fix-appimage-gstreamer: extraction failed (runtime and unsquashfs)" >&2
    exit 1
  fi
fi
if [ ! -d "$tree" ]; then
  echo "fix-appimage-gstreamer: extraction produced no root directory" >&2
  exit 1
fi

if [ ! -d "$tree/$GST_DIR" ]; then
  echo "fix-appimage-gstreamer: $GST_DIR is missing from the AppDir" >&2
  exit 1
fi

removed=()
while IFS= read -r found; do
  rm -f "$found"
  removed+=("${found#"$tree"/}")
done < <(find "$tree/$GST_DIR" -maxdepth 1 -name 'libgstpython*.so' -print)

hook_changed=0
hook="$tree/$GST_HOOK"
if [ -f "$hook" ] && grep -qF "$WRONG_PREFIX" "$hook"; then
  sed -i "s|$WRONG_PREFIX_SED|$RIGHT_PREFIX|g" "$hook"
  hook_changed=1
fi
if [ -f "$hook" ] && ! grep -q '^export GST_PLUGIN_SCANNER=' "$hook"; then
  printf 'export GST_PLUGIN_SCANNER="${APPDIR}/%s%s"\n' "$RIGHT_PREFIX" "$SCANNER_NAME" >> "$hook"
  hook_changed=1
fi

if [ "${#removed[@]}" -eq 0 ]; then
  if [ "$require_removal" -eq 1 ]; then
    echo "fix-appimage-gstreamer: no libgstpython plugin was bundled, but --require-removal" >&2
    echo "  was requested: the packaging changed. Re-verify before dropping the fix." >&2
    exit 1
  fi
  if [ "$hook_changed" -eq 0 ]; then
    echo "fix-appimage-gstreamer: no Python plugin and no wrong scanner path, nothing to do"
    exit 0
  fi
fi

if [ "${#removed[@]}" -gt 0 ]; then
  echo "fix-appimage-gstreamer: removed from AppDir:"
  printf '  %s\n' "${removed[@]}"
fi
if [ "$hook_changed" -eq 1 ]; then
  echo "fix-appimage-gstreamer: corrected GStreamer helper paths in $GST_HOOK"
fi

head -c "$offset" "$work/in.AppImage" > "$work/out.AppImage"
mksquashfs "$tree" "$work/fs.squashfs" \
  -comp "$SQUASHFS_COMPRESSION" \
  -b "$SQUASHFS_BLOCK_SIZE" \
  -all-root -mkfs-time 0 -no-xattrs -noappend -no-progress -quiet
cat "$work/fs.squashfs" >> "$work/out.AppImage"
chmod +x "$work/out.AppImage"

# 交付前自检：新镜像仍可解包、Python 插件确实消失、钩子不再引用不存在的目录、
# 钩子指向的辅助程序真实存在、AppRun 与主程序仍在。
verify="$work/verify"
mkdir -p "$verify"
verdict=0
if (
  cd "$verify"
  ../out.AppImage --appimage-extract >/dev/null 2>&1
) && [ -d "$verify/squashfs-root" ]; then
  verified="$verify/squashfs-root"
else
  rm -rf "$verify/squashfs-root"
  if unsquashfs -o "$offset" -d "$verify/squashfs-root" "$work/out.AppImage" >/dev/null 2>&1; then
    verified="$verify/squashfs-root"
  else
    echo "fix-appimage-gstreamer: verification failed, repacked image cannot be extracted" >&2
    exit 1
  fi
fi

if find "$verified/$GST_DIR" -maxdepth 1 -name 'libgstpython*.so' -print -quit | grep -q .; then
  echo "fix-appimage-gstreamer: verification failed, libgstpython is still bundled" >&2
  verdict=1
fi
if [ -f "$verified/$GST_HOOK" ]; then
  if grep -qF "$WRONG_PREFIX" "$verified/$GST_HOOK"; then
    echo "fix-appimage-gstreamer: verification failed, hook still references $WRONG_PREFIX" >&2
    verdict=1
  fi
  if ! grep -q '^export GST_PLUGIN_SCANNER=' "$verified/$GST_HOOK"; then
    echo "fix-appimage-gstreamer: verification failed, hook lacks GST_PLUGIN_SCANNER" >&2
    verdict=1
  fi
fi
for helper in "$SCANNER_NAME" "$PTP_HELPER_NAME"; do
  if [ -n "$(find "$verified/$GST_DIR" -maxdepth 1 -name "$helper" -print -quit)" ]; then
    :
  elif grep -qF "$helper" "$verified/$GST_HOOK" 2>/dev/null; then
    echo "fix-appimage-gstreamer: verification failed, $helper is referenced but missing" >&2
    verdict=1
  fi
done
for required in AppRun AppRun.wrapped usr/bin/deepseek-harness-desktop; do
  if [ ! -e "$verified/$required" ]; then
    echo "fix-appimage-gstreamer: verification failed, $required is missing" >&2
    verdict=1
  fi
done
if [ "$verdict" -ne 0 ]; then
  exit 1
fi

# 原子替换：先写同目录临时文件再 rename，避免中断留下半截 AppImage。
tmp="$(mktemp "$(dirname "$appimage")/.$(basename "$appimage").XXXXXX")"
cat "$work/out.AppImage" > "$tmp"
chmod +x "$tmp"
mv -f "$tmp" "$appimage"

echo "fix-appimage-gstreamer: repacked $appimage"
