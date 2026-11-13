#!/bin/sh
# Run the QML-level tests for the palette cache, the theme's delegation to it
# and the cover race guard.
#
# The real Quickshell types are C++ plugins that only load inside the running
# shell, so the test imports stand-ins from extras/qmltest/stubs: an in-memory
# FileView, a Process that exits at once, and the few qs.Commons tokens
# GrimTheme reads. Everything under test -- GrimPaletteStore.qml, GrimTheme.qml
# and PaletteSync.js -- is the real file.
set -eu

cd "$(dirname "$0")/.."

# /usr/bin/qmltestrunner is Qt 5 on this system; only the Qt 6 one can load the
# QML this plugin is written in. Same reasoning as lint.sh's qmllint lookup.
runner=""
for candidate in /usr/lib/qt6/bin/qmltestrunner qmltestrunner; do
    if command -v "$candidate" >/dev/null 2>&1; then
        runner="$candidate"
        break
    fi
done
if [ -z "$runner" ]; then
    echo "test-qml: qmltestrunner not found" >&2
    exit 1
fi

# offscreen: the suite never shows a window, and a test run should not need a
# display (or steal focus from one).
QT_QPA_PLATFORM=offscreen "$runner" -import extras/qmltest/stubs -input extras/qmltest "$@"
