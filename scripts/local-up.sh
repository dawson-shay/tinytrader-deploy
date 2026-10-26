#!/usr/bin/env bash
# Start the site's local services from a tinytrader checkout, with the
# keys decrypted only into this command's environment: the containers placed
# on this machine (the site's inventory.nix services, docs/decisions/0005), in
# Compose's default profile. Containers placed elsewhere are left as they are.
# On a machine with deploy checkouts (docs/decisions/0012) it always
# starts them from those: run from a working copy, it runs theirs instead.
#   TINYTRADER_SITE  the site (scripts/lib/site.sh; with deploy checkouts, theirs only)
#   TINYTRADER_SRC   path to a tinytrader checkout (default: ../tinytrader beside
#                    this repo; with deploy checkouts, theirs only)
#   TINYTRADER_HOST  this machine's inventory host, if its name doesn't say
set -euo pipefail
# Nix's tools, whatever shell this runs from (a `!` shell has no login PATH).
export PATH="/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
# shellcheck source=lib/deploy-root.sh
. "$(dirname "$0")/lib/deploy-root.sh"
deploy_root_exec "$0" "$@"
# shellcheck source=lib/site.sh
. "$(dirname "$0")/lib/site.sh"
src="${TINYTRADER_SRC:-$stack/../tinytrader}"
project="$(site_name)"
test -x "$src/nix/build-images.sh" || { echo "tinytrader checkout not found at $src (set TINYTRADER_SRC)" >&2; exit 1; }
test -d "$site/secrets" || { echo "no secrets/ in $site; see the site's secrets/README.md" >&2; exit 1; }
export TINYTRADER_SRC="$(cd "$src" && pwd)"
# The console's reminders and curated views, bind-mounted writable from the
# site (state/console, decision 0009): Docker would make an empty folder
# in its place, and the console would start with no reminders.
test -f "$site/state/console/reminders.json" || { echo "no state/console/reminders.json in $site (state/console/README.md)" >&2; exit 1; }
# The containers placed here, before anything is decrypted.
here="$("$stack/scripts/placement" services compose)"
# The console's topology, with the placement map (deploy/local/topology.nix).
export TINYTRADER_TOPOLOGY="${XDG_STATE_HOME:-$HOME/.local/state}/$project/topology.json"
"$stack/scripts/placement" topology "$TINYTRADER_TOPOLOGY"
# Where this host's containers reach each service (TT_ADDR_*, TT_URL_*), from
# the placement map (deploy/local/endpoints.nix, docs/decisions/0008).
eval "$("$stack/scripts/placement" endpoints)"
# Decrypt into this process's environment only; nothing is written to disk.
# Never the Databento key: no container holds it (docs/decisions/0013).
set -a
# The economic calendar's contact address for BLS (optional).
[ -e "$site/secrets/econ.env" ] && eval "$(sops decrypt "$site/secrets/econ.env")"
# The notebook server's token.
[ -e "$site/secrets/research.env" ] && eval "$(sops decrypt "$site/secrets/research.env")"
# The order gateway's client tokens.
[ -e "$site/secrets/gateway.env" ] && eval "$(sops decrypt "$site/secrets/gateway.env")"
# The console's push notices: the ntfy topic URL from notify.env, when it
# exists (secrets/README.md); without it the console sends none.
if [ -e "$site/secrets/notify.env" ]; then
  CONSOLE_NOTIFY="$(sops decrypt "$site/secrets/notify.env" | sed -n 's/^NTFY_URL=//p' | head -n1)" \
    || echo "secrets/notify.env: could not decrypt it; the console sends no notices" >&2
  export CONSOLE_NOTIFY
fi
# The console's trading token until the operator adds it (scripts/gateway-token
# GATEWAY_CONSOLE_TOKEN): empty, so the console starts with trading off.
export GATEWAY_CONSOLE_TOKEN="${GATEWAY_CONSOLE_TOKEN:-}"
# The store's write token (decision 0008), for the console (databento-jobs, native, has its own copy):
# empty until the operator makes secrets/store.env, and the store requires it
# only once its own role has it.
[ -e "$site/secrets/store.env" ] && eval "$(sops decrypt "$site/secrets/store.env")"
export STORE_WRITE_TOKEN="${STORE_WRITE_TOKEN:-}"
# The console's write gate (docs/operations.md): its order token and the
# Tailscale logins allowed to make changes. Without them the console starts
# with every write refused.
[ -e "$site/secrets/console.env" ] && eval "$(sops decrypt "$site/secrets/console.env")"
export CONSOLE_ORDER_TOKEN="${CONSOLE_ORDER_TOKEN:-}" CONSOLE_ORDER_LOGINS="${CONSOLE_ORDER_LOGINS:-}"
# The purchase approval token (tinytrader decision 0019), for the console.
export CONSOLE_JOBS_APPROVE_TOKEN="${CONSOLE_JOBS_APPROVE_TOKEN:-}"
# Each secrets/accounts/<name>.env holds one Alpaca account's keys; they
# become ACCOUNT_<NAME>_KEY_ID and ACCOUNT_<NAME>_SECRET_KEY for Compose.
for f in "$site"/secrets/accounts/*.env; do
  [ -e "$f" ] || continue
  n="$(basename "$f" .env | tr 'a-z-' 'A-Z_')"
  eval "$(sops decrypt "$f" | sed -nE "s/^APCA_API_(KEY_ID|SECRET_KEY)=/ACCOUNT_${n}_\1=/p")"
done
set +a
compose=(docker compose -f "$site/deploy/local/compose.yaml")
# This host's services in the default profile (config --services leaves out
# the rest, such as idle-relays; naming them to `up` would start them).
# shellcheck disable=SC2207
services=($("${compose[@]}" config --services | grep -Fx -f <(printf '%s\n' "$here") || true))
[ ${#services[@]} -gt 0 ] || { echo "no containers are placed on $("$stack/scripts/placement" host)"; exit 0; }
echo "== $("$stack/scripts/placement" host): ${services[*]}"
# Build the tinytrader images they use, with Nix.
# shellcheck disable=SC2046
"$src/nix/build-images.sh" $("${compose[@]}" config --format json | python3 -c '
import json, sys
c = json.load(sys.stdin)["services"]
print(" ".join(sorted({c[s]["image"].split("/")[1].split(":")[0] for s in sys.argv[1:] if c[s]["image"].startswith("tinytrader/")})))' "${services[@]}")
exec "${compose[@]}" up -d --build --remove-orphans "${services[@]}"
