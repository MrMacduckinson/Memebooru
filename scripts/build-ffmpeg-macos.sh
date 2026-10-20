#!/bin/bash
# Builds self-contained ffmpeg + ffprobe for the Mac app (arm64, static, LGPL — no x264/x265).
# Output: Vendor/ffmpeg/bin/{ffmpeg,ffprobe}. The Xcode build copies them into the app bundle.
# Needs: Xcode CLT, nasm, pkg-config, python3, and Homebrew static libs: lame, libvpx, webp, opus.
# dav1d (AV1 decoder) is built from source here — Homebrew ships it only as a dylib.
set -euo pipefail
VERSION=8.0.1
DAV1D=1.5.3
MIN_OS=26.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/Vendor/ffmpeg/build"
OUT="$ROOT/Vendor/ffmpeg/bin"
BREW="$(brew --prefix)"
mkdir -p "$WORK" "$OUT"
cd "$WORK"

[ -f "ffmpeg-$VERSION.tar.xz" ] || curl -fsSLO "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
[ -d "ffmpeg-$VERSION" ] || tar xf "ffmpeg-$VERSION.tar.xz"

# Only the static archives, so the linker can't pick Homebrew's dylibs (the binary must not depend on brew).
STATIC="$WORK/static"; rm -rf "$STATIC"; mkdir -p "$STATIC"
for l in mp3lame vpx webp webpmux webpdemux sharpyuv opus; do
  ln -sf "$BREW/lib/lib$l.a" "$STATIC/lib$l.a"
done

# dav1d, static, via meson/ninja from a private venv (nothing installed system-wide).
if [ ! -f "$WORK/dav1d-install/lib/libdav1d.a" ]; then
  [ -d "$WORK/venv" ] || python3 -m venv "$WORK/venv"
  "$WORK/venv/bin/pip" install -q meson ninja
  [ -f "dav1d-$DAV1D.tar.xz" ] || curl -fsSLO "https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D/dav1d-$DAV1D.tar.xz"
  [ -d "dav1d-$DAV1D" ] || tar xf "dav1d-$DAV1D.tar.xz"
  ( cd "dav1d-$DAV1D" && rm -rf build && \
    PATH="$WORK/venv/bin:$PATH" meson setup build --buildtype=release --default-library=static \
      -Denable_tools=false -Denable_tests=false --prefix="$WORK/dav1d-install" --libdir=lib \
      -Dc_args="-mmacosx-version-min=$MIN_OS" > "$WORK/dav1d.log" 2>&1 && \
    PATH="$WORK/venv/bin:$PATH" ninja -C build install >> "$WORK/dav1d.log" 2>&1 ) || { tail -20 "$WORK/dav1d.log"; exit 1; }
fi
ln -sf "$WORK/dav1d-install/lib/libdav1d.a" "$STATIC/libdav1d.a"
export PKG_CONFIG_PATH="$WORK/dav1d-install/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

cd "ffmpeg-$VERSION"
make distclean >/dev/null 2>&1 || true
./configure \
  --prefix="$WORK/install" \
  --arch=arm64 --cc=clang \
  --enable-static --disable-shared \
  --disable-doc --disable-ffplay --disable-debug --disable-network \
  --disable-autodetect \
  --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib \
  --enable-libmp3lame --enable-libvpx --enable-libwebp --enable-libopus --enable-libdav1d \
  --extra-cflags="-I$BREW/include -I$WORK/dav1d-install/include -mmacosx-version-min=$MIN_OS" \
  --extra-ldflags="-L$STATIC -mmacosx-version-min=$MIN_OS" \
  --pkg-config-flags="--static" \
  > "$WORK/configure.log" 2>&1 || { tail -30 "$WORK/configure.log"; exit 1; }
make -j"$(sysctl -n hw.ncpu)" > "$WORK/make.log" 2>&1 || { tail -40 "$WORK/make.log"; exit 1; }
cp ffmpeg ffprobe "$OUT/"
strip "$OUT/ffmpeg" "$OUT/ffprobe"
echo "== linked libraries (must be system only):"
otool -L "$OUT/ffmpeg" | tail -n +2
if otool -L "$OUT/ffmpeg" "$OUT/ffprobe" | grep -q "$BREW"; then echo "ERROR: links against Homebrew"; exit 1; fi
ls -lh "$OUT"
