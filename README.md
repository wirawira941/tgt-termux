# tgt for Termux (Android aarch64)

Unofficial Termux port of [tgt](https://github.com/FedericoBruzzone/tgt) — a terminal UI for Telegram written in Rust, powered by TDLib.

## How it works

- tgt's bindings (`tdlib-rs` 1.4.0) are generated from the **TDLib 1.8.61** TL scheme. Termux's `libtd` package is only 1.8.50 — new enough to *link*, too old to *talk to*: its replies omit fields the 1.8.61 types require, and the .1 release panicked at startup because of that.
- So CI builds the real **TDLib 1.8.61 from source** (`tdlib/td` at the exact commit tdlib-rs targets), cross-compiled with the Android NDK against Termux's OpenSSL/zlib packages, and the release **bundles the resulting `libtdjson.so`**.
- `tgt` (upstream main) is cross-compiled for `aarch64-linux-android` using its `pkg-config` feature against that TDLib — `tdjson.pc` reports the true version 1.8.61, no version faking anywhere on the runtime path.
- Extras trimmed: no `download-tdlib` (glibc prebuilds don't run on Android), no voice-message/rodio audio yet.

## Install (on the phone)

In Termux:

```sh
curl -LO https://raw.githubusercontent.com/wirawira941/tgt-termux/main/termux/install-tgt-termux.sh
bash install-tgt-termux.sh
```

The installer installs the runtime dependencies (`openssl`, `zlib`, `libc++`), puts the `tgt` binary in `$PREFIX/bin` and the bundled TDLib in `$PREFIX/lib/tgt/` (found first via the binary's RUNPATH, so it never clashes with Termux's own `libtd`), smoke-tests `tgt --help`, and seeds the default config with `tgt init-config`.

First run: get an **API ID / API hash** from https://my.telegram.org, put them into `~/.config/tgt/telegram.toml`, then run `tgt` and follow the login prompts.

## Build

Trigger the `build-termux` workflow (Actions tab → Run workflow). Set `release_tag` (e.g. `v1.0.0-termux.3`) to also publish a Release. Build logic lives in `termux/build-tgt-android.sh`. TDLib is the long pole (~tens of minutes); its build is cached in CI per TDLib commit.
