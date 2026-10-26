# 0015: A public stack, a private site

- **Status:** Accepted
- **Date:** 2026-10-25
- **Amends:** [0002](0002-platform-and-deployment-split.md) (the stack gets
  a repository of its own)

## Context

The stack (how tinytrader is placed, checked, addressed, deployed,
monitored and backed up) was written inside one private deployment
repository, beside that deployment's hosts, users and secrets. It was
generic in intent but not in fact: its modules named hosts, its scripts
assumed paths, and its history held personal details. Publishing it from
that repository would publish the history too, so the stack starts as a new
repository with fresh history, and the deployment keeps its own.

## Decision

**The stack is generic and takes everything from a site.** tinytrader-deploy
holds the modules (`modules/`), the roles (`roles/darwin.nix`, and the NixOS
role in `modules/nas.nix`), the scripts (`scripts/`), the checks
(`checks/`), the generators of addresses, the console's topology and the
tailnet policy (`deploy/local/endpoints.nix`, `deploy/local/topology.nix`,
`tailscale/policy.nix`), the research image (`deploy/local/research/`) and
the docs. A site, one deployment's private repository, holds:

- `inventory.nix`: hosts, placement, the tailnet, data roots, secrets
  recipients, and the `deployment` settings (`name`, `captureHours`,
  `autoDeploy.never`, `hosts.<host>.dockerSocket`, `native.<service>`);
- `deploy/local/compose.yaml`, `deploy/local/topology.json` and the queue
  templates;
- `secrets/` (sops) and `.sops.yaml`, `state/` (the console's), and the
  generated `tailscale/policy.hujson`.

**The site's flake calls `lib.mkDeployment`** with those files and gets back
`darwinModules.<host>`, `nixosModules.<host>`, `packages` (the topology,
the endpoints, backup-state, restore-state, tailscale-policy), `checks`,
`devShells` and the evaluated `inventory`. **The machines repository** (nix-darwin, NixOS) imports the
site's `darwinModules.<host>` and `nixosModules.<host>`; it owns the machine,
the site says what runs on it.

**Scripts find the site** (`scripts/lib/site.sh`): `TINYTRADER_SITE` if set,
else the current directory's repository if it has an `inventory.nix`, else
the one sibling of the stack checkout with an `inventory.nix` and a
`flake.nix`. They export `TINYTRADER_SITE` and `TINYTRADER_DEPLOY` (the
stack) for the site's compose.yaml.

**Deploy checkouts gain the stack** ([0012](0012-deploy-checkouts.md)):
`<deployRoot>/<site>`, `<deployRoot>/tinytrader-deploy` and
`<deployRoot>/tinytrader`, all three fast-forwarded by auto-deploy
([0011](0011-auto-deploy-from-main.md)).

**`checks.generic` guards the stack** (`checks/generic.nix`): it fails on
home directories, named drives, tailnet names and addresses, private
network addresses, and key material anywhere in this repository. Examples
are made up.

## Consequences

- A site pins the stack in its `flake.lock` for its Nix (the roles and
  modules a machine applies), while the scripts run from the stack
  checkout's main, as tinytrader's checkout is used for the images. A
  site's machines can run a role from an older stack than its scripts until
  the lock is updated.
- Changing the stack is a PR here, then an update of the site's lock.
- The option names moved to `tinytrader-deploy.*` (`deployRoot`,
  `checkouts.{site,stack,tinytrader}`, `autoDeploy.*`, `backup.*`, `nas.*`);
  a site may keep aliases from its older names while its machines catch up.
- The decision numbers keep their gaps: 0001 and 0003 were about the first
  deployment alone and stayed with it. Numbers and titles are stable, since
  code comments cite them.
