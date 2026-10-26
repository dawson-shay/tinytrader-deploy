# shellcheck shell=bash
# The deploy checkouts (docs/decisions/0012): on a services host, the
# containers and the native jobs run from plain clones of origin/main that
# only scripts/auto-deploy changes, never from a working copy. Sourced by
# scripts/deploy, scripts/local-up.sh and scripts/auto-deploy:
#
#   . "$(dirname "$0")/lib/deploy-root.sh"
#   deploy_root_exec "$0" "$@"
#
#   TINYTRADER_DEPLOY_ROOT   where they are (default ~/.local/share/tinytrader/deploy;
#                            nix-darwin's tinytrader-deploy.deployRoot sets it):
#     <root>/tinytrader-deploy   this stack
#     <root>/tinytrader          the platform
#     <root>/<site>              the site: the one directory there with an
#                                inventory.nix (the role modules name it after
#                                the deployment, inventory.nix deployment.name);
#                                TINYTRADER_DEPLOY_SITE names it when there are several
#
# A machine without them (a laptop, CI, a host that runs nothing from a
# deploy checkout) runs from the checkout the script is in, as before, on
# the site scripts/lib/site.sh finds.
deploy_root="${TINYTRADER_DEPLOY_ROOT:-$HOME/.local/share/tinytrader/deploy}"
deploy_stack="$deploy_root/tinytrader-deploy"
deploy_src="$deploy_root/tinytrader"

# The site checkout in the deploy root, or nothing.
deploy_site() {
  local d found=()
  if [ -n "${TINYTRADER_DEPLOY_SITE:-}" ]; then
    echo "$TINYTRADER_DEPLOY_SITE"
    return 0
  fi
  [ -d "$deploy_root" ] || return 0
  for d in "$deploy_root"/*/; do
    d="${d%/}"
    [ -f "$d/inventory.nix" ] && [ -e "$d/.git" ] && found+=("$d")
  done
  case "${#found[@]}" in
    0) ;;
    1) echo "${found[0]}" ;;
    *)
      echo "several sites in $deploy_root (${found[*]}): set TINYTRADER_DEPLOY_SITE to the one this machine runs" >&2
      return 1
      ;;
  esac
}

# True when this machine has deploy checkouts.
deploy_root_present() {
  [ -n "$(deploy_site)" ]
}

# deploy_root_exec SCRIPT ARGS...: where there are deploy checkouts, SCRIPT
# always acts on them. Run from anywhere else (a working copy, a worktree),
# it says so and runs the deploy checkout's copy of itself instead, with the
# same arguments: what is deployed is what auto-deploy last fast-forwarded to,
# never this checkout's branch or uncommitted changes. A TINYTRADER_SRC or
# TINYTRADER_SITE naming another checkout is refused. Without deploy
# checkouts it does nothing.
deploy_root_exec() {
  local script="$1" name here root_stack given dsite
  shift
  dsite="$(deploy_site)" || exit 1
  [ -n "$dsite" ] || return 0
  name="scripts/$(basename "$script")"
  [ -e "$deploy_src/.git" ] || { echo "$name: $dsite exists but $deploy_src doesn't: clone tinytrader there (docs/decisions/0012)" >&2; exit 1; }
  [ -e "$deploy_stack/.git" ] || { echo "$name: $dsite exists but $deploy_stack doesn't: clone tinytrader-deploy there (docs/decisions/0012)" >&2; exit 1; }
  if [ -n "${TINYTRADER_SRC:-}" ]; then
    given="$(cd "$TINYTRADER_SRC" 2>/dev/null && pwd -P || echo "$TINYTRADER_SRC")"
    if [ "$given" != "$(cd "$deploy_src" && pwd -P)" ]; then
      echo "$name: this machine deploys tinytrader from $deploy_src only, not TINYTRADER_SRC=$TINYTRADER_SRC (unset it; to deploy a change, merge it to main)" >&2
      exit 1
    fi
  fi
  if [ -n "${TINYTRADER_SITE:-}" ]; then
    given="$(cd "$TINYTRADER_SITE" 2>/dev/null && pwd -P || echo "$TINYTRADER_SITE")"
    if [ "$given" != "$(cd "$dsite" && pwd -P)" ]; then
      echo "$name: this machine deploys its site from $dsite only, not TINYTRADER_SITE=$TINYTRADER_SITE (unset it; to deploy a change, merge it to main)" >&2
      exit 1
    fi
  fi
  here="$(cd "$(dirname "$script")/.." && pwd -P)"
  root_stack="$(cd "$deploy_stack" && pwd -P)"
  if [ "$here" != "$root_stack" ]; then
    echo "$name: running from the deploy checkouts in $deploy_root, not $here ($(basename "$dsite") $(git -C "$dsite" rev-parse --short HEAD), tinytrader-deploy $(git -C "$deploy_stack" rev-parse --short HEAD), tinytrader $(git -C "$deploy_src" rev-parse --short HEAD): what auto-deploy last fast-forwarded to)" >&2
    TINYTRADER_SRC="$deploy_src" TINYTRADER_SITE="$dsite" exec "$deploy_stack/$name" "$@"
  fi
  export TINYTRADER_SRC="$deploy_src" TINYTRADER_SITE="$dsite"
}
