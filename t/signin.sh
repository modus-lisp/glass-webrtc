#!/bin/bash
# t/signin.sh — build the real client into /tmp, then drive it in a real headless Chromium.
#
# Same shape as warp's t/browser.sh and t/panel.sh: everything it makes and everything it writes is
# under /tmp, it binds only free ports, and THE GATEWAY IS NEVER LOADED, STARTED OR CONTACTED —
# loading gateway-nostr.lisp would subscribe to three relays as the box's own identity and race the
# session somebody is using.  The gateway's half of this change is asserted from its TEXT, in
# admission-test.lisp.
#
# The build goes to a /tmp dir with node_modules symlinked out of the real one, so a test run never
# touches the artefacts a publish would ship.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/.." && pwd)"
out="${GLASS_SIGNIN_OUT:-/tmp/glass-signin-out}"
build="${GLASS_SIGNIN_BUILD:-/tmp/glass-signin-build}"
real="${NSITE_BUILD:-/home/claude/nsite-build}"
mkdir -p "$out" "$build"

[ -d "$real/node_modules/nostr-tools" ] || {
  echo "no nostr-tools in $real/node_modules — see DEPLOY.md, \"Where the build dir is\""; exit 1; }
ln -sfn "$real/node_modules" "$build/node_modules"
[ -d "$real/novnc" ] && ln -sfn "$real/novnc" "$build/novnc"

SHUTTLE="${SHUTTLE:-$(command -v shuttle || true)}"
[ -n "$SHUTTLE" ] || for c in "$real"/../shuttle/bin/shuttle /home/claude/shuttle/bin/shuttle; do
  [ -x "$c" ] && SHUTTLE="$c" && break
done
[ -n "$SHUTTLE" ] || { echo "no shuttle found (expected a sibling ../shuttle checkout)"; exit 1; }

echo "== building the client (the same tools/mksplit.lisp a publish runs) =="
NSITE_BUILD="$build" sbcl --script "$src/tools/mksplit.lisp" "$build"

# THE BOX AND THE SIGNER, bundled by shuttle rather than esbuild.  Both were plain IIFEs
# (--bundle --format=iife --minify), which is shuttle's default output, and the signer additionally
# wanted --global-name: signer-shim.js is a CLASSIC script, so NSIGNER has to be on the window
# before the shell's deferred module looks for it.  That is now --global-name here too.
# BUNDLED IN PLACE, not from the build directory.  Both entries import `nostr-tools/pure`, and a
# bare specifier resolves by walking UP from the entry looking for vendor/ or node_modules/ -- which
# finds this repo's vendor/ from t/, and finds nothing at all from a temp build directory.  esbuild
# happened to resolve it from wherever it was run; shuttle says where it looked, which is how this
# surfaced at all.
echo "== bundling the box and the signer =="
"$SHUTTLE" bundle "$here/box.entry.mjs" -o "$build/box.js" >/dev/null
"$SHUTTLE" bundle "$here/signer.entry.mjs" --global-name NSIGNER -o "$build/signer.js" >/dev/null

GLASS_SIGNIN_OUT="$out" python3 "$here/signin.py" "$build"
