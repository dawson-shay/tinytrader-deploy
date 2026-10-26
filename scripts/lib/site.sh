# shellcheck shell=bash
# The two checkouts a script acts on. Sourced by the scripts:
#
#   . "$(dirname "$0")/lib/site.sh"
#
#   stack   this checkout (tinytrader-deploy): the scripts, the generic Nix
#   site    the site: the deployment's own repository, with its inventory.nix,
#           deploy/local/compose.yaml, secrets/ and state/ (docs/site.md).
#           The first of:
#             TINYTRADER_SITE           set by hand, by deploy_root_exec (the
#                                       deploy checkouts, decision 0012), or
#                                       by the launchd jobs
#             the current directory's   when it has an inventory.nix (run from
#             repository                inside the site: ../tinytrader-deploy/scripts/deploy)
#             a sibling of this         the one directory beside this checkout
#             checkout                  with an inventory.nix and a flake.nix
#
# Nothing here assumes a host, a user or a path: a machine with more than one
# site beside the stack names the one it means with TINYTRADER_SITE.
stack="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

site_find() {
  local top d found=()
  if [ -n "${TINYTRADER_SITE:-}" ]; then
    [ -f "$TINYTRADER_SITE/inventory.nix" ] || {
      echo "TINYTRADER_SITE=$TINYTRADER_SITE has no inventory.nix: it isn't a site (docs/site.md)" >&2
      return 1
    }
    (cd "$TINYTRADER_SITE" && pwd)
    return 0
  fi
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$top" ] && [ -f "$top/inventory.nix" ] && [ "$(cd "$top" && pwd -P)" != "$(cd "$stack" && pwd -P)" ]; then
    echo "$top"
    return 0
  fi
  for d in "$stack"/../*/; do
    d="${d%/}"
    [ -f "$d/inventory.nix" ] && [ -f "$d/flake.nix" ] || continue
    [ "$(cd "$d" && pwd -P)" = "$(cd "$stack" && pwd -P)" ] && continue
    found+=("$(cd "$d" && pwd)")
  done
  case "${#found[@]}" in
    1) echo "${found[0]}" ;;
    0)
      echo "no site found: set TINYTRADER_SITE to your deployment's repository (one with inventory.nix; docs/site.md)" >&2
      return 1
      ;;
    *)
      echo "several sites beside $stack (${found[*]}): set TINYTRADER_SITE to the one you mean" >&2
      return 1
      ;;
  esac
}

site="$(site_find)" || exit 1
export TINYTRADER_SITE="$site" TINYTRADER_DEPLOY="$stack"

# The deployment's name (inventory.nix deployment.name): its Compose project,
# and its state directory's name (~/.local/state/<name>).
site_name() {
  nix eval --raw --file "$site/inventory.nix" --apply 'i: i.deployment.name or "tinytrader"'
}

# stack_eval FILE [NIX EVAL ARGS...]: this stack's FILE (deploy/local/endpoints.nix,
# deploy/local/topology.nix, tailscale/policy.nix) applied to the site: its
# inventory.nix and, where it has one, its deploy/local/topology.json.
#   stack_eval deploy/local/endpoints.nix --json --apply 'e: e.aclPorts'
stack_eval() {
  local file="$1"
  shift
  TT_EVAL_FILE="$stack/$file" TT_EVAL_SITE="$site" nix eval --impure "$@" --expr '
    let
      site = builtins.getEnv "TT_EVAL_SITE";
      overlay = site + "/deploy/local/topology.json";
    in
    import (builtins.getEnv "TT_EVAL_FILE") {
      inventory = site + "/inventory.nix";
      overlay = if builtins.pathExists overlay then overlay else null;
    }'
}
