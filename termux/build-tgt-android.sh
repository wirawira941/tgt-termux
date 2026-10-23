#!/usr/bin/env bash
# Build tgt (Telegram TUI) for Termux / Android aarch64 — "jalur normal":
# build the REAL TDLib 1.8.61 from source and bundle its libtdjson.so.
#
# Why: tdlib-rs 1.4.0 (used by upstream tgt main) is generated from the
# TDLib 1.8.61 TL scheme. Termux's libtd package is only 1.8.50, whose
# replies omit fields the 1.8.61 types require (e.g. collectible_usernames)
# -> tgt panicked at runtime. Faking the version in tdjson.pc satisfied
# the linker but not the data scheme. So this pipeline builds TDLib
# itself, at the exact commit tdlib-rs 1.4.0 targets, and ships it next
# to tgt. The tdjson.pc then reports the TRUE version 1.8.61.
#
# Layout on the phone (see install-tgt-termux.sh):
#   $PREFIX/bin/tgt                      (RUNPATH: $PREFIX/lib/tgt first)
#   $PREFIX/lib/tgt/libtdjson.so         (bundled 1.8.61, wins over any
#                                         Termux libtd in $PREFIX/lib)
#   runtime deps from pkg: openssl, zlib, libc++
#
# Env inputs:
#   TD_REF           tdlib/td commit       (default: 1.8.61 commit)
#   TGT_REF          upstream tgt commit   (default: main @ 6b2abb9)
#   ANDROID_NDK_HOME / NDK_HOME            (required)
#   API_LEVEL        Android API level     (default: 24)
#   JOBS             parallel build jobs   (default: nproc)
set -euo pipefail

TD_REF="${TD_REF:-11e254af695060d8890024dd7faa1cc2d6685ef8}"
TD_VERSION="1.8.61"
TGT_REF="${TGT_REF:-6b2abb9354515023d3a90853f7d4cc95ba00ce6e}"
OPENSSL_DEB_URL="${OPENSSL_DEB_URL:-https://packages-cf.termux.dev/apt/termux-main/pool/main/o/openssl/openssl_1%3A3.6.5_aarch64.deb}"
ZLIB_DEB_URL="${ZLIB_DEB_URL:-https://packages-cf.termux.dev/apt/termux-main/pool/main/z/zlib/zlib_1.3.2_aarch64.deb}"
HOST_LIBTD_DEB_URL="${HOST_LIBTD_DEB_URL:-https://packages-cf.termux.dev/apt/termux-main/pool/main/libt/libtd/libtd_1.8.50-1_x86_64.deb}"
API_LEVEL="${API_LEVEL:-24}"
FEATURES="${FEATURES:-pkg-config}"
JOBS="${JOBS:-$(nproc)}"
NDK="${ANDROID_NDK_HOME:-${NDK_HOME:-}}"
[ -n "$NDK" ] || { echo "ERROR: ANDROID_NDK_HOME/NDK_HOME not set"; exit 1; }
command -v gperf >/dev/null || { echo "ERROR: gperf missing (needed by TDLib's TL parser build)"; exit 1; }

WORK="${WORK:-$HOME/tgt-build}"
TD_SRC="$WORK/td"
TD_BUILD="$WORK/td-build-android"
TD_INSTALL="$WORK/td-install"
DEPS_SYSROOT="$WORK/deps-sysroot"        # Termux openssl+zlib (aarch64)
DEPS_USR="$DEPS_SYSROOT/data/data/com.termux/files/usr"
SYSROOT="$WORK/termux-sysroot"          # tgt-stage sysroot (our TDLib)
TERMUX_USR="$SYSROOT/data/data/com.termux/files/usr"
HOST_SYSROOT="$WORK/host-sysroot"       # x86_64 libtd for the HOST build-script link
HOST_TERMUX_USR="$HOST_SYSROOT/data/data/com.termux/files/usr"
DIST="${DIST:-$WORK/dist}"
TERMUX_PREFIX="/data/data/com.termux/files/usr"
mkdir -p "$WORK" "$DIST"

extract_deb() { # $1=deb file, $2=dest dir
  if command -v dpkg-deb >/dev/null; then
    dpkg-deb -x "$1" "$2"
  else
    (cd "$2" && ar x "$1" && tar -xf data.tar.* && rm -f data.tar.* debian-binary control.tar.*)
  fi
}

echo "== [1/6] Clone td (TDLib) @ $TD_REF"
if [ ! -d "$TD_SRC/.git" ]; then
  mkdir -p "$TD_SRC"
  git -C "$TD_SRC" init -q
  git -C "$TD_SRC" remote add origin https://github.com/tdlib/td.git
  git -C "$TD_SRC" fetch -q --depth 1 origin "$TD_REF"
  git -C "$TD_SRC" checkout -q FETCH_HEAD
fi
git -C "$TD_SRC" rev-parse HEAD
grep -m1 "project(TDLib" "$TD_SRC/CMakeLists.txt"

echo "== [2/6] Fetch Termux openssl + zlib (TDLib target deps)"
if [ ! -f "$DEPS_USR/lib/libssl.so" ]; then
  mkdir -p "$DEPS_SYSROOT"
  curl -sL -o "$WORK/openssl.deb" "$OPENSSL_DEB_URL"
  curl -sL -o "$WORK/zlib.deb" "$ZLIB_DEB_URL"
  extract_deb "$WORK/openssl.deb" "$DEPS_SYSROOT"
  extract_deb "$WORK/zlib.deb" "$DEPS_SYSROOT"
fi
ls -la "$DEPS_USR/lib/libssl.so" "$DEPS_USR/lib/libz.so" "$DEPS_USR/include/openssl/ssl.h"

echo "== [3/6] Build TDLib $TD_VERSION for aarch64 (target: tdjson)"
if [ ! -f "$TD_INSTALL/lib/libtdjson.so" ]; then
  # Cross-compiling TDLib requires its code generators to run on the HOST
  # first: they emit the *-auto sources into the source tree (run #10 died
  # with "No rule to make target tdutils/generate/auto/mime_type_to_extension.cpp"
  # because this stage was missing). TDLib provides the aggregate target.
  echo "-- Native prepare_cross_compiling (host code generators)"
  cmake -S "$TD_SRC" -B "$WORK/td-build-native" -DCMAKE_BUILD_TYPE=Release
  cmake --build "$WORK/td-build-native" --target prepare_cross_compiling -j "$JOBS"
  ls -la "$TD_SRC/tdutils/generate/auto/mime_type_to_extension.cpp"
  cmake -S "$TD_SRC" -B "$TD_BUILD" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM="android-${API_LEVEL}" \
    -DCMAKE_BUILD_TYPE=Release -DTD_ENABLE_LTO=OFF \
    -DCMAKE_INSTALL_PREFIX="$TD_INSTALL" \
    -DCMAKE_INSTALL_RPATH="$TERMUX_PREFIX/lib" -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
    -DOPENSSL_ROOT_DIR="$DEPS_USR" -DOPENSSL_INCLUDE_DIR="$DEPS_USR/include" \
    -DOPENSSL_SSL_LIBRARY="$DEPS_USR/lib/libssl.so" -DOPENSSL_CRYPTO_LIBRARY="$DEPS_USR/lib/libcrypto.so" \
    -DZLIB_INCLUDE_DIR="$DEPS_USR/include" -DZLIB_LIBRARY="$DEPS_USR/lib/libz.so"
  # Build BOTH tdjson (shared) and tdjson_static: TDLib's install step
  # installs both, and bare `cmake --install` fails with
  # "cannot find libtdjson_static.a" if the static target was never built
  # (run #11 died exactly there, AFTER libtdjson.so itself was built fine).
  cmake --build "$TD_BUILD" --target tdjson tdjson_static -j "$JOBS"
  cmake --install "$TD_BUILD"
  # The bundled libtdjson.so must find its own deps (libssl.so.3 & friends in
  # $PREFIX/lib) WITHOUT any help: TDLib ships it with no RUNPATH, the
  # executable's RUNPATH is not transitive, and LD_LIBRARY_PATH would shadow
  # the bundled lib with Termux's old libtd (all three seen on-device with
  # release .3). Give the library its own RUNPATH.
  patchelf --set-rpath "$TERMUX_PREFIX/lib" "$TD_INSTALL/lib/libtdjson.so"
fi
# patchelf is idempotent, so this runs on every invocation — including runs
# where the TDLib cache hit and the stage above was skipped (release .4
# taught us the hard way: a patchelf hidden inside the cache-if never runs).
readelf -d "$TD_INSTALL/lib/libtdjson.so" | grep "RUNPATH"
ls -la "$TD_INSTALL/lib/libtdjson.so" "$TD_INSTALL/include/td/telegram/td_json_client.h"
readelf -d "$TD_INSTALL/lib/libtdjson.so" | grep NEEDED || true

echo "== [4/6] Assemble tgt sysroot (REAL tdjson $TD_VERSION) + host sysroot"
mkdir -p "$TERMUX_USR/lib/pkgconfig"
cp -a "$TD_INSTALL/include" "$TERMUX_USR/"
cp -a "$TD_INSTALL/lib/libtdjson.so" "$TERMUX_USR/lib/"
cat > "$TERMUX_USR/lib/pkgconfig/tdjson.pc" <<EOF
prefix=$TERMUX_PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: tdjson
Description: Telegram Database library (JSON interface), built from source
Version: $TD_VERSION
Libs: -L\${libdir} -ltdjson
Cflags: -I\${includedir}
EOF
cat "$TERMUX_USR/lib/pkgconfig/tdjson.pc"

# Host sysroot (link-time stand-in ONLY): cargo also builds tdlib-rs for
# the HOST (build-dependency of tgt's build script), and that link must
# resolve -ltdjson against an x86_64 library. The host build script never
# talks to Telegram, so Termux's x86_64 libtd is a safe stand-in; its .pc
# reports 1.8.61 only to satisfy the version probe of that host link.
# The phone's RUNTIME library is the real 1.8.61 built above — no version
# is faked anywhere on the data path.
if [ ! -f "$HOST_TERMUX_USR/lib/libtdjson.so" ]; then
  mkdir -p "$HOST_SYSROOT"
  curl -sL -o "$WORK/libtd-host.deb" "$HOST_LIBTD_DEB_URL"
  extract_deb "$WORK/libtd-host.deb" "$HOST_SYSROOT"
fi
sed -i 's/^Version: .*/Version: 1.8.61/' "$HOST_TERMUX_USR/lib/pkgconfig/tdjson.pc"
grep '^Version:' "$HOST_TERMUX_USR/lib/pkgconfig/tdjson.pc"

echo "== [5/6] Clone tgt @ $TGT_REF"
if [ ! -d "$WORK/tgt/.git" ]; then
  mkdir -p "$WORK/tgt"
  git -C "$WORK/tgt" init -q
  git -C "$WORK/tgt" remote add origin https://github.com/FedericoBruzzone/tgt.git
  git -C "$WORK/tgt" fetch -q --depth 1 origin "$TGT_REF"
  git -C "$WORK/tgt" checkout -q FETCH_HEAD
fi
git -C "$WORK/tgt" rev-parse HEAD

echo "== [6/6] cargo build tgt (features: $FEATURES)"
NDK_BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK_BIN/aarch64-linux-android${API_LEVEL}-clang"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_AR="$NDK_BIN/llvm-ar"
export CC_aarch64_linux_android="$NDK_BIN/aarch64-linux-android${API_LEVEL}-clang"
export CXX_aarch64_linux_android="$NDK_BIN/aarch64-linux-android${API_LEVEL}-clang++"
export AR_aarch64_linux_android="$NDK_BIN/llvm-ar"
# pkg-config env is TARGET-scoped, never global (run #4 lesson), in the
# underscore form bash can export (run #5 lesson).
export PKG_CONFIG_ALLOW_CROSS=1
export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1
export PKG_CONFIG_ALLOW_SYSTEM_LIBS=1
export PKG_CONFIG_PATH_aarch64_linux_android="$TERMUX_USR/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR_aarch64_linux_android="$SYSROOT"
export PKG_CONFIG_PATH_x86_64_unknown_linux_gnu="$HOST_TERMUX_USR/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR_x86_64_unknown_linux_gnu="$HOST_SYSROOT"
PKG_CONFIG_PATH="$TERMUX_USR/lib/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$SYSROOT" pkg-config --modversion tdjson

cd "$WORK/tgt"
# Runtime lookup order: bundled TDLib dir first, then Termux's lib dir.
export RUSTFLAGS="-C link-arg=-Wl,-rpath,$TERMUX_PREFIX/lib/tgt,-rpath,$TERMUX_PREFIX/lib"
# NOTE: no --locked (run #1 lesson).
cargo build --release --target aarch64-linux-android \
  --no-default-features --features "$FEATURES"

BIN="$WORK/tgt/target/aarch64-linux-android/release/tgt"
file "$BIN"
readelf -d "$BIN" | grep -E "NEEDED|RUNPATH"
cp "$BIN" "$DIST/tgt"
cp "$TD_INSTALL/lib/libtdjson.so" "$DIST/libtdjson.so"
echo "Built: $DIST/tgt + $DIST/libtdjson.so"
