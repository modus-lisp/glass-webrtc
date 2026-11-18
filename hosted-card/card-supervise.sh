#!/bin/bash
# card-supervise.sh CARD_DIR TAG IMPL DESKPORT -- start the card if it is not running.  For cron:
#
#   */3 * * * * /path/to/hosted-card/card-supervise.sh /mnt/lisp/kiln-desktop/card-run wmnv sbcl 6340
#
# A card started by hand stays up only until the machine reboots or the process dies, and nothing
# says so: a phone just gets no answer.  (One was down for two days after a reboot.)  This brings it
# back within a cron period.  Its settings come from CARD_DIR/TAG.env, as for any card.sh start --
# that is what makes an unattended start possible.
#
# UP means: CARD_DIR/TAG.pids names a live card-gateway process AND the desk port is listening.
# Anything else is a start, logged to CARD_DIR/supervise-TAG.log with card.sh's own output.
# A card stopped on purpose stays stopped while CARD_DIR/TAG.nosupervise exists.
# One supervisor at a time (flock), so a slow start is never doubled by the next tick.
set -u
dir=${1:?usage: card-supervise.sh CARD_DIR TAG IMPL DESKPORT}; tag=${2:?TAG}; impl=${3:?IMPL}
port=${4:?DESKPORT}
here=$(cd "$(dirname "$0")" && pwd)
export PATH=/usr/local/bin:/usr/bin:/bin       # cron's PATH has no sbcl
log=$dir/supervise-$tag.log

[ -e "$dir/$tag.nosupervise" ] && exit 0
[ -f "$dir/$tag.env" ] || { echo "$(date -Is) no $dir/$tag.env -- cannot start $tag" >> "$log"; exit 1; }
exec 9> "$dir/$tag.supervise.lock"
flock -n 9 || exit 0

up() {
  local pid
  pid=$(cut -d' ' -f1 "$dir/$tag.pids" 2>/dev/null) || return 1
  [ -n "$pid" ] && tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline" | grep -q card-gateway &&
    ss -ltn | grep -q "127.0.0.1:$port\b"
}
up && exit 0

echo "$(date -Is) $tag is not running -- starting it" >> "$log"
cd "$here" && env -i HOME="$HOME" PATH="$PATH" CARD_DIR="$dir" ./card.sh "$tag" "$impl" "$port" >> "$log" 2>&1
echo "$(date -Is) card.sh exited $?" >> "$log"
