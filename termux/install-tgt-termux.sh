#!/data/data/com.termux/files/usr/bin/bash
# Install tgt (Telegram TUI) on Termux (Android aarch64).
#
# What it does:
#   1. Installs Termux's TDLib package (libtd) — tgt links to it dynamically.
#   2. Installs the tgt binary (from this folder if present, else downloaded
#      from the GitHub release) into $PREFIX/bin.
#   3. Creates ~/.tgt (tgt v1.0.0 panics at startup if it does not exist).
#   4. Smoke-tests with `tgt --help`.
#
# Env:
#   TGT_TAG   release tag to download (default: v1.0.0-termux.2)
set -euo pipefail

TGT_TAG="${TGT_TAG:-v1.0.0-termux.2}"
REPO="wirawira941/tgt-termux"
ASSET="tgt-termux-android-aarch64.zip"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "== tgt Termux installer =="
[ -n "${PREFIX:-}" ] || { echo "ERROR: run this inside Termux (\$PREFIX is empty)."; exit 1; }
[ "$(uname -m)" = "aarch64" ] || { echo "ERROR: this build is for aarch64 only (got $(uname -m))."; exit 1; }

echo "-- Installing TDLib (libtd) from Termux repo"
pkg install -y libtd

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -f "$SCRIPT_DIR/tgt" ]; then
  echo "-- Using tgt binary next to this script"
  cp "$SCRIPT_DIR/tgt" "$WORK/tgt"
else
  echo "-- Downloading $ASSET from release $TGT_TAG"
  curl -sL -o "$WORK/$ASSET" "https://github.com/$REPO/releases/download/$TGT_TAG/$ASSET"
  (cd "$WORK" && unzip -o "$ASSET" >/dev/null)
fi

echo "-- Installing binary to $PREFIX/bin/tgt"
install -m 0755 "$WORK/tgt" "$PREFIX/bin/tgt"

echo "-- Creating tgt home directory (~/.tgt)"
mkdir -p "$HOME/.tgt"

echo "-- Seeding default config into ~/.tgt/config (existing files are kept)"
mkdir -p "$HOME/.tgt/config"
CFG_BASE="https://raw.githubusercontent.com/FedericoBruzzone/tgt/v1.0.0/config"
for f in app.toml keymap.toml logger.toml telegram.toml theme.toml; do
  if [ ! -f "$HOME/.tgt/config/$f" ]; then
    curl -sfL -o "$HOME/.tgt/config/$f" "$CFG_BASE/$f" \
      || { echo "ERROR: failed to download default config $f"; exit 1; }
  fi
done

echo "-- Smoke test"
"$PREFIX/bin/tgt" --help >/dev/null && echo "tgt --help: OK"

cat <<'EOF'

Done. First run:
  1. Get your own API ID and API hash at https://my.telegram.org (API development tools).
  2. Put them into ~/.tgt/config/telegram.toml (api_id / api_hash) — the
     seeded file only contains upstream's public demo values.
  3. Run:  tgt
     and follow the first-run prompts (phone number + login code from Telegram).

Config lives in ~/.tgt/config. Enjoy!
EOF
