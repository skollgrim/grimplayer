#!/usr/bin/env bash
# Open the folder behind a library row, selecting a file where the file manager
# can. Called by the player as:
#
#   open_folder.sh <directory> [<file-to-select>]
#
# The default file manager on Omarchy is Flea, which opens a folder and can put
# the cursor on a child with --select. Nautilus has --select too. Everything else
# gets FileManager1, the desktop-wide "show this file" service, and finally the
# directory is handed to xdg-open. The first that applies wins.
#
# A cue album's virtual track ("Album.cue/track0003") does not exist on disk;
# selecting the cue sheet is what puts the file manager on the real file.
set -u

dir=${1:-}
select=${2:-}
[ -n "$dir" ] || exit 2

case "$select" in
    *.cue/track[0-9]*)
        select="${select%%.cue/track*}.cue"
        ;;
esac

if [ -n "$select" ] && command -v flea >/dev/null 2>&1; then
    exec flea --gui --select "$select"
fi

if [ -n "$select" ] && command -v nautilus >/dev/null 2>&1; then
    exec nautilus --select "$select"
fi

if [ -n "$select" ] && command -v gdbus >/dev/null 2>&1; then
    # FileManager1 takes file URIs, so the path is escaped rather than pasted.
    # A failed call (no service, or one that refuses) falls through to opening
    # the folder without a selection.
    uri=$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).as_uri())' "$select" 2>/dev/null)
    if [ -n "$uri" ] && gdbus call --session \
            --dest org.freedesktop.FileManager1 \
            --object-path /org/freedesktop/FileManager1 \
            --method org.freedesktop.FileManager1.ShowItems \
            "['$uri']" "" >/dev/null 2>&1; then
        exit 0
    fi
fi

exec xdg-open "$dir"
