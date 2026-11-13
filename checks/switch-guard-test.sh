# scripts/switch-guard on made-up systems: refused inside the hours when a
# live-path unit changes, appears or goes; allowed otherwise.
#   bash switch-guard-test.sh SCRIPT
set -euo pipefail
guard="$1"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mk() { # SYSTEM KIND NAME CONTENT
  local d
  case "$2" in
    systemd) d="$work/$1/etc/systemd/system"; mkdir -p "$d"; printf '%s' "$4" > "$d/tinytrader-$3.service" ;;
    launchd) d="$work/$1/Library/LaunchDaemons"; mkdir -p "$d"; printf '%s' "$4" > "$d/com.tinytrader.$3.plist" ;;
  esac
}
run() { # KIND NOW NEW [ACTION]
  SWITCH_GUARD_KIND="$1" SWITCH_GUARD_NOW="$2" SWITCH_GUARD_CURRENT="$work/old-$1" \
    SWITCH_GUARD_SERVICES="relay-* order-gateway-* store" SWITCH_GUARD_OVERRIDE="$work/ok" \
    bash "$guard" "$work/$3" "${4:-switch}" 2> "$work/log"
}
refuses() { if run "$@"; then echo "FAIL: allowed: $*" >&2; exit 1; fi; }
allows() { if ! run "$@"; then echo "FAIL: refused: $*" >&2; cat "$work/log" >&2; exit 1; fi; }

for kind in systemd launchd; do
  mk "old-$kind" "$kind" relay-opra-spy a
  mk "old-$kind" "$kind" store a
  mk "old-$kind" "$kind" console a
  # A changed relay; a changed console only; an added gateway; a removed store.
  mk "relay-$kind" "$kind" relay-opra-spy b; mk "relay-$kind" "$kind" store a
  mk "console-$kind" "$kind" relay-opra-spy a; mk "console-$kind" "$kind" store a; mk "console-$kind" "$kind" console b
  mk "added-$kind" "$kind" relay-opra-spy a; mk "added-$kind" "$kind" store a; mk "added-$kind" "$kind" order-gateway-live a
  mk "removed-$kind" "$kind" relay-opra-spy a

  refuses "$kind" "3 1000" "relay-$kind"
  grep -q "relay-opra-spy" "$work/log" || { echo "FAIL: $kind: the refusal doesn't name the relay" >&2; exit 1; }
  refuses "$kind" "1 0925" "added-$kind"
  refuses "$kind" "5 1619" "removed-$kind"
  allows "$kind" "3 1000" "console-$kind"   # not live-path
  allows "$kind" "3 0924" "relay-$kind"     # before the hours
  allows "$kind" "3 1620" "relay-$kind"     # after
  allows "$kind" "6 1000" "relay-$kind"     # Saturday
  allows "$kind" "3 1000" "relay-$kind" boot
  touch "$work/ok"
  allows "$kind" "3 1000" "relay-$kind"     # the override, fresh
  touch -t 202001010000 "$work/ok"
  refuses "$kind" "3 1000" "relay-$kind"    # stale
  rm "$work/ok"
done
echo "switch-guard: ok"
