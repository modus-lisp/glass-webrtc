# hosted-card

The Zero card's software, run on an ordinary machine: its desktop and its gateway, the same Lisp
files under SBCL and hosted modus. `card-gateway.lisp` mirrors kiln's `boot/zero-gateway.lisp`
START with a real environment in place of the board's table; `card-desk.lisp` serves glass's
window manager (or, with `CARD_DESK=lean`, glass's lean desk) on loopback RFB.

    OWNER=npub1... MODUS_ROOT=/path/to/tree CARD_CONFIG=/path/to/config \
      hosted-card/card.sh phone sbcl 6290

- `TAG` names the run's logs and stores under `$CARD_DIR` (default `./card-run`).
- `IMPL` is the gateway's Lisp: `sbcl`, or the path to a modus binary.
- `DESK_IMPL` does the same for the desktop. It defaults to `sbcl`.
- The desktop listens on `DESKPORT`, and admission listens on `DESKPORT+1`.

The box gets a fresh identity each run. When it is ready, it DMs `OWNER` a one-time login link.
Open the link on the phone. Reply `link` to the DM for a fresh one. `card.sh` prints the two PIDs
and leaves both processes running; stop them by those PIDs (also in `$CARD_DIR/TAG.pids`).

`CARD_CONFIG` is a shell file that sets `TURN_ICE="turn:HOST:PORT USER PASS"`. Keep it mode 600.
The script reads it inside a subshell and never prints it.

Optional settings and diagnostics are listed at the top of `card.sh` and `card-gateway.lisp`. Two
useful ones:

- `CARD_LOGIN_TTL` makes a link last longer than glass's 10 minutes.
- `CARD_ADMDIAG=1` logs what an admission request carried (its shape only, never a code) and why
  it was refused.
