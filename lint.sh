#!/bin/sh
# Lint the plugin's QML with the shell's modules on the import path.
#
# qmllint does not know Quickshell's `qs` module root, so a bare run cannot
# resolve `import qs.Commons` and reports every `Color.*`, `Style.*` and
# `Util.*` token as an unknown member. The shell keeps those modules under
# `$OMARCHY_PATH/shell`, laid out as the `qs/Commons` directory this script
# exposes in a temporary import root.
set -eu

cd "$(dirname "$0")"

shell_root="${OMARCHY_PATH:-/usr/share/omarchy}/shell"
if [ ! -d "$shell_root/Commons" ]; then
    echo "lint: cannot find the shell's Commons module under $shell_root" >&2
    echo "lint: set OMARCHY_PATH to the Omarchy install prefix" >&2
    exit 1
fi

# /usr/bin/qmllint is Qt 5 on this system; the Qt 6 binary is the one that
# understands the QML this plugin is written in.
qmllint_bin=""
for candidate in /usr/lib/qt6/bin/qmllint qmllint; do
    if command -v "$candidate" >/dev/null 2>&1; then
        qmllint_bin="$candidate"
        break
    fi
done
if [ -z "$qmllint_bin" ]; then
    echo "lint: qmllint not found" >&2
    exit 1
fi

imports="$(mktemp -d)"
trap 'rm -rf "$imports"' EXIT INT TERM

mkdir -p "$imports/qs"
ln -s "$shell_root/Commons" "$imports/qs/Commons"

"$qmllint_bin" -I "$imports" ./*.qml
