#!/usr/bin/env bash
# Build tgt (Telegram TUI) for Termux / Android aarch64.
#
# Strategy: cross-compile with the Android NDK, linking dynamically against
# Termux's own TDLib package (libtd) through tgt's `pkg-config` feature.
# The libtd .deb is downloaded from the Termux repo and extracted as a
# sysroot; at runtime the phone resolves libtdjson.so from `pkg install libtd`.
#
# Env inputs:
#   TGT_REF        upstream tag/commit to build   (default: v1.0.0)
#   LIBTD_DEB_URL  pinned Termux libtd .deb URL   (default: libtd 1.8.50-1)
#   ANDROID_NDK_HOME / NDK_HOME                   (required)
#   API_LEVEL      Android API level for clang    (default: 24)
#   FEATURES       cargo features                 (default: pkg-config)
#                  Fallback if system-deps/pkg-config misbehaves:
#                  FEATURES=local-tdlib (uses LOCAL_TDLIB_PATH=$SYSROOT)
set -euo pipefail

TGT_REF="${TGT_REF:-v1.0.0}"
LIBTD_DEB_URL="${LIBTD_DEB_URL:-https://packages-cf.termux.dev/apt/termux-main/pool/main/libt/libtd/libtd_1.8.50-1_aarch64.deb}"
API_LEVEL="${API_LEVEL:-24}"
FEATURES="${FEATURES:-pkg-config}"
NDK="${ANDROID_NDK_HOME:-${NDK_HOME:-}}"
[ -n "$NDK" ] || { echo "ERROR: ANDROID_NDK_HOME/NDK_HOME not set"; exit 1; }

WORK="${WORK:-$HOME/tgt-build}"
SYSROOT="$WORK/termux-sysroot"          # .deb extracts ./data/data/... under here
TERMUX_USR="$SYSROOT/data/data/com.termux/files/usr"
DIST="${DIST:-$WORK/dist}"
mkdir -p "$WORK" "$DIST"

echo "== [1/5] Clone tgt @ $TGT_REF"
if [ ! -d "$WORK/tgt/.git" ]; then
  git clone --depth 1 --branch "$TGT_REF" https://github.com/FedericoBruzzone/tgt.git "$WORK/tgt"
fi

echo "== [2/5] Fetch Termux libtd (sysroot)"
if [ ! -f "$TERMUX_USR/lib/libtdjson.so" ]; then
  mkdir -p "$SYSROOT"
  curl -sL -o "$WORK/libtd.deb" "$LIBTD_DEB_URL"
  # .deb is an ar archive; dpkg-deb may not exist on the runner
  if command -v dpkg-deb >/dev/null; then
    dpkg-deb -x "$WORK/libtd.deb" "$SYSROOT"
  else
    (cd "$SYSROOT" && ar x "$WORK/libtd.deb" && tar -xf data.tar.* && rm -f data.tar.* debian-binary control.tar.*)
  fi
fi
ls -la "$TERMUX_USR/lib/libtdjson.so" "$TERMUX_USR/lib/pkgconfig/tdjson.pc"

echo "== [3/5] Toolchain env (NDK: $NDK)"
NDK_BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK_BIN/aarch64-linux-android${API_LEVEL}-clang"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_AR="$NDK_BIN/llvm-ar"
export CC_aarch64_linux_android="$NDK_BIN/aarch64-linux-android${API_LEVEL}-clang"
export CXX_aarch64_linux_android="$NDK_BIN/aarch64-linux-android${API_LEVEL}-clang++"
export AR_aarch64_linux_android="$NDK_BIN/llvm-ar"

echo "== [4/5] pkg-config sysroot env"
export PKG_CONFIG_ALLOW_CROSS=1
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export PKG_CONFIG_PATH="$TERMUX_USR/lib/pkgconfig"
# Fallback feature path (FEATURES=local-tdlib)
export LOCAL_TDLIB_PATH="$TERMUX_USR"
pkg-config --modversion tdjson
pkg-config --cflags --libs tdjson

echo "== [5/5] cargo build (features: $FEATURES)"
cd "$WORK/tgt"
# Runtime lookup: Termux keeps its libs in $PREFIX/lib; embed that rpath.
export RUSTFLAGS="-C link-arg=-Wl,-rpath,/data/data/com.termux/files/usr/lib"
# NOTE: no --locked — the v1.0.0 tag's Cargo.lock does not cover this
# feature set, so cargo must be allowed minimal lock updates (run #1 died
# on exactly that). The lock still pins the base resolution.
cargo build --release --target aarch64-linux-android \
  --no-default-features --features "$FEATURES"

BIN="$WORK/tgt/target/aarch64-linux-android/release/tgt"
file "$BIN"
cp "$BIN" "$DIST/tgt"
echo "Built: $DIST/tgt"
