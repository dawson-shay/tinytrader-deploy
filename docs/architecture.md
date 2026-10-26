# Architecture

> **Status: partly speculative.** The parts about the Macs (containers under
> Docker Compose, native services under launchd, the placement map, the
> tailnet, secrets, backups, monitoring, auto-deploy) describe what the stack
> does. The NixOS hosts, the archive, offsite backups and the research data
> routes are the intended shape; sections marked _Open_ are undecided. How
> to run it is in [operations.md](operations.md); what runs where is the
> site's `inventory.nix` `services` ([decision 0005](decisions/0005-placement-map.md)).

tinytrader-deploy is an opinionated way to run tinytrader on a few machines
you own: small-scale Nix GitOps, where a change to the fleet is a commit plus
a deploy, and a rollback is the previous generation. It makes no assumption
about your hosts, users, paths or tailnet: all of that is a *site*, a private
repository of your own that calls this stack's `lib.mkDeployment`.

The examples here use the made-up example site's hosts: `desk` (the Mac
that runs the services), `vault` (the Mac with the store's drives) and `nas`
(a planned NixOS machine).

## Principles

1. **Declarative, rollbackable.** Hosts are built from flakes. Nothing is
   started by hand in a way that a rebuild would not reproduce.
2. **Simple enough to hold in your head.** Prefer one more line of Nix over one
   more tool. Every moving part should be explainable from these docs.
3. **Apps don't know about hosts.** tinytrader produces packages and images;
   the site decides where they run, with what config, secrets and data roots,
   and this stack turns that decision into machine configuration.
4. **Services are placed, not pinned.** A service is a module that any host can
   enable. Moving it is a placement change plus a data handoff, not a rewrite.
5. **Data has one writer and a known lifecycle.** Every dataset has an owner,
   a hot location, an archive location, and a backup.
6. **Nothing is exposed publicly.** Hosts reach each other over Tailscale.

## Three repositories

| Repository | Public? | Holds |
|---|---|---|
| **tinytrader** | Public | The platform: services, libraries, `tinytrader.services.<name>` definitions (systemd units on Linux, launchd agents or daemons on macOS), the images |
| **tinytrader-deploy** (this one) | Public | The stack: `lib.mkDeployment`, the Mac role (`roles/darwin.nix`), `modules/`, the address and topology generators (`deploy/local/`), the tailnet policy generator, the checks and `scripts/` |
| **The site** | Private | `inventory.nix`, `deploy/local/compose.yaml`, `deploy/local/topology.json`, `deploy/local/queue-templates.yaml`, `secrets/` (sops), `state/console/`, the generated `tailscale/policy.hujson`, and your own research and strategies |

The site's `flake.nix` is short:

```nix
outputs = { tinytrader-deploy, ... }:
  tinytrader-deploy.lib.mkDeployment {
    inventory = ./inventory.nix;
    secrets = ./secrets;
    compose = ./deploy/local/compose.yaml;
    topology = ./deploy/local/topology.json;
    state = ./state;
    policy = ./tailscale/policy.hujson;
  };
```

It returns `darwinModules.<host>` for each Mac something is placed on,
`nixosModules.<host>` for each NixOS host, the checks, packages and dev
shells. Your **machines repository** (whatever configures your Macs:
nix-darwin, Home Manager) imports `<site>.darwinModules.<host>` for each Mac.
The scripts find the site by `TINYTRADER_SITE`, else the current repository
if it has an `inventory.nix`, else the one sibling of the stack's checkout
that has an `inventory.nix` and a `flake.nix` (`scripts/lib/site.sh`).

## Topology

```text
                         ┌──────────────────────────── tailnet ───────────────────────────┐
                         │                                                                │
  Exchanges, brokers,    │   ┌──────────── VPS (NixOS, 24/7, planned) ───────────┐        │
  data vendors           │   │ collectors, order gateway, live traders           │        │
  ─── market data ───────┼──▶│ hot root: committed, sealed units awaiting pickup │        │
  ◀── orders ────────────┼───│                                                   │        │
                         │   └───────────────────────┬───────────────────────────┘        │
                         │                           │ the NAS pulls (verify, release)    │
                         │   ┌──── home LAN ─────────▼───────────────────────────┐        │
                         │   │ nas (NixOS, planned): archive, backups, monitoring│        │
                         │   │        │ NFS (read-only)                          │        │
                         │   │        ▼                                          │        │
                         │   │ desk (macOS): relays, console, queue, gateways,   │        │
                         │   │               research and training               │        │
                         │   │ vault (macOS): the store, beside its drives       │        │
                         │   └───────────────────────────────────────────────────┘        │
                         │   Phone: alerts (ntfy), the console, SSH break-glass           │
                         └────────────────────────────────────────────────────────────────┘
```

A site can have one Mac or several, and add NixOS hosts as it grows. The
placement map, not the stack, decides which host does what.

## Hosts and runtimes

| Kind | Managed by | Runs services as |
|---|---|---|
| A Mac (`desk`, `vault`) | Your machines repository, importing the site's `darwinModules.<host>` (this stack's `roles/darwin.nix`) | Containers under Docker Compose (Colima or Docker Desktop), plus native launchd agents and daemons |
| A NixOS host (`nas`, a VPS) | The site's `nixosModules.<host>` (`modules/nas.nix`) | systemd units |
| Phone | n/a | Alerts, the console, SSH |

**Two runtimes, one service definition.** Each service is built once and
packaged two ways from tinytrader's flake:

- **NixOS hosts** run it as a systemd service through the
  `tinytrader.services.<name>` module: sandboxing, data-root grants, rollback.
- **Macs** run most services as Linux containers under **Docker Compose**,
  from images Nix builds (`dockerTools`). Compose's restart policy supervises
  them, and the container runtime starts on its own (Colima at boot, or
  Docker Desktop at login). Services stay Linux-only code; nothing
  macOS-specific is written.

**Native on a Mac** where a container can't do the job, from the same
`tinytrader.services` definitions, as launchd agents or boot-time daemons
(`roles/darwin.nix` picks them from the placement map, runtime `launchd`):

- the store and alpaca-history (`modules/store-darwin.nix`): the store must
  see its drives as they are attached, which a container can't;
- the monitor and node_exporter (`modules/watch-darwin.nix`): they must
  outlive the Docker engine they watch;
- the Databento key's holders, databento-jobs and the OPRA relays
  (`modules/databento-darwin.nix`), as a system user of their own, so the
  key never enters Compose ([decision 0013](decisions/0013-databento-key-held-by-its-services.md));
- the nightly backup, auto-deploy, the CI runner, and the queue's host
  runner, where placed.

One Compose file (the site's `deploy/local/compose.yaml`) serves every Mac;
the inventory decides which of its services each runs, and `nix flake check`
keeps the two in step, so the macOS and NixOS views of a service cannot drift
apart.

Notes on Macs:

- Docker on macOS is a Linux VM **without GPU access**, so containerised jobs
  get the CPU cores but not Metal / MLX / the Neural Engine. Run GPU-bound
  training natively; use Docker only for jobs that genuinely need Linux.
- Colima shares only the user's home directory with its VM by default, so
  bind mounts and deploy checkouts live under `$HOME`.
- Research reads timestamps recorded at capture time, so it does not depend
  on a Mac's clock. Clock discipline matters most where capture runs (chrony,
  and recording both exchange and receive timestamps). _Open:_ chrony on
  macOS in place of `timed`, as a nix-darwin daemon.

## The services

What the stack expects a site to run (the names are tinytrader's; the
site's compose.yaml and inventory configure them):

- **Relays** stream a provider's live market data to subscribers, each on its
  own `stream` port, with an `observe` port for health and stats. Each holds
  provider sessions, so a site sizes them against its plan's limits, and
  gives each its symbols and hours (`deployment.native.relay-*` for native
  ones).
- **The store** holds captured and purchased data on the site's drives and
  serves it to research ([decision 0007](decisions/0007-research-reads-through-the-store.md)).
  Its volumes and arguments are `deployment.native.store`.
- **The console** is the web UI: services' state, the hosts, the queue,
  reminders and views. Its topology (what it shows and links) is generated
  from the inventory plus the site's `deploy/local/topology.json`
  (`deploy/local/topology.nix`); its reminders, journal and curated views
  live in the site's `state/console/`, written by the console and committed
  ([decision 0009](decisions/0009-console-state-in-git.md)). It pushes its own
  notices to `CONSOLE_NOTIFY`, an ntfy topic URL.
- **The job queue** runs one-off batch work (research collectors, notebooks,
  builds) from the site's `deploy/local/queue-templates.yaml`, in containers
  through a Docker proxy, or on the Mac itself through the queue's host
  runner. See [batch-jobs.md](batch-jobs.md).
- **Order gateways** are the most sensitive services: own ports
  (`monitoring.gatewayPorts`), never forwarded to the tailnet, never
  deployed automatically, never probed by the monitor.

## The placement map

The site's `inventory.nix` `services` says, for each service, its host (or,
for a host agent like the monitor or node_exporter, `perHost`: each host and
its runtime), its runtime (`compose` or
`launchd`, systemd on NixOS), its ports by name, the services it uses, and
any real colocation constraint ([decision 0005](decisions/0005-placement-map.md)).
`scripts/placement` prints it; the checks (`checks/placement.nix`) refuse a
map that contradicts compose.yaml, places a gateway without a gateway port,
or grants a secret to a host that doesn't run its services.

```nix
# the site's inventory.nix (sketch)
services = {
  console    = { host = "desk";  runtime = "compose"; ports.http = 8080; };
  store      = { host = "vault"; runtime = "launchd"; ports.http = 9300; };
  relay-opra = { host = "desk";  runtime = "launchd";
                 ports = { stream = 9200; observe = 9110; }; };
  research   = { host = "desk";  runtime = "compose";
                 uses = [ "store" "console" "relay-opra:observe" ]; };
};
```

The inventory also has a `deployment` attribute for the stack: `name` (the
Compose project, the state directory, the deploy checkout's name),
`captureHours`, `autoDeploy.never`, `hosts.<host>.dockerSocket`, and
`native.<service>` settings for the role modules.

Moving a service means: change its host, hand over its data, deploy both
hosts. For capture services, overlap both briefly rather than leave a gap.

## Addresses

Nothing is configured with an address by hand: `deploy/local/endpoints.nix`
derives every one from the placement map ([decision 0008](decisions/0008-addresses-from-the-placement-map.md)).
For a client on a host:

| Client | Service on the same host | On another host |
|---|---|---|
| A container | `<name>:<port>`, or `host.docker.internal:<port>` for a native service | the other host's full MagicDNS name and the port |
| A native service | `127.0.0.1:<port>` | the same |
| A browser | `localhost:<port>` | the same |

compose.yaml reads them as `${TT_ADDR_<SERVICE>}` and `${TT_URL_<SERVICE>}`
(a port's name appended when a service has several, such as
`TT_URL_RELAY_OPRA_OBSERVE`); `scripts/deploy` and `scripts/local-up.sh`
export them before Compose runs, and `scripts/placement endpoints` prints
them.

## The tailnet

Every host joins one tailnet, tagged `tag:tinytrader`. Containers publish on
`127.0.0.1` only, and each host forwards every port of every service placed
on it with `tailscale serve --tcp` (`scripts/tailnet-serve --apply`), so
nothing binds the Tailscale address or `0.0.0.0` ([decision 0010](decisions/0010-all-service-ports-on-the-tailnet.md)).
The `localOnly` services are never forwarded: the order gateways, the
console's raw port (its write gate trusts Tailscale's identity headers,
which anything reaching the raw port could forge; browsers use its HTTPS
name) and the Docker proxies.

The policy is generated (`tailscale/policy.nix`, `scripts/tailscale-policy`)
into the site's `tailscale/policy.hujson`: tagged hosts reach each other on
the forwarded ports; your own untagged devices get the console's HTTPS and
SSH. `scripts/tailscale-join`, `tailscale-pin` and `tailscale-credential`
join a host, pin its name, and make the credentials.

## Secrets

Secrets are sops-encrypted files in the site's `secrets/`
([decision 0004](decisions/0004-secrets-across-machines.md)). Each file's
recipients come from the inventory: your operator age key and an offline
recovery key for every file, and a host's own key (its SSH host key, via
`ssh-to-age`) only for the files its services need. `scripts/secrets-recipients`
writes `.sops.yaml` and re-encrypts. A `hostOnly` file (the Databento key)
leaves the operator key out, so only its host's services can read it.

On a Mac, the role modules decrypt at start-up into the process's
environment (or sops-nix into `/run/secrets` for host-only files); on NixOS,
sops-nix into `/run/secrets`. Nothing decrypted is written to disk, and the
checks fail if a file under `secrets/` isn't encrypted.

## Data

Logical data roots are named in the inventory and mapped to a physical path
per host, so services and docs refer to `cex-hot` or `cex-archive`, never to a
drive's mount point or a ZFS dataset directly.

| Logical root | Host (example) | Writer | Contents |
|---|---|---|---|
| `cex-hot` | a VPS | collectors | Committed, sealed units awaiting pickup |
| `cex-archive` | `nas` | sync job | Archive of record, per venue |
| `databento` | `vault`, later `nas` | none (immutable) | Purchased data |
| `research` | `nas` | research jobs | Models, results, derived datasets |
| `cache` | `desk` (internal SSD) | research jobs | Disposable local copy of a working set |
| `scratch` | any | jobs | Disposable; never under an archive root |

Lifecycle of captured data (planned):

1. **Capture** into `cex-hot`. Until step 3 this is the *only* copy; sync
   frequency sets the maximum data at risk if that host dies.
2. **Pull** to the NAS over Tailscale on a timer; the capturing host holds no
   home credentials.
3. **Verify** length and hash at the destination, **then release** the hot
   copy. Interrupted transfers must be resumable.
4. **Archive** on the NAS (for example RAIDZ2, which survives two disk
   failures; keep it below ~80% full), with periodic ZFS snapshots.
5. **Back up.** RAID and snapshots protect against disk failure and mistakes,
   not against losing the NAS itself.

## Backups

**Now:** `scripts/backup-state` runs nightly where the placement map runs
`backup` (`modules/backup-darwin.nix`): the services' state volumes (the
console's settings, the queue's journal, the strategies' and gateways'
state), the gateways' journals, and the site's and stack's deploy checkouts,
kept 14 daily and 8 weekly, with an age-encrypted copy sent to another Mac
over the tailnet (`tinytrader-deploy.backup.receive` on the receiver). It
copies no key. `scripts/restore-state` restores; the monitor warns when the
newest backup, or its off-host copy, is older than `monitoring.backup`
allows. See [operations.md](operations.md).

**Planned tiers:**

| Tier | What | Protects against |
|---|---|---|
| ZFS snapshots | Everything on the pool | Accidental deletion or overwrite |
| Cold drives (manual) | Selected datasets | Pool loss, ransomware, bad upgrade |
| Offsite copy | Irrecoverable data only | Losing the house: fire, theft, flood, surge |

Irrecoverable capture earns all three; purchased data, recoverable by
repurchase, cold drives at most; research outputs and caches, snapshots only.
Encrypt offsite drives (ZFS native encryption or restic) and keep the key
somewhere other than the drives.

## Research and training

tinytrader owns capture, normalisation, storage and order handling; research
and strategies are the site's, consuming data and producing trained
artifacts. _Open: the language for models._

- **Strategies are clients of tinytrader's services.** They subscribe to live
  feeds through the relays and the console, and send orders through an order
  gateway. They never import collectors or the store, and never get write
  access to an archive.
- **Research reads through the store** by default
  ([decision 0007](decisions/0007-research-reads-through-the-store.md)).
  Bulk scans may use columnar copies (Arrow/Parquet) an ordinary subscriber
  writes to the research root: derived, disposable data.
- **Data is bought through databento-jobs**, the key's only holder; research
  and the queue's jobs never see the key.
- **One client implementation, bound into each language.** Rust clients use
  tinytrader's crates directly; other languages call the same Rust client
  through a C ABI or PyO3 rather than reimplementing the protocol.
- **GPU work runs natively on a Mac**, outside Docker.

### Training versus live

- **Live inference must run on CPU, on Linux**, since a live host may have no
  GPU. Metal is for training speed only.
- **Features are computed by one implementation**, used by both training and
  live inference.
- **Trained models are versioned artifacts**, promoted to live by an
  explicit, recorded step. A live trader loads a pinned artifact; it does not
  train.
- **Live traders are deployed like any other service** (meeting the
  [contract](#contract-with-application-repos)); offline jobs run on demand.

### Bulk data routes (planned)

```text
nas cex-archive, databento ──NFS, read-only, LAN──▶ desk /data/archive
nas research               ──NFS, read-write──────▶ desk /data/research
desk internal SSD                                    /data/cache (disposable)
```

- **Mount the NAS at the same paths on every client**, so job configs don't
  change between machines. Archive exports are read-only to clients.
- **Bulk data uses the LAN address, not Tailscale**, whose encryption can cap
  throughput well below a fast LAN on macOS.
- Copy a working set to `/data/cache` when a job rereads it many times.

## Personal machines

The stack configures what runs, not the people who operate it.

- **Every machine has exactly one root configuration.** NixOS fleet hosts are
  rooted in the site. Macs you sit at are rooted in your machines
  repository, which owns users, shells, Tailscale and the Docker engine.
- **Dependencies point one way.** Your machines repository takes the site as
  a flake input and imports `<site>.darwinModules.<host>`, which builds on
  this stack's `roles/darwin.nix` and tinytrader's `darwinModules.services`.
  Neither tinytrader, this stack nor the site depends on anyone's personal
  configuration.
- **Fleet hosts carry no personal setup:** a minimal admin user, SSH keys and
  a basic shell.

## Deploy, rollback and auto-deploy

- **Containers:** `scripts/deploy SERVICE...` builds the images it needs
  (Nix, inside the Docker engine's VM), recreates those containers and checks
  each came back. `scripts/local-up.sh` and `local-down.sh` bring a host's
  whole share up or down.
- **Native services:** applying the Mac's role (your machines repository's
  switch, or `scripts/darwin-switch`). `scripts/deploy store` deploys the
  native store.
- **Rollback:** the previous commit, deployed; on a Mac or NixOS host, the
  previous system generation.
- **Updating tinytrader:** bump the site's `tinytrader` input
  (`nix flake update tinytrader`), commit, deploy. The deployed version is
  always in git history.
- **Deploy checkouts** ([decision 0012](decisions/0012-deploy-checkouts.md)):
  everything live runs from plain clones of `main` under
  `tinytrader-deploy.deployRoot`: `<deployRoot>/<site>` (named after
  `deployment.name`), `<deployRoot>/tinytrader-deploy` and
  `<deployRoot>/tinytrader`. Your working copies can be on any branch;
  nothing live reads them. Run by hand from a working copy, the scripts run
  the deploy checkout's copy of themselves.
- **Auto-deploy** ([decision 0011](decisions/0011-auto-deploy-from-main.md)):
  `scripts/auto-deploy`, a launchd agent every few minutes
  (`modules/auto-deploy-darwin.nix`, off until the machine sets
  `tinytrader-deploy.autoDeploy.enable`), fast-forwards the three deploy
  checkouts and redeploys only what the new commits touch. It never forces,
  never deploys during market hours, and never touches the gateways, the
  relays or anything in `deployment.autoDeploy.never`: those are notified as
  needing a manual deploy. It commits and pushes the console's state first.

### Market hours

No image builds between 09:25 and 16:20 New York time on trading days.
Builds compile inside the Docker engine's VM on every CPU it has, the same
CPUs the relays read from, and a busy relay that falls behind loses records
from its provider. Page changes don't need a build (the console serves its
pages from the deploy checkout); anything else waits for the close.
`scripts/deploy` enforces this: it refuses builds in those hours and
restarting a relay that is live (`--force` overrides both). Auto-deploy
starts nothing after 09:00 so a build is done before the open.

## Contract with application repos

A service is deployable from here if it:

- is buildable as a Nix package (flake output);
- takes config and data roots from files or flags, never hardcoded paths;
- logs to stdout/journald;
- exposes `/health` and `/metrics` (and, for trading, a small control API);
- shuts down cleanly on SIGTERM and recovers after a restart.

## Observability and remote control

**Each host watches itself** ([decision 0006](decisions/0006-host-monitoring.md),
set up with [monitoring.md](monitoring.md)). Every host placed to run `watch`
runs tinytrader's `watch` natively (a launchd daemon on a Mac, systemd on
NixOS), outside Docker so it outlives the engine. Every minute it checks:

- the Docker engine (a ping on its socket);
- the containers the inventory places on its host: present, running, and not
  restarting;
- the console's `/api/state` where the console runs (a service `failed`, or
  `degraded` for 3 minutes) and the store's `/health` where the store runs;
- its native services (launchd or systemd);
- its disks (`hosts.<host>.watch.disks`, thresholds in `monitoring.disk`).

Problems seen two runs in a row go to a private ntfy topic, and a
"resolved" follows. After each run it pings that host's healthchecks.io
check, so a host that is off or offline is noticed from outside. It never
connects to an order gateway: those are judged by their containers alone.
node_exporter runs on each host for the console's Hosts views. Both are
boot-time daemons, so they start without a login (once FileVault, if on, is
unlocked).

Planned, on the NAS: metrics and logs from every host, dashboards, served
over Tailscale only. SSH + tmux remains the break-glass path. Server-side
risk limits and a dead-man's switch on a gateway must not depend on any of
this being reachable.

## Open questions

1. **NixOS deploy tool:** plain `nixos-rebuild --target-host`, deploy-rs
   (automatic rollback if the host becomes unreachable), or colmena?
2. **Offsite rotation cadence** (see [Backups](#backups)).
3. **VPS sizing and sync interval:** how much hot data can the VPS hold, and
   how many hours of capture are you willing to have as a single copy?
4. **Monitoring independence:** healthchecks.io covers a silent host; a home
   outage still silences alerts about a VPS unless something outside watches
   it.
5. **Model language and framework.** Apple GPUs have no Float64, so GPU code
   paths must work in Float32; non-Rust clients need bindings to tinytrader's
   Rust client.
