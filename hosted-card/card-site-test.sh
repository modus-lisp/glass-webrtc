#!/bin/bash
# card-site-test.sh -- CARD_SITE end to end, with NO network and never the real site key:
#   a card started with CARD_SITE=1 mints links to the memo of its last publish (over the launcher's
#   LOGIN_URL_BASE), publish.lisp finds its control socket from CARD_DIR + CARD_TAG and has it publish
#   (to loopback fakes that verify every signature), the link base and the memo follow; a card
#   started WITHOUT CARD_SITE refuses; a card that is running but has no control socket makes
#   publish.lisp refuse rather than publish from its own process.
# The "card" is card-site-test-card.lisp: card-site.lisp + card-control.lisp, as card-gateway.lisp
# loads them, without the gateway.  Set CL_SOURCE_REGISTRY to test particular checkouts.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d /tmp/card-site-test.XXXXXX); chmod 700 "$T"
PASS=0; FAIL=0
ok () { if [ "$2" = 0 ]; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi; }
REAL_KEY=$HOME/.glass/site-key
REAL_MTIME=$(stat -c %Y "$REAL_KEY" 2>/dev/null || echo none)
unset GLASS_SITE_SEC SITE_SEC
# a throwaway site key, for the cards only
( umask 077; { echo "# throwaway, card-site-test"; od -An -N32 -tx1 /dev/urandom | tr -d " \n"; echo; } > "$T/site-key" )
echo '<!doctype html><title>card-site-test</title>' > "$T/page.html"
echo "https://memo.example/k6.html" > "$T/site-url"
PIDS=()
cleanup () { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT

start_card () {  # TAG CARD_SITE
  ( export CARD_ONE_PROCESS=1 CARD_CONTROL=1 CARD_CONTROL_PATH=$T/$1.control CARD_SITE=$2 \
           GLASS_SITE_KEY=$T/site-key GLASS_SITE_URL_FILE=$T/site-url \
           GLASS_LOGIN_URL_BASE=https://launcher.example/k1.html
    exec sbcl --dynamic-space-size 2048 --non-interactive --load "$HERE/card-site-test-card.lisp" ) \
      > "$T/$1.log" 2>&1 < /dev/null &
  local pid=$!; PIDS+=($pid); echo "$pid $pid" > "$T/$1.pids"
  for i in $(seq 120); do grep -q "fake-card: ready" "$T/$1.log" && return 0; kill -0 $pid 2>/dev/null || break; sleep 1; done
  echo "card $1 did not start:"; tail -20 "$T/$1.log"; return 1
}
# publish.lisp gets NO usable site key: if it ever fell back to publishing itself, it could not
publish () {  # TAG VERSION
  CARD_DIR=$T CARD_TAG=$1 SITE_VERSION=$2 GLASS_SITE_KEY=$T/no-such-key GLASS_SITE_URL_FILE=$T/pub-url \
    PUBLISH_TIMEOUT=60 sbcl --script "$HERE/../publish.lisp" "$T/page.html" 2>&1
}

echo "== a card with CARD_SITE=1 =="
start_card a 1 || exit 1
base=$("$HERE/card-eval" "$T/a.control" 'glass:*login-url-base*')
case "$base" in *memo.example/k6.html*) r=0;; *) r=1;; esac
ok "the memo of the last publish outranks the launcher's LOGIN_URL_BASE ($base)" $r
out=$(publish a k7); rc=$?
echo "$out" | sed 's/^/       | /'
ok "publish.lisp found the card's socket and the card published (exit $rc)" $rc
case "$out" in *"link base ->"*"/k7.html"*) r=0;; *) r=1;; esac
ok "  …and the report names the new link base" $r
base=$("$HERE/card-eval" "$T/a.control" 'glass:*login-url-base*')
case "$base" in *"/k7.html"*) r=0;; *) r=1;; esac
ok "  …which is now what the card mints links to ($base)" $r
grep -q "/k7.html" "$T/site-url"; ok "  …and what the memo says, for its next start" $?
v2=$("$HERE/card-eval" "$T/a.control" '(let ((m (find 15128 glass-site-fakes:*events* :key (function cl-nostr.event:event-kind)))) (and m (cl-nostr.event:verify-event m) (equal (cl-nostr.event:event-pubkey m) (glass:with-site-secret (kp) (cl-nostr.keys:public-hex kp)))))')
case "$v2" in T*) r=0;; *) r=1;; esac
ok "the fake relay holds a manifest that verifies, signed by the card's site key ($v2)" $r

echo "== a card WITHOUT CARD_SITE =="
start_card b 0 || exit 1
out=$(publish b k8); rc=$?
echo "$out" | sed 's/^/       | /'
[ $rc != 0 ]; ok "publish.lisp fails (exit $rc)" $?
case "$out" in *"not started with CARD_SITE=1"*) r=0;; *) r=1;; esac
ok "  …because the card refused, not for some other reason" $r
loaded=$("$HERE/card-eval" "$T/b.control" '(and (asdf:component-loaded-p "glass/site") t)')
case "$loaded" in NIL*) r=0;; *) r=1;; esac
ok "  …and the card did not load glass/site on demand" $r

echo "== a card that is running with no control socket =="
cp "$T/a.pids" "$T/c.pids"           # a live process, and no c.control
out=$(publish c k9); rc=$?
echo "$out" | sed 's/^/       | /'
[ $rc != 0 ]; ok "publish.lisp fails (exit $rc)" $?
case "$out" in *"running but nothing answers"*) r=0;; *) r=1;; esac
ok "  …refusing to publish from its own process while that card mints links" $r
base=$("$HERE/card-eval" "$T/a.control" 'glass:*login-url-base*')
case "$base" in *"/k7.html"*) r=0;; *) r=1;; esac
ok "card a still mints k7: nothing moved" $r

echo "== nothing of the real site =="
[ "$REAL_MTIME" = "$(stat -c %Y "$REAL_KEY" 2>/dev/null || echo none)" ]; ok "~/.glass/site-key untouched" $?
echo; echo "$PASS passed, $FAIL failed"
[ $FAIL = 0 ]
