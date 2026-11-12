#!/bin/bash
# t/linkcond.sh -- the card over conditioned links (t/linkcond.py): build the client the way a
# publish does, then run a real card (gateway + glass, one process) through a local shaped TURN.
#
#   t/linkcond.sh [IMPL...]        IMPL: sbcl (default) and/or a hosted modus binary
#
#   MODUS_ROOT / QUICKLISP_SOFTWARE   where the card's systems come from (see t/linkcond.py)
#   LINKCOND_BUILD=DIR                use an already-built client instead of building one
#   LINKCOND_ONLY=lan,rtt100,...      a subset of the link conditions
#   LINKCOND_RELAYS=wss://a,wss://b   signal over these public relays (sign-in time: `answer')
# Needs what t/signin.sh needs (nsite-build's node_modules, shuttle, playwright's Chromium), plus
# python3's aioice (the TURN messages) and PIL (the screenshots).  Writes only under /tmp.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/.." && pwd)"
build="${LINKCOND_BUILD:-}"
if [ -z "$build" ]; then
  build=/tmp/glass-linkcond-build
  real="${NSITE_BUILD:-/home/claude/nsite-build}"
  mkdir -p "$build"
  [ -d "$real/node_modules/nostr-tools" ] || {
    echo "no nostr-tools in $real/node_modules — see DEPLOY.md, \"Where the build dir is\""; exit 1; }
  ln -sfn "$real/node_modules" "$build/node_modules"
  [ -d "$real/novnc" ] && ln -sfn "$real/novnc" "$build/novnc"
  SHUTTLE="${SHUTTLE:-$(command -v shuttle || true)}"
  [ -n "$SHUTTLE" ] || for c in "$src"/../shuttle/bin/shuttle /home/claude/shuttle/bin/shuttle; do
    [ -x "$c" ] && SHUTTLE="$c" && break
  done
  [ -n "$SHUTTLE" ] || { echo "no shuttle found (expected a sibling ../shuttle checkout)"; exit 1; }
  echo "== building the client (tools/mksplit.lisp) =="
  NSITE_BUILD="$build" sbcl --script "$src/tools/mksplit.lisp" "$build"
  "$SHUTTLE" bundle "$here/signer.entry.mjs" --global-name NSIGNER -o "$build/signer.js" >/dev/null
fi
rc=0
for impl in "${@:-sbcl}"; do
  LINKCOND_OUT="/tmp/glass-linkcond-$(basename "$impl")" python3 "$here/linkcond.py" "$build" "$impl" || rc=1
done
exit $rc
