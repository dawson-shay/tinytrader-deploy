# checks.<system>.backup-script: scripts/backup-state on made-up data, with
# no Docker engine: its volume list, the gateways' journal copy, and the
# retention. Run by `nix flake check`; $1 is compose.yaml.
set -euo pipefail
compose="$1"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home" BACKUP_DOCKER=0 BACKUP_MIN_FREE_GIB=0
export BACKUP_ROOT="$HOME/Backups/tinytrader" BACKUP_STATE="$HOME/state"
export BACKUP_GATEWAY_STATE="$HOME/gw" TINYTRADER_SRC="$HOME/repos/tinytrader" TINYTRADER_SITE="$HOME/repos/my-site"
export TINYTRADER_DEPLOY="$HOME/repos/tinytrader-deploy"
mkdir -p "$HOME" "$TINYTRADER_SRC/.git" "$TINYTRADER_SITE/.git" "$TINYTRADER_SITE/target" "$TINYTRADER_DEPLOY/.git"
echo x > "$TINYTRADER_SRC/README"; echo big > "$TINYTRADER_SITE/target/build-output"; echo y > "$TINYTRADER_DEPLOY/README"
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== the volume list is compose.yaml's"
want="$(yq -r '.volumes | keys | .[]' "$compose" | sort)"
got="$(backup-state --list-volumes | awk '{ print $1 }' | sort)"
[ "$want" = "$got" ] || fail "volumes: want [$want] got [$got]"
[ -n "$got" ] || fail "no volumes listed"

echo "== the gateways' journals: copied live, a torn line cut, the chain verified"
python3 - "$BACKUP_GATEWAY_STATE" <<'PY'
import hashlib, json, os, sys
root = sys.argv[1]
for acct, days in (("paper", ("2026-10-14", "2026-10-15")), ("live", ("2026-10-15",))):
    j = os.path.join(root, acct, "journal"); os.makedirs(j)
    open(os.path.join(root, acct, "lock"), "w").close()
    prev, seq = "0" * 64, 0
    for day in days:
        with open(os.path.join(j, day + ".jsonl"), "wb") as f:
            for k in range(3):
                seq += 1
                ev = json.dumps({"type": "event", "seq": seq, "ts_gateway": seq, "account": acct, "kind": "status"}, separators=(",", ":"))
                line = (ev[:-1] + ',"prev":"%s"}\n' % prev).encode()
                f.write(line); prev = hashlib.sha256(line).hexdigest()
    with open(os.path.join(j, days[-1] + ".jsonl"), "ab") as f:
        f.write(b'{"type":"event","seq":%d,"ts_gat' % (seq + 1))  # a line being written
PY
touch "$BACKUP_GATEWAY_STATE/live/KILL"
backup-state "$work/snap1"
s="$work/snap1"
jq -e '.gateways["paper"].last_seq == 6 and .gateways.live.last_seq == 3 and .gateways.live.torn_bytes_cut > 0' "$s/MANIFEST.json" >/dev/null \
  || fail "manifest: $(cat "$s/MANIFEST.json")"
[ -f "$s/order-gateway/live/KILL" ] || fail "the KILL sentinel wasn't kept"
[ ! -e "$s/order-gateway/live/lock" ] || fail "the lock file was copied"
[ "$(tail -c1 "$s/order-gateway/live/journal/2026-10-15.jsonl" | od -An -c | tr -d ' ')" = '\n' ] || fail "the torn line is still there"
[ "$(tail -c1 "$BACKUP_GATEWAY_STATE/live/journal/2026-10-15.jsonl" | od -An -c | tr -d ' ')" != '\n' ] || fail "the live journal was changed"
(cd "$s" && sha256sum --quiet -c SHA256SUMS) || fail "SHA256SUMS"
[ -f "$s/repos/tinytrader/README" ] && [ -f "$s/repos/tinytrader-deploy/README" ] && [ -d "$s/repos/my-site" ] && [ ! -e "$s/repos/my-site/target" ] || fail "repositories"
! find "$s" -iname '*key*' | grep -q . || fail "something named like a key is in the snapshot"
[ "$(stat -c %a "$s")" = 700 ] || fail "the snapshot isn't owner-only"

echo "== a broken chain fails the backup"
sed -i '2s/"seq":2/"seq":9/' "$BACKUP_GATEWAY_STATE/paper/journal/2026-10-14.jsonl"
if backup-state "$work/snap2" 2> "$work/log"; then fail "a broken chain passed"; fi
grep -q "hash chain mismatch\|seq 9 after 1" "$work/log" || { cat "$work/log" >&2; fail "no reason given"; }
[ ! -e "$work/snap2" ] || fail "an incomplete snapshot was kept"
rm -rf "$BACKUP_GATEWAY_STATE"

echo "== retention: 14 daily, 8 weekly, the newest always"
mkdir -p "$BACKUP_ROOT"
for i in $(seq 0 119); do
  d="$(date -u -d "2026-10-15 - $i days" +%Y-%m-%d)"
  mkdir "$BACKUP_ROOT/$d-0230"
  [ $((i % 5)) -ne 0 ] || mkdir "$BACKUP_ROOT/$d-1404" # a second one that day
done
mkdir "$BACKUP_ROOT/.partial-2026-10-16-0230"
backup-state --prune --dry-run 2> "$work/log"
[ "$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 | wc -l)" -gt 140 ] || fail "the dry run deleted something"
backup-state --prune
kept="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort -r)"
n="$(grep -c . <<<"$kept")"
# 14 days (2026-10-02..15, the 15th's 14:04 being its newest), and the newest
# of each of 8 ISO weeks (W35..W42), 3 of which those days already hold.
[ "$n" -eq 19 ] || fail "kept $n: $kept"
[ "$(head -n1 <<<"$kept")" = 2026-10-15-1404 ] || fail "the newest wasn't kept"
grep -qx 2026-10-15-0230 <<<"$kept" && fail "kept a second snapshot of one day"
grep -q partial <<<"$kept" && fail "kept an unfinished snapshot"
oldest="$(tail -n1 <<<"$kept")"
[ "$oldest" \> 2026-08-16 ] || fail "kept something older than 8 weeks: $oldest"

echo "== the off-host copy refuses plain text"
if BACKUP_OFFHOST=nobody@nowhere BACKUP_RECIPIENTS="" backup-state --offhost 2> "$work/log"; then fail "sent without recipients"; fi
grep -q "plain text" "$work/log" || fail "no reason given"
echo "backup-state: all checks passed"
