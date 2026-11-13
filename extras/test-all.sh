#!/bin/sh
# Everything the plugin can check without a running shell or a live MPD.
#
# Used as the gate for refactors: each step moves code, runs this, and stays
# green before the next step starts.
set -eu

cd "$(dirname "$0")/.."

./lint.sh
echo "lint ok"

for test in extras/test-paths.js extras/test-names.js extras/test-palette.js \
        extras/test-palette-sync.js extras/test-lyrics.js \
        extras/test-layout.js extras/test-tag-frames.js; do
    node "$test"
done

./extras/test-qml.sh
