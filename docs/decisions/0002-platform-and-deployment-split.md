# 0002: Split the platform from the deployment

- **Status:** Accepted; the stack's own repository added by
  [0015](0015-stack-and-site.md)
- **Date:** 2026-10-05

## Context

One repository holding everything (services, infrastructure, strategies,
research and one operation's inventory) has a cost: every host name, product
and display preference ends up in code that should be shareable, so sharing
any of it later means a rewrite. And the way a deployment is run (its
placement map, its role modules, its deploy scripts) is shareable too, but
only once it is kept apart from the hosts, users and secrets of the one
deployment it was written for.

## Decision

Three repositories, in the pattern of nixpkgs, a set of shared modules and a
NixOS configuration:

- **tinytrader**: the platform. Libraries, services, the console, NixOS and
  nix-darwin service modules, formats, examples. Generic by rule (its
  CONTRIBUTING.md), with a flake check that fails on common leaks.
- **tinytrader-deploy** (this repository): the stack, an opinionated way to
  deploy tinytrader on a few machines. The placement map's checks, the role
  modules (`roles/darwin.nix`, `modules/`), the scripts (`scripts/deploy`,
  `scripts/local-up.sh`, `scripts/auto-deploy`, ...), the generators of
  addresses, the console's topology and the tailnet policy, the research
  image, and these docs. Generic by rule too: it assumes no host, user,
  path, tailnet or account, and its `checks.<system>.generic` fails on
  deployment-specific patterns.
- **The site**: one deployment's own repository, private. Its
  `inventory.nix` (hosts, placement, tailnet, data roots, secrets
  recipients, and the `deployment` settings), its
  `deploy/local/compose.yaml` and `topology.json`, queue templates,
  `secrets/` (sops), `state/` (the console's), and whatever else is its own:
  strategies, research, private docs and decisions about the operation. Its
  `flake.nix` calls `tinytrader-deploy.lib.mkDeployment`.

The site takes tinytrader and tinytrader-deploy as flake inputs;
tinytrader-deploy takes tinytrader. Neither tinytrader nor tinytrader-deploy
ever references a site. The machines themselves stay rooted in a separate
machines repository (nix-darwin, NixOS, home-manager), which imports the
site's `darwinModules.<host>` and `nixosModules.<host>`.

## What goes where

| Work | Where |
|---|---|
| A service, a library, a format, a console panel kind | tinytrader |
| How services are placed, checked, addressed, deployed, monitored and backed up | tinytrader-deploy |
| Which hosts exist and what runs on each, the Compose file, secrets, panels, strategies, research | the site |
| Users, shells, Tailscale, the Docker engine, the machine's own settings | the machines repository |

Wire-format identifiers are never renamed across the split.

## Keeping the boundary

The table above is the rule; tinytrader's CONTRIBUTING.md states it for the
platform. tinytrader's and this stack's flake checks
(`checks.<system>.generic`) backstop it; a site keeps its own specifics and
needs no such check.
