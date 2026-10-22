#!/data/data/com.termux/files/usr/bin/bash
# Install tgt (Telegram TUI) on Termux (Android aarch64).
#
# This build bundles its own TDLib 1.8.61 (compiled from source, the exact
# version tgt's tdlib-rs bindings target). It does NOT use Termux's libtd
# package (1.8.50 — too old for these bindings; that mismatch is what the
# .1 release got wrong). The bundled library goes into $PREFIX/lib/tgt/,
# which tgt's embedded RUNPATH checks first.
#
# What it does:
#   1. Installs the runtime dependencies of the bundled libtdjson
#      (openssl, zlib, libc++) from the Termux repo.
#   2. Installs the tgt binary into $PREFIX/bin and the bundled
#      libtdjson.so into $PREFIX/lib/tgt/.
#   3. Smoke-tests with `tgt --help` and seeds the default config with
#      `tgt init-config` (only when no config exists yet).
#
# Env:
#   TGT_TAG   release tag to download (default: v1.0.0-termux.4)
set -euo pipefail

TGT_TAG="${TGT_TAG:-v1.0.0-termux.4}"
REPO="wirawira941/tgt-termux"
ASSET="tgt-termux-android-aarch64.zip"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "== tgt Termux installer (bundled TDLib 1.8.61) =="
[ -n "${PREFIX:-}" ] || { echo "ERROR: run this inside Termux (\$PREFIX is empty)."; exit 1; }
[ "$(uname -m)" = "aarch64" ] || { echo "ERROR: this build is for aarch64 only (got $(uname -m))."; exit 1; }

echo "-- Installing runtime dependencies (openssl, zlib, libc++)"
pkg install -y openssl zlib libc++

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -f "$SCRIPT_DIR/tgt" ] && [ -f "$SCRIPT_DIR/libtdjson.so" ]; then
  echo "-- Using tgt + libtdjson.so next to this script"
  cp "$SCRIPT_DIR/tgt" "$SCRIPT_DIR/libtdjson.so" "$WORK/"
else
  echo "-- Downloading $ASSET from release $TGT_TAG"
  curl -sL -o "$WORK/$ASSET" "https://github.com/$REPO/releases/download/$TGT_TAG/$ASSET"
  (cd "$WORK" && unzip -o "$ASSET" >/dev/null)
fi

[ -f "$WORK/libtdjson.so" ] || {
  echo "ERROR: libtdjson.so not found in the package."
  echo "       Release $TGT_TAG may predate the bundled-TDLib builds; use v1.0.0-termux.3 or newer."
  exit 1
}

echo "-- Installing binary to $PREFIX/bin/tgt"
install -m 0755 "$WORK/tgt" "$PREFIX/bin/tgt"
echo "-- Installing bundled TDLib 1.8.61 to $PREFIX/lib/tgt/libtdjson.so"
mkdir -p "$PREFIX/lib/tgt"
install -m 0755 "$WORK/libtdjson.so" "$PREFIX/lib/tgt/libtdjson.so"

echo "-- Smoke test"
"$PREFIX/bin/tgt" --help >/dev/null && echo "tgt --help: OK"
if [ ! -d "$HOME/.config/tgt" ]; then
  echo "-- Seeding default config (~/.config/tgt)"
  "$PREFIX/bin/tgt" init-config
fi

cat <<'EOF'

Done. First run:
  1. Get your own API ID and API hash at https://my.telegram.org (API development tools).
  2. Put them into ~/.config/tgt/telegram.toml (api_id / api_hash) — the
     seeded file only contains upstream's public demo values.
  3. Run:  tgt
     and follow the first-run prompts (phone number + login code from Telegram).

Notes:
  - The old ~/.tgt folder (from the v1.0.0-tag builds) is unused now;
    you can delete it.
  - Copy/paste inside tgt works on this build (upstream's Android support).
EOF
