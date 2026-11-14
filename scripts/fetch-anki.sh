#!/usr/bin/env bash
#
# fetch-anki.sh - put Anki's source where the build expects it: vendor/anki = Anki 26.09.3 + our patch.
#
# kanki links Anki's own Rust core (rslib). The repository doesn't carry Anki's source; this script clones
# the release tag from https://github.com/ankitects/anki (with the translation submodules rslib needs) and
# applies patches/anki-26.09.3-kanki.patch (two small changes, see the patch). Safe to re-run.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="26.09.3"
DEST="$ROOT/vendor/anki"
PATCH="$ROOT/patches/anki-$TAG-kanki.patch"

if [[ -d "$DEST/.git" ]]; then
    have="$(git -C "$DEST" describe --tags 2>/dev/null || true)"
    if [[ "$have" == "$TAG" ]] && git -C "$DEST" apply --reverse --check "$PATCH" 2>/dev/null; then
        echo "vendor/anki is already Anki $TAG with the kanki patch."
        exit 0
    fi
    echo "vendor/anki exists but isn't Anki $TAG + patch; move it away and run again." >&2
    exit 1
fi

mkdir -p "$ROOT/vendor"
echo "Cloning Anki $TAG ..."
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" https://github.com/ankitects/anki "$DEST"
echo "Fetching the translation submodules ..."
git -C "$DEST" submodule update --quiet --init --depth 1 ftl/core-repo ftl/qt-repo
echo "Applying $(basename "$PATCH") ..."
git -C "$DEST" apply "$PATCH"
echo "Done: vendor/anki = Anki $TAG + kanki patch."
