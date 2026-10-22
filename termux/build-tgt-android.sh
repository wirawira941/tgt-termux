#!/usr/bin/env bash
# Build tgt (Telegram TUI) for Termux / Android aarch64.
#
# Strategy: cross-compile with the Android NDK, linking dynamically against
# Termux's own TDLib package (libtd) through tgt's `pkg-config` feature.
# The libtd .deb is downloaded from the Termux repo and extracted as a
# sysroot; at runtime the phone resolves libtdjson.so from `pkg install libtd`.
#
# Env inputs:
#   TGT_REF        upstream commit to build       (default: v1.0.0 tag)
#                  PIN RATIONALE (revised after the .1 on-device panic):
#                  tdlib-rs' generated types must not be NEWER than the
#                  runtime TDLib. tdlib-rs 1.3.0/1.4.0 (upstream main) are
#                  generated from the TDLib 1.8.61 scheme; Termux ships
#                  TDLib 1.8.50, whose replies omit newer required fields
#                  (e.g. `collectible_usernames`) -> tgt panicked at
#                  runtime deserializing them. The v1.0.0 tag uses
#                  tdlib-rs 1.0.5 (TDLib 1.8.29 scheme <= 1.8.50 runtime:
#                  the safe direction — unknown newer fields are ignored).
#                  The tag's only Android blocker is its unconditional
#                  arboard dep (no Android backend); termux/patches/
#                  0001-android-termux-clipboard.patch target-gates it
#                  out and routes copy/paste through Termux:API instead.
#   LIBTD_DEB_URL  pinned Termux libtd .deb URL   (default: libtd 1.8.50-1)
#   ANDROID_NDK_HOME / NDK_HOME                   (required)
#   API_LEVEL      Android API level for clang    (default: 24)
#   FEATURES       cargo features                 (default: pkg-config)
#                  Fallback if system-deps/pkg-config misbehaves:
#                  FEATURES=local-tdlib (uses LOCAL_TDLIB_PATH=$SYSROOT)
set -euo pipefail

TGT_REF="${TGT_REF:-9ae9cb6c5788976b8db9e797045b90ffb1ee6d1e}"
LIBTD_DEB_URL="${LIBTD_DEB_URL:-https://packages-cf.termux.dev/apt/termux-main/pool/main/libt/libtd/libtd_1.8.50-1_aarch64.deb}"
HOST_LIBTD_DEB_URL="${HOST_LIBTD_DEB_URL:-https://packages-cf.termux.dev/apt/termux-main/pool/main/libt/libtd/libtd_1.8.50-1_x86_64.deb}"
API_LEVEL="${API_LEVEL:-24}"
FEATURES="${FEATURES:-pkg-config}"
NDK="${ANDROID_NDK_HOME:-${NDK_HOME:-}}"
[ -n "$NDK" ] || { echo "ERROR: ANDROID_NDK_HOME/NDK_HOME not set"; exit 1; }

WORK="${WORK:-$HOME/tgt-build}"
SYSROOT="$WORK/termux-sysroot"          # .deb extracts ./data/data/... under here
HOST_SYSROOT="$WORK/host-sysroot"      # x86_64 libtd for the HOST build script link
TERMUX_USR="$SYSROOT/data/data/com.termux/files/usr"
DIST="${DIST:-$WORK/dist}"
mkdir -p "$WORK" "$DIST"

echo "== [1/5] Clone tgt @ $TGT_REF"
if [ ! -d "$WORK/tgt/.git" ]; then
  mkdir -p "$WORK/tgt"
  git -C "$WORK/tgt" init -q
  git -C "$WORK/tgt" remote add origin https://github.com/FedericoBruzzone/tgt.git
  git -C "$WORK/tgt" fetch -q --depth 1 origin "$TGT_REF"
  git -C "$WORK/tgt" checkout -q FETCH_HEAD
fi
git -C "$WORK/tgt" rev-parse HEAD

# Android clipboard patch (see header): gate arboard out on Android and
# route copy/paste through Termux:API (termux-clipboard-set/get).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIP_PATCH="$SCRIPT_DIR/patches/0001-android-termux-clipboard.patch"
if git -C "$WORK/tgt" apply --check "$CLIP_PATCH" 2>/dev/null; then
  git -C "$WORK/tgt" apply "$CLIP_PATCH"
  echo "Applied Android clipboard patch"
else
  echo "Clipboard patch already applied (or tree dirty); continuing"
fi
grep -n "termux_clipboard_set" "$WORK/tgt/src/components/chat_window.rs" | head -2

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

# Host sysroot (run #4): tgt's own build.rs is compiled+linked for the HOST
# (x86_64). Cargo therefore runs tdlib-rs' pkg-config probe for the host
# too, and the host link must resolve -ltdjson against an x86_64 library.
# Termux's x86_64 libtd .deb provides exactly that.
HOST_TERMUX_USR="$HOST_SYSROOT/data/data/com.termux/files/usr"
if [ ! -f "$HOST_TERMUX_USR/lib/libtdjson.so" ]; then
  mkdir -p "$HOST_SYSROOT"
  curl -sL -o "$WORK/libtd-host.deb" "$HOST_LIBTD_DEB_URL"
  if command -v dpkg-deb >/dev/null; then
    dpkg-deb -x "$WORK/libtd-host.deb" "$HOST_SYSROOT"
  else
    (cd "$HOST_SYSROOT" && ar x "$WORK/libtd-host.deb" && tar -xf data.tar.* && rm -f data.tar.* debian-binary control.tar.*)
  fi
fi
ls -la "$HOST_TERMUX_USR/lib/libtdjson.so" "$HOST_TERMUX_USR/lib/pkgconfig/tdjson.pc"

echo "== [3/5] Toolchain env (NDK: $NDK)"
NDK_BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK_BIN/aarch64-linux-android${API_LEVEL}-clang"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_AR="$NDK_BIN/llvm-ar"
export CC_aarch64_linux_android="$NDK_BIN/aarch64-linux-android${API_LEVEL}-clang"
export CXX_aarch64_linux_android="$NDK_BIN/aarch64-linux-android${API_LEVEL}-clang++"
export AR_aarch64_linux_android="$NDK_BIN/llvm-ar"

echo "== [4/5] pkg-config sysroot env"
# Run #4 lesson: pkg-config env must be TARGET-scoped, never global.
# The host (x86_64) build script's probe otherwise resolves -ltdjson
# against the aarch64 sysroot and the host link dies on the wrong-arch .so.
# (pkg-config crate honours PKG_CONFIG_PATH_<target> over the plain var.)
export PKG_CONFIG_ALLOW_CROSS=1
export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1
export PKG_CONFIG_ALLOW_SYSTEM_LIBS=1
# (Underscore variant: bash cannot export names containing dashes, and the
# pkg-config crate accepts PKG_CONFIG_PATH_<target_with_underscores> as an
# equivalent form — run #5 died on exactly that bash identifier rule.)
export PKG_CONFIG_PATH_aarch64_linux_android="$TERMUX_USR/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR_aarch64_linux_android="$SYSROOT"
export PKG_CONFIG_PATH_x86_64_unknown_linux_gnu="$HOST_TERMUX_USR/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR_x86_64_unknown_linux_gnu="$HOST_SYSROOT"

# TDLib version note: tdlib-rs 1.0.5 (v1.0.0 tag) probes tdjson >= 1.8.29,
# which Termux's real 1.8.50 satisfies — NO version faking. (The .1 build
# faked 1.8.61 for main's tdlib-rs 1.4.0; the C API linked fine, but its
# 1.8.61-scheme types panicked at runtime against the 1.8.50 library.
# Never fake the .pc version again; match the scheme instead.)
grep '^Version:' "$TERMUX_USR/lib/pkgconfig/tdjson.pc" "$HOST_TERMUX_USR/lib/pkgconfig/tdjson.pc"
# Fallback feature path (FEATURES=local-tdlib)
export LOCAL_TDLIB_PATH="$TERMUX_USR"
PKG_CONFIG_PATH="$TERMUX_USR/lib/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$SYSROOT" pkg-config --modversion tdjson
PKG_CONFIG_PATH="$TERMUX_USR/lib/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$SYSROOT" pkg-config --cflags --libs tdjson

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
