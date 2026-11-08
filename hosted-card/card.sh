#!/bin/bash
# card.sh TAG IMPL DESKPORT -- the Zero card's software, hosted: its desktop (card-desk.lisp) on
# 127.0.0.1:DESKPORT and its gateway (card-gateway.lisp) in front of it, the gateway under IMPL
# (sbcl | path to a modus binary).  When the gateway is ready it DMs OWNER a one-time login link;
# this waits for that, prints the PIDs, and leaves both running.  Secrets go into the gateway's
# environment from their files and are never printed.
#
# Required:
#   OWNER        npub the box admits and DMs (its allowlist)
#   MODUS_ROOT   source tree, one directory per system (glass, glass-webrtc, cl-nostr ...)
#   CARD_CONFIG  a shell file setting TURN_ICE="turn:HOST:PORT USER PASS" (keep it mode 600)
# Optional:
#   CARD_DIR     logs and stores (default ./card-run)
#   DESK_IMPL    sbcl (default) or a modus binary for the desktop
#   CARD_DESK    lean: glass's lean desk instead of the window manager
#   LOGIN_URL_BASE, NOSTR_RELAYS, PAYLOAD_FILE, QUICKLISP_SOFTWARE
#   CARD_LOGIN_TTL, CARD_ONE_THREAD, CARD_TRACE, CARD_ADMDIAG, CARD_TS, CARD_SYMDUMP -- see
#   card-gateway.lisp
# Stop: kill the two PIDs it prints (also in $CARD_DIR/TAG.pids).
set -u
TAG=${1:?usage: card.sh TAG IMPL DESKPORT}; IMPL=${2:?IMPL}; DPORT=${3:?DESKPORT}
HERE=$(cd "$(dirname "$0")" && pwd)
: "${OWNER:?set OWNER to the npub to admit}" "${MODUS_ROOT:?set MODUS_ROOT}" "${CARD_CONFIG:?set CARD_CONFIG}"
CARD_DIR=${CARD_DIR:-$PWD/card-run}; mkdir -p "$CARD_DIR"
ss -ltn | grep -q ":$DPORT\b" && { echo "desk port $DPORT busy"; exit 1; }
ss -ltn | grep -q ":$((DPORT+1))\b" && { echo "admission port $((DPORT+1)) busy"; exit 1; }
run () { if [ "$1" = sbcl ]; then echo "sbcl --dynamic-space-size 4096 --script"; else echo "$1 --script"; fi; }
( export MODUS_ROOT MODUS_RFB_PORT=$DPORT CARD_DESK=${CARD_DESK:-}
  [ -n "${CARD_SYMDUMP:-}" ] && export CARD_SYMDUMP=$CARD_SYMDUMP.desk
  exec setsid $(run "${DESK_IMPL:-sbcl}") "$HERE/card-desk.lisp" ) > "$CARD_DIR/desk-$TAG.log" 2>&1 < /dev/null &
DESK_PID=$!
for i in $(seq 300); do grep -q 'serving on' "$CARD_DIR/desk-$TAG.log" 2>/dev/null && break; kill -0 $DESK_PID 2>/dev/null || break; sleep 1; done
grep -q 'serving on' "$CARD_DIR/desk-$TAG.log" || { echo "desktop did not start (see $CARD_DIR/desk-$TAG.log)"; exit 1; }
STORE=$CARD_DIR/store-$TAG; rm -rf "$STORE"; mkdir -p "$STORE"; chmod 700 "$STORE"
T0=$(date +%s)
( set +x; source "$CARD_CONFIG"
  read -r srv user pass <<< "$TURN_ICE"
  export TURN_ICE TURN_SERVER=${srv#turn:} TURN_SERVER_URL=$srv TURN_USER=$user TURN_PASS=$pass
  # a fresh box identity per run
  export NOSTR_SEC=$(od -An -N32 -tx1 /dev/urandom | tr -d " \n") && export GLASS_NOSTR_SEC=$NOSTR_SEC
  export GLASS_NOSTR_ALLOW=$OWNER GLASS_HOST=127.0.0.1 GLASS_PORT=$DPORT
  export GLASS_ADMISSION_HOST=127.0.0.1 GLASS_ADMISSION_PORT=$((DPORT+1)) CARD_STORE=$STORE MODUS_ROOT
  export NOSTR_RELAYS=${NOSTR_RELAYS:-wss://nos.lol,wss://relay.primal.net}
  export PAYLOAD_CHANNEL=1 PAYLOAD_FILE=${PAYLOAD_FILE:-$HERE/../payload.js}
  export GLASS_LOGIN_URL_BASE=${LOGIN_URL_BASE:-https://npub1ajvjnhgcmdxkng22lzsh22qvl63es78gk6p9mwksepju974teguq4l4evc.nsite.lol/}
  [ "$IMPL" = sbcl ] || ulimit -c unlimited
  exec setsid $(run "$IMPL") "$HERE/card-gateway.lisp" ) > "$CARD_DIR/gw-$TAG.log" 2>&1 < /dev/null &
GW_PID=$!
echo "$GW_PID $DESK_PID" > "$CARD_DIR/$TAG.pids"
for i in $(seq 450); do grep -aq "ready: answering" "$CARD_DIR/gw-$TAG.log" && break; kill -0 $GW_PID 2>/dev/null || break; sleep 2; done
grep -aq "ready: answering" "$CARD_DIR/gw-$TAG.log" || { echo "gateway not ready after $(( $(date +%s)-T0 )) s (see $CARD_DIR/gw-$TAG.log)"; exit 1; }
echo "gateway ready after $(( $(date +%s)-T0 )) s"
for i in $(seq 60); do grep -aq "link: DM'd" "$CARD_DIR/gw-$TAG.log" && break; sleep 2; done
grep -a "link: DM'd" "$CARD_DIR/gw-$TAG.log" | head -1
echo "pids: gateway $GW_PID desktop $DESK_PID"
