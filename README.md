# tinytrader-deploy

An opinionated deployment stack for [tinytrader](https://github.com/dawson-shay/tinytrader):
Nix role modules for macOS (nix-darwin) and NixOS, the scripts that deploy
and operate it, and the checks that keep it consistent. It makes no
assumptions about your hosts, users, paths, tailnet or accounts: all of that
comes from your **site**, a small private repository with your inventory,
compose file, encrypted secrets and state ([docs/site.md](docs/site.md)).

```
tinytrader          the platform: services, the console, libraries (public)
tinytrader-deploy   this stack: how a deployment runs them (public, generic)
your site           one deployment: hosts, placement, secrets, state (private)
```

The opinions: services listen on loopback and are forwarded across hosts
with `tailscale serve`; what runs where is one placement map in the
inventory, and `nix flake check` fails when the map, the compose file, the
roles, the data roots and the secrets disagree; secrets are sops files,
decrypted only into the environment of what needs them; no builds or deploys
during US market hours (09:25-16:20 New York); the live order gateway never
runs on two hosts. The reasons are in [docs/decisions/](docs/decisions/).

## Start a site

```sh
nix flake new -t github:dawson-shay/tinytrader-deploy my-site
cd my-site   # edit inventory.nix and deploy/local/compose.yaml; keep it private
nix flake check
```

Its `flake.nix` is one call:

```nix
outputs = { tinytrader-deploy, ... }:
  tinytrader-deploy.lib.mkDeployment {
    inventory = ./inventory.nix;
    secrets = ./secrets;
    compose = ./deploy/local/compose.yaml;
    topology = ./deploy/local/topology.json;  # optional
    state = ./state;                          # optional
    policy = ./tailscale/policy.hujson;       # optional
  };
```

`mkDeployment` returns `darwinModules.<host>` and `nixosModules.<host>`, one
role per host something is placed on, for your machines' own configurations
to import; packages (the console's topology, every host's service
addresses, the backup, the tailnet policy); and the checks. See
[example/](example/) for a complete, made-up site.

## Deploy

Check out tinytrader and this repository beside your site; the scripts find
the site as their sibling (or `TINYTRADER_SITE`):

```sh
scripts/placement services   # what this machine runs
scripts/deploy console       # rebuild one service, recreate it, check it came back
scripts/local-up.sh          # every container placed on this machine
scripts/tailnet-serve        # what this machine forwards from the tailnet (--apply)
```

Day-to-day operation, backups, incidents and recovery:
[docs/operations.md](docs/operations.md).

## Repository map

| Path | Holds |
|---|---|
| `lib/default.nix` | `lib.mkDeployment` |
| `roles/darwin.nix` | A Mac's role, assembled from the placement map |
| `modules/` | The pieces: the monitor and node_exporter, the backup, auto-deploy and the deploy checkouts, the Databento key's holders, the store, the CI runner, the batch scheduler (Nomad), a NAS's role |
| `deploy/nomad/` | The batch scheduler's per-host settings from the site's policy (`node.nix`), the jobs' gate, the default access policy |
| `deploy/local/` | `endpoints.nix` (every service's address from every host), `topology.nix` (the console's graph), `research/` (the notebook image) |
| `tailscale/policy.nix` | The tailnet policy, from the inventory |
| `checks/` | The placement, data-root and backup checks, and `generic.nix` (nothing deployment-specific here) |
| `scripts/` | deploy, local-up/down, auto-deploy, placement, tailnet-serve, job and nomad-bootstrap (batch jobs), backup and restore, secrets and Tailscale tools (tailscale-join, tailnet-lock) |
| `example/` | An example site, also the flake template |
| `docs/` | [site](docs/site.md), [operations](docs/operations.md), [architecture](docs/architecture.md), [monitoring](docs/monitoring.md), [CI](docs/ci.md), [batch jobs](docs/batch-jobs.md), [decisions](docs/decisions/) |

Contributions: [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT: [LICENSE](LICENSE).
