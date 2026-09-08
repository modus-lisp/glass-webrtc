#!/usr/bin/env bash
# vendor-js.sh — copy the browser client's JS dependencies into vendor/, so building it needs
# no npm.  Run once when a dependency changes; the result is committed.
#
#   tools/vendor-js.sh [node_modules-dir]
#
# WHAT IS COPIED, AND WHY THIS SHAPE.  Each package contributes its package.json (the `exports`
# map is what resolves `nostr-tools/pure`), its LICENSE, and its ESM tree only -- the CJS build at
# the package root is dead weight for a browser bundle.  The node_modules DIRECTORY LAYOUT is
# preserved exactly, nested copies included: @noble/curves ships its own @noble/hashes at a
# different version from the top-level one, BOTH are reached by the real graph, and flattening
# them would silently change which cryptography runs.
set -eu
SRC="${1:-$HOME/nsite-build/node_modules}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HERE/vendor"
[ -d "$SRC" ] || { echo "no such node_modules: $SRC" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST"

copy_pkg() {                       # copy_pkg <relative-package-path>
  local rel="$1" from="$SRC/$1" to="$DEST/$1"
  [ -d "$from" ] || { echo "missing package: $rel" >&2; return 1; }
  mkdir -p "$to"
  cp "$from/package.json" "$to/"
  for l in LICENSE LICENSE.md LICENCE COPYING; do
    [ -f "$from/$l" ] && cp "$from/$l" "$to/"
  done
  # the ESM tree, wherever the package keeps it
  for d in esm lib/esm; do
    if [ -d "$from/$d" ]; then
      mkdir -p "$to/$d"
      (cd "$from/$d" && find . -name '*.js' -print0) | while IFS= read -r -d '' f; do
        mkdir -p "$to/$d/$(dirname "$f")"
        cp "$from/$d/$f" "$to/$d/$f"
      done
    fi
  done
  printf '  %-46s %s\n' "$rel" "$(python3 -c "import json,sys;print(json.load(open('$from/package.json')).get('version','?'))")"
}

echo "vendoring into $DEST"
copy_pkg nostr-tools
copy_pkg @noble/curves
copy_pkg @noble/hashes
copy_pkg @noble/ciphers
copy_pkg @scure/base
# @noble/curves pins its own @noble/hashes; the graph reaches both
copy_pkg "@noble/curves/node_modules/@noble/hashes"

echo
echo "files: $(find "$DEST" -name '*.js' | wc -l)   size: $(du -sh "$DEST" | cut -f1)"
echo "licenses: $(find "$DEST" -name 'LICENSE*' | wc -l)"
