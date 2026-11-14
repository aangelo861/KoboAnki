#!/bin/sh
# Start KOReader straight into the Anki deck list. Used by the NickelMenu "Anki" entry
# (see nickelmenu-entry.txt next to this file).
#
# * KANKI_AUTOSTART=1 is read by kanki.koplugin/main.lua. koreader.sh re-execs itself from /tmp with
#   `exec`, which keeps the environment, and runs reader.lua as a child, so the variable reaches
#   KOReader (and stays set across KOReader's own restarts inside koreader.sh's loop).
# * The directory argument is passed through to reader.lua by koreader.sh ("$@"): with a directory,
#   KOReader opens its file manager there instead of re-opening the last book, so no document is
#   loaded behind the deck list. Nickel is stopped by koreader.sh and restarted when KOReader exits.

KOREADER_DIR="/mnt/onboard/.adds/koreader"
START_DIR="/mnt/onboard"

export KANKI_AUTOSTART=1
exec "${KOREADER_DIR}/koreader.sh" "${START_DIR}"
