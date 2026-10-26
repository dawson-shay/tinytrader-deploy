#!/usr/bin/env bash
# Stop the site's local services (its Compose project, inventory.nix deployment.name).
set -euo pipefail
export PATH="/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:/run/current-system/sw/bin:$PATH"
# shellcheck source=lib/site.sh
. "$(dirname "$0")/lib/site.sh"
docker compose -p "$(site_name)" down
