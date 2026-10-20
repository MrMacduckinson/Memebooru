#!/bin/bash
# In-process FFmpeg for the iOS app (apps there can't run helper executables).
# Builds, for iPhone (arm64) and the Simulator (arm64):
#   dav1d (AV1 decode), lame (MP3), opus, libvpx (VP8/VP9), libwebp — from source, static;
#   FFmpeg libraries (LGPL, VideoToolbox/AudioToolbox);
#   fftools' ffmpeg with main() turned into mb_ffmpeg_main() that resets its globals, so the
#   ffmpeg command line can run many times inside one process;
#   scripts/mbffmpeg/mbffmpeg.c — the C entry points the Swift side calls.
# Output: Vendor/ffmpeg-ios/MBFFmpeg.xcframework (one static library per slice + header + modulemap).
set -euo pipefail
FFMPEG=8.0.1; DAV1D=1.5.3; LAME=3.100; OPUS=1.5.2; WEBP=1.6.0; VPX=1.15.2
MIN_IOS=26.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/Vendor/ffmpeg-ios/build"
OUT="$ROOT/Vendor/ffmpeg-ios"
SHIM="$ROOT/scripts/mbffmpeg"
JOBS="$(sysctl -n hw.ncpu)"
mkdir -p "$WORK/src" "$OUT"

fetch() { # url file
  [ -f "$WORK/src/$2" ] || curl -fsSL -o "$WORK/src/$2" "$1"
}
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG.tar.xz" "ffmpeg-$FFMPEG.tar.xz"
fetch "https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D/dav1d-$DAV1D.tar.xz" "dav1d-$DAV1D.tar.xz"
fetch "https://downloads.sourceforge.net/project/lame/lame/$LAME/lame-$LAME.tar.gz" "lame-$LAME.tar.gz"
fetch "https://downloads.xiph.org/releases/opus/opus-$OPUS.tar.gz" "opus-$OPUS.tar.gz"
fetch "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$WEBP.tar.gz" "libwebp-$WEBP.tar.gz"
fetch "https://github.com/webmproject/libvpx/archive/refs/tags/v$VPX.tar.gz" "libvpx-$VPX.tar.gz"

[ -d "$WORK/venv" ] || python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install -q meson ninja
export PATH="$WORK/venv/bin:$PATH"

# FFmpeg source, patched once: fftools' main → mb_ffmpeg_main_impl + a resetting wrapper.
FSRC="$WORK/ffmpeg-$FFMPEG"
if [ ! -d "$FSRC" ]; then
  tar xf "$WORK/src/ffmpeg-$FFMPEG.tar.xz" -C "$WORK"
  sed -i '' 's/^int main(int argc, char \*\*argv)$/int mb_ffmpeg_main(int argc, char **argv);\
int mb_ffmpeg_main_impl(int argc, char **argv);\
int mb_ffmpeg_main_impl(int argc, char **argv)/' "$FSRC/fftools/ffmpeg.c"
  grep -q "mb_ffmpeg_main_impl" "$FSRC/fftools/ffmpeg.c" || { echo "patch failed"; exit 1; }
  cat >> "$FSRC/fftools/ffmpeg.c" <<'EOF'

/* Memebooru: run the command line repeatedly inside one process. ffmpeg_cleanup() frees the
 * arrays but leaves their counts and the run flags behind; reset them before every run. */
int mb_ffmpeg_main(int argc, char **argv)
{
    nb_input_files = 0; nb_output_files = 0; nb_filtergraphs = 0; nb_decoders = 0;
    received_sigterm = 0; received_nb_signals = 0; ffmpeg_exited = 0;
    atomic_store(&transcode_init_done, 0);
    copy_ts_first_pts = AV_NOPTS_VALUE;
    return mb_ffmpeg_main_impl(argc, argv);
}
EOF
fi

build_slice() { # name sdk triple
  local NAME=$1 SDK=$2 TRIPLE=$3
  local P="$WORK/$NAME" PREFIX="$WORK/$NAME/prefix"
  local SYSROOT; SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
  local CC; CC="$(xcrun --sdk "$SDK" -f clang)"
  local FLAGS="-target $TRIPLE -isysroot $SYSROOT"
  mkdir -p "$P" "$PREFIX/lib" "$PREFIX/include"
  echo "== [$NAME] dependencies"

  if [ ! -f "$PREFIX/lib/libdav1d.a" ]; then
    rm -rf "$P/dav1d"; mkdir -p "$P/dav1d"; tar xf "$WORK/src/dav1d-$DAV1D.tar.xz" -C "$P/dav1d" --strip-components 1
    cat > "$P/dav1d/cross.txt" <<EOF
[binaries]
c = '$CC'
ar = '$(xcrun --sdk "$SDK" -f ar)'
strip = '$(xcrun --sdk "$SDK" -f strip)'
[built-in options]
c_args = ['-target', '$TRIPLE', '-isysroot', '$SYSROOT']
c_link_args = ['-target', '$TRIPLE', '-isysroot', '$SYSROOT']
[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
    (cd "$P/dav1d" && meson setup build --cross-file cross.txt --buildtype=release --default-library=static \
        -Denable_tools=false -Denable_tests=false --prefix="$PREFIX" --libdir=lib >"$P/dav1d.log" 2>&1 \
      && ninja -C build install >>"$P/dav1d.log" 2>&1) || { tail -20 "$P/dav1d.log"; exit 1; }
  fi

  if [ ! -f "$PREFIX/lib/libmp3lame.a" ]; then
    rm -rf "$P/lame"; mkdir -p "$P/lame"; tar xf "$WORK/src/lame-$LAME.tar.gz" -C "$P/lame" --strip-components 1
    # lame 3.100 lists a symbol that doesn't exist; newer toolchains refuse the export list.
    sed -i '' '/lame_init_old/d' "$P/lame/include/libmp3lame.sym" 2>/dev/null || true
    (cd "$P/lame" && ac_cv_header_stdc=yes CC="$CC" CFLAGS="$FLAGS -O2" LDFLAGS="$FLAGS" ./configure --host=aarch64-apple-darwin \
        --prefix="$PREFIX" --disable-shared --enable-static --disable-frontend --disable-decoder >"$P/lame.log" 2>&1 \
      && make -j"$JOBS" install >>"$P/lame.log" 2>&1) || { tail -20 "$P/lame.log"; exit 1; }
  fi

  local CMAKE_ARGS=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT="$SYSROOT"
                    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release
                    -DBUILD_SHARED_LIBS=OFF -DCMAKE_C_FLAGS="-target $TRIPLE")
  if [ ! -f "$PREFIX/lib/libopus.a" ]; then
    rm -rf "$P/opus"; mkdir -p "$P/opus"; tar xf "$WORK/src/opus-$OPUS.tar.gz" -C "$P/opus" --strip-components 1
    (cd "$P/opus" && cmake -S . -B build "${CMAKE_ARGS[@]}" -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DBUILD_TESTING=OFF >"$P/opus.log" 2>&1 \
      && cmake --build build -j"$JOBS" --target install >>"$P/opus.log" 2>&1) || { tail -20 "$P/opus.log"; exit 1; }
  fi

  if [ ! -f "$PREFIX/lib/libwebp.a" ]; then
    rm -rf "$P/webp"; mkdir -p "$P/webp"; tar xf "$WORK/src/libwebp-$WEBP.tar.gz" -C "$P/webp" --strip-components 1
    (cd "$P/webp" && cmake -S . -B build "${CMAKE_ARGS[@]}" -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
        -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF \
        -DWEBP_BUILD_EXTRAS=OFF >"$P/webp.log" 2>&1 \
      && cmake --build build -j"$JOBS" --target install >>"$P/webp.log" 2>&1) || { tail -20 "$P/webp.log"; exit 1; }
  fi

  if [ ! -f "$PREFIX/lib/libvpx.a" ]; then
    rm -rf "$P/vpx"; mkdir -p "$P/vpx"; tar xf "$WORK/src/libvpx-$VPX.tar.gz" -C "$P/vpx" --strip-components 1
    # Device: libvpx's own iOS toolchain (NEON). Simulator: libvpx has no arm64 simulator target, so
    # plain portable C through our compiler flags (speed doesn't matter there).
    local VPXENV=(IOS_VERSION_MIN=$MIN_IOS) VPXT=arm64-darwin-gcc
    if [ "$SDK" != iphoneos ]; then
      VPXENV=(CC="$CC $FLAGS" CXX="$(xcrun --sdk "$SDK" -f clang++) $FLAGS" AR="$(xcrun --sdk "$SDK" -f ar)" LD="$CC $FLAGS"); VPXT=generic-gnu
    fi
    (cd "$P/vpx" && env "${VPXENV[@]}" ./configure --target=$VPXT --prefix="$PREFIX" --disable-examples --disable-tools \
        --disable-docs --disable-unit-tests --enable-pic --disable-shared --enable-static >"$P/vpx.log" 2>&1 \
      && make -j"$JOBS" install >>"$P/vpx.log" 2>&1) || { tail -20 "$P/vpx.log"; exit 1; }
  fi

  echo "== [$NAME] ffmpeg"
  local B="$P/ffmpeg"
  if [ ! -f "$B/config.h" ]; then
    rm -rf "$B"; mkdir -p "$B"
    (cd "$B" && PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" "$FSRC/configure" \
        --prefix="$P/ffmpeg-install" --enable-cross-compile --target-os=darwin --arch=arm64 \
        --cc="$CC" --sysroot="$SYSROOT" \
        --extra-cflags="-target $TRIPLE -I$PREFIX/include" --extra-ldflags="-target $TRIPLE -L$PREFIX/lib" \
        --pkg-config=pkg-config --pkg-config-flags=--static \
        --enable-static --disable-shared --disable-doc --disable-debug --disable-network --disable-avdevice \
        --disable-ffplay --disable-ffprobe --disable-autodetect \
        --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib \
        --enable-libdav1d --enable-libmp3lame --enable-libopus --enable-libvpx --enable-libwebp \
        >"$P/ffmpeg-configure.log" 2>&1) || { tail -30 "$P/ffmpeg-configure.log"; exit 1; }
  fi
  # Libraries, then the fftools objects (linking the ffmpeg program itself fails — main is gone — and that's fine).
  (cd "$B" && make -j"$JOBS" >"$P/ffmpeg-make.log" 2>&1; make -j"$JOBS" -k ffmpeg_g >>"$P/ffmpeg-make.log" 2>&1; make install-headers >>"$P/ffmpeg-make.log" 2>&1) || true
  [ -f "$B/libavcodec/libavcodec.a" ] && [ -f "$B/fftools/ffmpeg.o" ] || { grep -E "error:" "$P/ffmpeg-make.log" | head -20; exit 1; }

  echo "== [$NAME] shim + merge"
  "$CC" -target "$TRIPLE" -isysroot "$SYSROOT" -O2 -I"$P/ffmpeg-install/include" -c "$SHIM/mbffmpeg.c" -o "$P/mbffmpeg.o"
  local OBJS; OBJS=$(cd "$B" && find fftools -name '*.o' ! -name 'ffprobe.o' ! -name 'ffplay*.o' | sed "s|^|$B/|")
  xcrun libtool -static -no_warning_for_no_symbols -o "$P/libMBFFmpeg.a" \
    "$B"/libavcodec/libavcodec.a "$B"/libavformat/libavformat.a "$B"/libavfilter/libavfilter.a \
    "$B"/libavutil/libavutil.a "$B"/libswscale/libswscale.a "$B"/libswresample/libswresample.a \
    "$PREFIX"/lib/libdav1d.a "$PREFIX"/lib/libmp3lame.a "$PREFIX"/lib/libopus.a "$PREFIX"/lib/libvpx.a \
    "$PREFIX"/lib/libwebp.a "$PREFIX"/lib/libwebpmux.a "$PREFIX"/lib/libwebpdemux.a "$PREFIX"/lib/libsharpyuv.a \
    $OBJS "$P/mbffmpeg.o"
}

build_slice ios iphoneos "arm64-apple-ios$MIN_IOS"
build_slice sim iphonesimulator "arm64-apple-ios$MIN_IOS-simulator"

echo "== xcframework"
H="$WORK/headers"; rm -rf "$H"; mkdir -p "$H"
cp "$SHIM/mbffmpeg.h" "$H/"
printf 'module MBFFmpeg {\n  header "mbffmpeg.h"\n  export *\n}\n' > "$H/module.modulemap"
rm -rf "$OUT/MBFFmpeg.xcframework"
xcodebuild -create-xcframework \
  -library "$WORK/ios/libMBFFmpeg.a" -headers "$H" \
  -library "$WORK/sim/libMBFFmpeg.a" -headers "$H" \
  -output "$OUT/MBFFmpeg.xcframework" >/dev/null
du -sh "$OUT/MBFFmpeg.xcframework"/*/libMBFFmpeg.a
echo "done: $OUT/MBFFmpeg.xcframework"
