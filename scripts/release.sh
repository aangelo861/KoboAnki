#!/usr/bin/env bash
#
# release.sh VERSION - build the user-facing zip from dist/kanki.koplugin (run scripts/package.sh first):
#
#   dist/KoboAnki-vVERSION.zip
#     KoboAnki-vVERSION/kanki.koplugin/     the plugin with bin/kanki
#     KoboAnki-vVERSION/NickelMenu/kanki    NickelMenu entry
#     KoboAnki-vVERSION/install-macos.sh    one-command install on a Mac
#     KoboAnki-vVERSION/INSTALL.txt, LICENSE, LICENSE-AGPL-3.0.txt
#
# Refuses to package a binary that embeds the builder's home directory (see build-kobo.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?usage: release.sh VERSION (e.g. 0.1.0)}"
SRC="$ROOT/dist/kanki.koplugin"
NAME="KoboAnki-v$VERSION"
OUT="$ROOT/dist/$NAME"

[[ -f "$SRC/bin/kanki" ]] || { echo "dist/kanki.koplugin/bin/kanki missing: run scripts/package.sh" >&2; exit 1; }
if strings -n 8 "$SRC/bin/kanki" | grep -q "$HOME"; then
    echo "bin/kanki contains paths under $HOME: rebuild with scripts/build-kobo.sh (path remapping)" >&2
    exit 1
fi

rm -rf "$OUT" "$OUT.zip"
mkdir -p "$OUT/NickelMenu"
COPYFILE_DISABLE=1 cp -R "$SRC" "$OUT/kanki.koplugin"
tr -d '\r' < "$ROOT/koplugin/kanki.koplugin/nickelmenu-entry.txt" > "$OUT/NickelMenu/kanki"
cp "$ROOT/scripts/release/install-macos.sh" "$ROOT/scripts/release/INSTALL.txt" "$OUT/"
cp "$ROOT/LICENSE" "$ROOT/LICENSE-AGPL-3.0.txt" "$OUT/"
chmod +x "$OUT/install-macos.sh" "$OUT/kanki.koplugin/bin/kanki"
find "$OUT" \( -name '._*' -o -name '.DS_Store' \) -delete
(cd "$ROOT/dist" && COPYFILE_DISABLE=1 zip -q -r -X "$NAME.zip" "$NAME")
echo "$ROOT/dist/$NAME.zip ($(du -h "$ROOT/dist/$NAME.zip" | cut -f1))"
(cd "$ROOT/dist" && shasum -a 256 "$NAME.zip")
