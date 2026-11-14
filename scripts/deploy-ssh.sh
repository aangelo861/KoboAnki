#!/usr/bin/env bash
#
# deploy-ssh.sh - install dist/kanki.koplugin on the Kobo over KOReader's built-in SSH server.
#
# KOReader's SSH plugin (plugins/SSH.koplugin) runs its patched dropbear as
#     ./dropbear -E -R -p <port> -P /tmp/dropbear_koreader.pid [-s | -n]
# The user is root. The port is 2222 unless changed in KOReader's SSH menu (G_reader_settings
# "SSH_port"). Public keys are read from
#     /mnt/onboard/.adds/koreader/settings/SSH/authorized_keys
# and our key (.dev/kobo_ed25519.pub) must be in that file. With "Login with key only" (-s),
# password login is disabled.
#
# Usage:
#   scripts/deploy-ssh.sh HOST [PORT]                  (run scripts/package.sh first)
#   scripts/deploy-ssh.sh --stop-server HOST [PORT]    first ask a running kanki to shut down
#                                                       (POST /shutdown) so that the new binary
#                                                       is the one started next time
# Environment:
#   KOBO_SSH_PORT   default port when PORT is not given (default 2222)
#   KOBO_SSH_KEY    private key (default .dev/kobo_ed25519)
#
# How it copies: there is no rsync on the Kobo, and scp/sftp onto FAT32 can fail when it tries to
# set file modes. So the plugin is streamed as a tar archive and unpacked with KOReader's bundled
# GNU tar (the same tool and flags KOReader's own OTA updater uses on this FAT32 partition) into
# a staging folder, which then replaces the old plugin folder.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
SRC="$DIST/kanki.koplugin"

die() { echo "deploy-ssh.sh: $*" >&2; exit 1; }

STOP_SERVER=0
if [[ "${1:-}" == "--stop-server" ]]; then STOP_SERVER=1; shift; fi
HOST="${1:-}"
[[ -n "$HOST" ]] || die "usage: $0 [--stop-server] HOST [PORT]"
PORT="${2:-${KOBO_SSH_PORT:-2222}}"
KEY="${KOBO_SSH_KEY:-$ROOT/.dev/kobo_ed25519}"

[[ -f "$KEY" ]] || die "SSH key not found: $KEY"
[[ -f "$SRC/bin/kanki" ]] || die "$SRC/bin/kanki missing (run scripts/package.sh first)"
desc="$(file -b "$SRC/bin/kanki")"
[[ "$desc" == *"ELF 32-bit LSB"*"ARM"* ]] || die "$SRC/bin/kanki is not an ARM binary: $desc"

# Use only our key. Keep the device's host key in a separate known_hosts file under .dev/:
# reinstalling KOReader regenerates it, and it shouldn't end up in ~/.ssh/known_hosts.
# accept-new trusts the key on first connect and rejects it if it later changes.
SSH=(ssh -p "$PORT" -i "$KEY"
     -o IdentitiesOnly=yes
     -o UserKnownHostsFile="$ROOT/.dev/known_hosts"
     -o StrictHostKeyChecking=accept-new
     -o ConnectTimeout=10
     -o ServerAliveInterval=5 -o ServerAliveCountMax=3
     "root@$HOST")

echo "Checking the device at $HOST:$PORT ..."
"${SSH[@]}" 'test -d /mnt/onboard/.adds/koreader/plugins && echo "  $(uname -m), Linux $(uname -r)"' \
    || die "cannot reach KOReader over SSH (is the SSH server on in KOReader, Wi-Fi up, key installed?)"

if (( STOP_SERVER )); then
    # Clean shutdown closes the collection. Busybox wget may not support POST on every firmware,
    # so fall back to SIGTERM. Nothing happens if kanki isn't running.
    "${SSH[@]}" '
        wget -q -O /dev/null --post-data="" http://127.0.0.1:47321/shutdown 2>/dev/null \
            || { pid="$(pidof kanki)"; [ -n "$pid" ] && kill -TERM $pid; }
        sleep 1; true'
    echo "  asked any running kanki server to shut down"
fi

# --- Plugin: tar stream -> staging folder -> swap ----------------------------------------------
# macOS bsdtar: no ._* AppleDouble entries (COPYFILE_DISABLE, --no-mac-metadata) and no xattr/ACL
# pax headers (GNU tar would warn about them). ustar is plenty for these short paths. Entries
# are stored as root-owned, so the plain-tar fallback doesn't create files owned by our Mac uid.
echo "Uploading plugin ..."
COPYFILE_DISABLE=1 tar -C "$DIST" -c -f - \
    --format ustar --no-mac-metadata --no-xattrs --no-acls --no-fflags \
    --uid 0 --gid 0 --uname root --gname root \
    --exclude '._*' --exclude '.DS_Store' \
    kanki.koplugin \
| "${SSH[@]}" '
    set -e
    KO=/mnt/onboard/.adds/koreader
    P="$KO/plugins"
    # Prefer KOReader GNU tar (--no-same-owner/--no-same-permissions avoid chown/chmod on FAT32).
    if [ -x "$KO/tar" ]; then TAR="$KO/tar --no-same-owner --no-same-permissions"; else TAR=tar; fi
    # Unpack into a staging folder whose name does not end in ".koplugin", so KOReader never
    # loads a half-copied plugin. Then swap it in with renames on the same filesystem.
    S="$P/.kanki-deploy"
    rm -rf "$S"
    mkdir "$S"
    $TAR -x -f - -C "$S"
    test -f "$S/kanki.koplugin/bin/kanki"
    if [ -d "$P/kanki.koplugin" ]; then mv "$P/kanki.koplugin" "$S/old"; fi
    mv "$S/kanki.koplugin" "$P/kanki.koplugin"
    # A running kanki keeps its (now unlinked) binary open, so deleting the old copy is fine.
    rm -rf "$S"
    sync
    ls -l "$P/kanki.koplugin/bin/kanki" | sed "s/^/  /"'
echo "  -> /mnt/onboard/.adds/koreader/plugins/kanki.koplugin"

# --- NickelMenu entry ---------------------------------------------------------------------------
NM_ENTRY=""
for f in "$SRC/nickelmenu-entry.txt" "$ROOT/koplugin/kanki.koplugin/nickelmenu-entry.txt"; do
    if [[ -f "$f" ]]; then NM_ENTRY="$f"; break; fi
done
if [[ -n "$NM_ENTRY" ]]; then
    # NickelMenu wants LF line endings.
    tr -d '\r' < "$NM_ENTRY" \
        | "${SSH[@]}" 'mkdir -p /mnt/onboard/.adds/nm && cat > /mnt/onboard/.adds/nm/kanki && sync'
    echo "  -> /mnt/onboard/.adds/nm/kanki"
else
    echo "  NickelMenu entry skipped (no nickelmenu-entry.txt in the plugin)"
fi

echo "Done. Restart KOReader (Exit -> Restart KOReader) to load the new plugin code."
