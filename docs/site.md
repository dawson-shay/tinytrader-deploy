# A site

A site is one deployment of tinytrader: a private repository that holds what
is that deployment's own, and nothing else. This stack is generic; the site
makes it concrete. [example/](../example/) is a complete one, made up.

| Path | What | Read by |
|---|---|---|
| `flake.nix` | Calls `tinytrader-deploy.lib.mkDeployment`, pinning tinytrader and this stack in `flake.lock` | Your machines repository, which imports its roles |
| `inventory.nix` | Hosts, placement, tailnet, data roots, secrets recipients, monitoring, backup, and `deployment` (below) | Every module, script and check |
| `deploy/local/compose.yaml` | The containers, one file for every host | scripts/deploy, local-up.sh, the checks, the backup |
| `deploy/local/topology.json` | The console's panels, bundles, edges and links (optional) | deploy/local/topology.nix |
| `deploy/local/queue-templates.yaml` | The job queue's templates (if it runs the queue) | the queue container |
| `deploy/nomad/jobs/` | The batch jobs, as Nomad job specs (if it runs the scheduler) | scripts/job, auto-deploy |
| `secrets/`, `.sops.yaml` | sops-encrypted files; `.sops.yaml` is written by scripts/secrets-recipients | scripts, the native services' wrappers, sops-nix |
| `state/console/` | The console's reminders, journal and curated views, kept in git (decision 0009) | the console, auto-deploy |
| `tailscale/policy.hujson` | The tailnet policy, written by scripts/tailscale-policy and checked current | you, pasting it into the admin console |
| `research/`, `pyproject.toml`, `uv.lock`, `.python-version` | Notebooks, and the research image's Python environment (a `notebook` group) | the research container |
| `strategies/`, `docs/`, anything else | Yours | |

## The inventory

The schema is the example's [inventory.nix](../example/inventory.nix), with
a comment on every field. In brief:

- `hosts.<host>`: `system`, `os` (`darwin`, `nixos`), `runtime`
  (`docker-compose` where containers run), `tailnetName`, `status`
  (`planned` hosts are checked but not drawn or served), `watch.disks`.
- `services.<name>`: the placement map (decision 0005): `host` and `runtime`
  (`compose`, `launchd`, `systemd`), or `perHost` for a host agent; `ports`,
  `uses`, `localOnly`, `https`, `usesHttps`, `viaHost`, `dataRoots`,
  `colocateWith`, `secrets`, `profile`. Services find each other from it
  (decision 0008).
- `secrets`: the operator and recovery keys, each host's key, the
  `operatorKeyHosts`, the `hostOnly` files and who decrypts each file
  (decision 0004).
- `dataRoots`, `tailnet` (`domain`, `tag`), `monitoring`, `backup`.
- `deployment`: what the stack needs beyond the placement map (not part of
  the console's topology):
  - `name`: the Compose project (compose.yaml's `name` must match), the
    state directory (`~/.local/state/<name>`), and the site's deploy
    checkout (`<deployRoot>/<name>`).
  - `captureHours`: when the relays capture, New York time; background
    work yields to them.
  - `autoDeploy.never`: services scripts/auto-deploy leaves to you
    (default: `order-gateway-*`, `relay-*`).
  - `hosts.<host>.dockerSocket`: the Docker engine's socket, relative to the
    primary user's home or absolute (default Colima's).
  - `native.<service>`: the native services' settings: `store` (`volumes`
    as `{ name; root; }` data roots in order, `discover`, `args`),
    `alpaca-history` (`keys`, `yieldTo`), each `relay-*` (`symbols`,
    `enable`), `queue-host-runner` (`enable`, `path`), `runner` (`url`,
    `name`, `attr`).
  - `hosts.<host>.siteCheckout`: the site checkout batch jobs mount on a
    host without deploy checkouts (relative to the primary user's home, or
    absolute; a NixOS host's default is `/srv/<name>`).
  - `privateWords`: words of this deployment that must never appear in
    the stack (user names, machine names, account names), checked with its
    tailnet domain and `name` by the site's `checks.stack-generic`.
  - `nomad`: the batch scheduler's policy (`server`, `datacenter`,
    `nodes.<host>` with `pool`, `memoryMB`, `cpuMHz`, `feed`, `builds`,
    `cleanRoots` (where the disk-hygiene job deletes idle Rust targets), and
    `yieldTo`), where the inventory places `nomad` on hosts
    ([docs/batch-jobs.md](batch-jobs.md)). Its job specs are the site's
    `deploy/nomad/jobs/`.

## Machines

Your machines' configurations (a machines repository) own the machines:
users, shells, Tailscale, the Docker engine, sops-nix. Each imports its
role from the site:

```nix
darwinConfigurations.desk = nix-darwin.lib.darwinSystem {
  modules = [
    sops-nix.darwinModules.sops   # the Databento key's holders need it
    ./desk.nix
    my-site.darwinModules.desk
    { tinytrader-deploy.autoDeploy.enable = true; tinytrader-deploy.backup.receive = true; }
  ];
};
```

A role follows the placement map: the monitor where `watch` runs, the CI
runner where `runner` runs, the backup where `backup` runs, the store and
the Databento key's holders where they are placed natively
([roles/darwin.nix](../roles/darwin.nix)). Options: `tinytrader-deploy.deployRoot`,
`.checkouts.{site,stack,tinytrader}`, `.autoDeploy.{enable,interval}`,
`.backup.{enable,receive}`, and on NixOS `.nas.{enable,volumes,historyTopoff}`.

## Checkouts

The scripts run from a checkout of this stack and act on a site found as
`TINYTRADER_SITE`, else the repository of the current directory when it has
an `inventory.nix`, else the one sibling of the stack checkout with an
`inventory.nix` and a `flake.nix` ([scripts/lib/site.sh](../scripts/lib/site.sh)).
They build tinytrader's images from `TINYTRADER_SRC` (default
`../tinytrader`). On a services host the deploy checkouts are
`<deployRoot>/<deployment name>`, `<deployRoot>/tinytrader-deploy` and
`<deployRoot>/tinytrader` (decision 0012), and every script that deploys
runs from them.

## Updating the stack

A change to the stack is a pull request here. The site takes it in two
ways: its Nix (the roles) when its `flake.lock` takes the new revision
(`nix flake update tinytrader-deploy`), then the machines repository's
lock and a switch; its scripts when auto-deploy fast-forwards the stack's
deploy checkout to main.
