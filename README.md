# tinytrader-deploy

How to run the full [tinytrader](https://github.com/dawson-shay/tinytrader)
stack: on [one machine](#one-machine) with Docker Compose, or on
[a network](#a-network) of machines with Nomad. Both come with examples that
run as they are.

```
tinytrader          the platform: services, the console, libraries (public)
tinytrader-deploy   this repository: how a deployment runs them (public, generic)
your site           one deployment: hosts, placement, secrets, state (private)
```

## One machine

[quickstart/](quickstart/) runs a toy collector streaming live Coinbase
prices and the tinytrader console. It needs only Docker with Compose: the
images are published prebuilt, so there is nothing to install or build.

```sh
cd quickstart && docker compose up -d     # port 8080 taken? CONSOLE_PORT=8081 docker compose up -d
```

Then open <http://localhost:8080> (or the port you chose).
`curl -s http://localhost:8080/api/state` shows the same state from the
command line. `docker compose down -v` removes
it and its recorded data. To build the images from a tinytrader checkout
instead, see [its README](quickstart/README.md#images).

## A network

Several machines run one deployment as a site (below): its inventory says
which machine runs what, and the machines reach each other over a tailnet.

1. **List the machines in your site's `inventory.nix`:** each host under
   `hosts`, `nomad` placed on the hosts that run batch work, and the
   scheduler's policy under `deployment.nomad` (the server, each node's pool
   and budget). The [example inventory](example/inventory.nix) has every
   field.
2. **Switch each machine** to its configuration, which imports its role
   from the inventory. The first switch starts `tailscaled`, which the next
   step needs.
3. **Join each machine to the tailnet:** `scripts/tailscale-join TARGET`
   (an ssh destination, before Tailscale its LAN address).
4. **Start the scheduler:** `scripts/tailnet-serve --apply` on each machine,
   then `scripts/nomad-bootstrap` on the server's host (ACLs, the token into
   the site's secrets, the jobs).
5. **Run batch jobs:** `scripts/job run research-collector script=collect_x.py`,
   `scripts/job list`, `scripts/job logs RUN`. The jobs are the site's
   `deploy/nomad/jobs/` ([example](example/deploy/nomad/jobs/)).

Nomad runs batch work today. The long-lived services (relays, the store, the
console and the rest) still run from the site's Compose file and native
services on the hosts the inventory places them on; moving them onto Nomad
service jobs is planned. Setting the scheduler up in full:
[docs/batch-jobs.md](docs/batch-jobs.md#nomad-decision-0014).

## Your own site

The stack is an opinionated deployment: Nix role modules for macOS
(nix-darwin) and NixOS, the scripts that deploy and operate it, and the
checks that keep it consistent. It makes no assumptions about your hosts,
users, paths, tailnet or accounts: all of that comes from your **site**, a
small private repository with your inventory, compose file, encrypted
secrets and state ([docs/site.md](docs/site.md)). Nix is this more advanced
path; the one-machine quick start needs none.

The opinions: services listen on loopback and are forwarded across hosts
with `tailscale serve`; what runs where is one placement map in the
inventory, and `nix flake check` fails when the map, the compose file, the
roles, the data roots and the secrets disagree; secrets are sops files,
decrypted only into the environment of what needs them; no builds or deploys
during US market hours (09:25-16:20 New York); the live order gateway never
runs on two hosts. The reasons are in [docs/decisions/](docs/decisions/).

### Start a site

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

### Deploy

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
| `quickstart/` | One machine with Docker Compose: a toy collector and the console |
| `example/` | An example site, also the flake template |
| `docs/` | [site](docs/site.md), [operations](docs/operations.md), [architecture](docs/architecture.md), [monitoring](docs/monitoring.md), [CI](docs/ci.md), [batch jobs](docs/batch-jobs.md), [decisions](docs/decisions/) |

Contributions: [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT: [LICENSE](LICENSE).
