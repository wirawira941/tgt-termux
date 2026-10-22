# tgt for Termux (Android aarch64)

Unofficial Termux port of [tgt](https://github.com/FedericoBruzzone/tgt) — a terminal UI for Telegram written in Rust, powered by TDLib.

## How it works

- Termux already ships TDLib as the **`libtd`** package (1.8.50), so no TDLib compilation is needed.
- `tgt` is cross-compiled in GitHub Actions for `aarch64-linux-android` (NDK r28c) using its own **`pkg-config`** feature, linking dynamically against Termux's `libtdjson.so`. The Termux `.deb` is extracted as a sysroot during the build.
- v1 trims upstream's default extras: no `download-tdlib` (glibc prebuilds don't run on Android), no voice-message/rodio audio yet.

## Install (on the phone)

Download `tgt-termux-android-aarch64.zip` from the Releases page, unzip, then in Termux:

```sh
bash install-tgt-termux.sh
```

The installer runs `pkg install libtd`, installs the `tgt` binary into `$PREFIX/bin`, and smoke-tests `tgt --help`.

First run: get an **API ID / API hash** from https://my.telegram.org, then run `tgt` and follow the login prompts. Config: `~/.config/tgt`.

## Build

Trigger the `build-termux` workflow (Actions tab → Run workflow). Set `release_tag` (e.g. `v1.0.0-termux.1`) to also publish a Release. Build logic lives in `termux/build-tgt-android.sh`.
