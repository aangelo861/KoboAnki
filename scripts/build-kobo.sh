#!/usr/bin/env bash
#
# build-kobo.sh - cross-compile the kanki server for the Kobo (Libra Colour and other ARM Kobos).
#
# Target: armv7-unknown-linux-musleabihf, i.e. ARMv7-A, Thumb-2, VFPv3-D16 and the hard-float
# ABI, linked fully statically against musl 1.2.5. The Kobo userland is old glibc, so a static
# binary avoids glibc version problems, and it needs nothing from the device but the kernel.
#
# Toolchain: cargo-zigbuild, which uses `zig cc` as both the C compiler (for ring, bundled
# SQLite, zstd and blake3) and the linker. No ARM GCC sysroot is needed. Verified with
# rustc 1.99.1, cargo-zigbuild 0.24, zig 0.16.0 and Anki rslib 26.09.3.
#
# Usage:
#   scripts/build-kobo.sh [--small] [extra cargo args...]
#     --small   fat LTO and 1 codegen unit: the kanki server drops from 27.6 MB to 18.8 MB and
#               usually runs a little faster, but every rebuild redoes the whole LTO link
#               (about 3 min instead of under 1 min). Use it for builds that go on the device
#               for real use. The default (dev loop) build keeps the workspace
#               [profile.release] unchanged.
#
# Environment (all optional):
#   CARGO_TARGET_DIR   default <repo>/target-arm, kept apart from target/ so that native and
#                      cross builds don't invalidate each other
#   JOBS               parallel rustc/cc jobs (default 4; the build machine has 8 GB of RAM)
#   PROTOC             protobuf compiler for Anki's build scripts (default: protoc on PATH)
#
# Output: progress goes to stderr. The last line on stdout is the path of the built binary.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="armv7-unknown-linux-musleabihf"

die() { echo "build-kobo.sh: $*" >&2; exit 1; }

# rustup/cargo/cargo-zigbuild live in ~/.cargo/bin; zig and protoc come from Homebrew.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

SMALL=0
if [[ "${1:-}" == "--small" ]]; then SMALL=1; shift; fi

# --- Prerequisites ------------------------------------------------------------------------------
command -v cargo-zigbuild >/dev/null || die "cargo-zigbuild not found (cargo install --locked cargo-zigbuild)"
command -v zig >/dev/null            || die "zig not found (brew install zig)"
export PROTOC="${PROTOC:-$(command -v protoc || true)}"
[[ -x "$PROTOC" ]]                   || die "protoc not found (brew install protobuf)"
rustup target list --installed 2>/dev/null | grep -qx "$TARGET" \
    || die "Rust std for $TARGET missing (rustup target add $TARGET)"

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target-arm}"
JOBS="${JOBS:-4}"

# --- Leave out Anki's desktop (Qt) translations ---------------------------------------------------
# rslib's i18n build script compiles every .ftl file into the binary: the core strings that rslib
# uses (about 6.8 MB for 70 languages) and the desktop GUI's Qt strings (about 0.9 MB), which
# rslib never uses. EXTRA_FTL_ROOT is the hook AnkiDroid/AnkiMobile use to swap the Qt set for
# their own; pointing it at an empty folder just drops it. No runtime cost, about 0.9 MiB smaller.
# Caveat: that build script doesn't declare rerun-if-env-changed, so cargo won't rerun it if you
# change this setting later. Then: rm -rf "$CARGO_TARGET_DIR/$TARGET/release/build/anki_i18n-"*
EMPTY_FTL="$CARGO_TARGET_DIR/empty-ftl-root"
mkdir -p "$EMPTY_FTL"
export EXTRA_FTL_ROOT="$EMPTY_FTL"

# --- Profile tweaks (env overrides of the workspace profile; Cargo.toml is not touched) ---------
# kanki server as of 2026-11-01 (stripped, bytes): default 27,581,504; --small 18,830,928.
# Measured earlier on a smaller test binary that links rslib, reqwest/rustls and tokio:
#   workspace profile (opt 3, cu 16, no LTO, strip)    15,764,520
#   + Qt translations dropped (always, see above)      14,808,808   <- default build
#   + lto=thin                                         +186 KB vs workspace profile (not used)
#   + lto=fat, codegen-units=1                         -954 KB vs workspace profile (--small)
#   + panic=abort                                      a further -367 KB (not used, see below)
#   + opt-level=s                                      a further -1.4 MB (not used: slower code)
#   without strip                                      34,205,668
# panic=abort is deliberately not used: with unwinding, a panic in one request or sync thread
# stays in that thread instead of killing the whole server.
if (( SMALL )); then
    export CARGO_PROFILE_RELEASE_LTO=fat
    export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
fi

# --- Notes on things that needed no workaround --------------------------------------------------
# * TLS: kanki enables reqwest's rustls-tls-webpki-roots, which pulls in ring (not aws-lc-rs),
#   and Mozilla's root certificates are compiled in. ring's ARMv7 assembly builds with zig cc.
# * No -latomic is needed: Rust implements 64-bit atomics on ARMv7 with ldrexd/strexd, and zig's
#   compiler-rt covers any __atomic_* calls from C.
# * Thread stacks: Rust threads (std, rayon, tokio) default to 2 MiB whatever the libc. zig's
#   linker writes a 16 MiB PT_GNU_STACK, which musl uses (capped at 8 MiB) as the default for
#   threads created from C, such as zstd's workers. So RUST_MIN_STACK isn't needed.
# * Kernel 4.9: musl falls back from the *_time64 syscalls, and Rust std from statx, when the
#   kernel returns ENOSYS.

cd "$ROOT"

# Guard: TLS must stay on ring. aws-lc-sys (C + CMake + assembly) is painful to cross-build with
# zig. It would come in through rustls' default features (rustls 0.23 defaults to aws_lc_rs) or a
# bump to reqwest 0.13, whose rustls feature defaults to aws-lc-rs. `cargo tree -i` fails when the
# package isn't in the graph.
if cargo tree -q --target "$TARGET" -p kanki -i aws-lc-sys >/dev/null 2>&1; then
    echo "build-kobo.sh: warning: aws-lc-sys is in the dependency graph; see why with:" >&2
    echo "  cargo tree --target $TARGET -p kanki -i aws-lc-sys -e features" >&2
fi

# Don't embed the builder's home directory in the binary (panic locations keep source paths): map the
# cargo registry and this checkout to neutral prefixes. Release binaries are published.
REMAP="--remap-path-prefix=$HOME/.cargo=/cargo --remap-path-prefix=$ROOT=/src --remap-path-prefix=$HOME=/home"
export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_RUSTFLAGS="${CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_RUSTFLAGS:-} $REMAP"

echo "Building kanki for $TARGET (target dir $CARGO_TARGET_DIR, jobs $JOBS, small=$SMALL) ..." >&2
cargo zigbuild --release --target "$TARGET" -p kanki -j "$JOBS" "$@" >&2

BIN="$CARGO_TARGET_DIR/$TARGET/release/kanki"
[[ -f "$BIN" ]] || die "build finished but $BIN is missing"

# Sanity check: must be a static 32-bit ARM executable (ELF flags: EABI5, hard-float ABI).
desc="$(file -b "$BIN")"
[[ "$desc" == *"ELF 32-bit LSB executable, ARM, EABI5"* && "$desc" == *"statically linked"* ]] \
    || die "unexpected binary type: $desc"
echo "$desc" >&2
echo "size: $(stat -f %z "$BIN") bytes" >&2
echo "$BIN"
